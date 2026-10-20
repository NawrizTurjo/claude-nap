#Requires -Version 7.0
# ClaudeUsageManager - 5-hour usage provider, gate and reset waiter for Claude Code
# on a claude.ai subscription (Pro / Max / Team).
#
# Data source: the `rate_limit_event` message that Claude Code emits in
#   claude -p ... --output-format stream-json --verbose
# Its `rate_limit_info.unifiedWindows.five_hour` holds `utilization` (0..1) and
# `resetsAt` (Unix seconds). The event type is part of the Agent SDK message union
# (SDKRateLimitEvent) but its fields are not documented in detail, so every reading
# is validated and anything unexpected becomes UNKNOWN.
#
# The probe is one tiny Haiku turn (~1.1k tokens) on the subscription login.
# This module never reads ~/.claude/.credentials.json and never logs tokens.

$script:Root = $PSScriptRoot

$script:Defaults = [ordered]@{
    Enabled                   = $true
    DryRun                    = $true
    StopThresholdPercent      = 98
    PredictiveStop            = $true
    HeavyToolsBlockPercent    = 90
    HeavyTools                = @('Agent', 'Task', 'Workflow')
    MinPollSeconds            = 5
    MaxPollSeconds            = 300
    PollBands                 = @(
        [pscustomobject]@{ BelowPercent = 50;  Seconds = 300 }
        [pscustomobject]@{ BelowPercent = 75;  Seconds = 120 }
        [pscustomobject]@{ BelowPercent = 85;  Seconds = 60 }
        [pscustomobject]@{ BelowPercent = 92;  Seconds = 20 }
        [pscustomobject]@{ BelowPercent = 101; Seconds = 8 })
    UnknownBlockMarginPercent = 5
    MaxDataAgeSeconds         = 180
    ProbeModel                = 'haiku'
    ProbeTimeoutSeconds       = 45
    ClaudePath                = ''
    ResetGraceSeconds         = 30
    RetrySeconds              = @(60, 120, 300)
    PreNotifyMinutes          = 5
    MaxWaitHours              = 8
    Notifications             = $true
}

#region config, paths, logging

function Get-CumConfig {
    param([string]$Path = $(if ($env:CUM_CONFIG) { $env:CUM_CONFIG } else { Join-Path $script:Root 'config.json' }))
    $cfg = [ordered]@{} + $script:Defaults
    # config.json holds the shipped defaults; config.local.json (git-ignored) holds your overrides.
    $local = Join-Path (Split-Path $Path) 'config.local.json'
    foreach ($file in $Path, $local) {
        if (-not (Test-Path $file)) { continue }
        $json = Get-Content $file -Raw | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    }
    [pscustomobject]$cfg
}

function Get-CumStateDir {
    $d = if ($env:CUM_STATE_DIR) { $env:CUM_STATE_DIR } else { Join-Path $script:Root 'state' }
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
    $d
}

function Get-CumPath([string]$Name) { Join-Path (Get-CumStateDir) $Name }

function Test-CumStopFile { Test-Path (Get-CumPath 'STOP') }

function Write-CumLog([string]$Message) {
    $line = '{0}  {1}' -f [datetimeoffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz'), $Message
    try { Add-Content (Get-CumPath 'events.log') $line } catch {}
}

function Write-CumJsonAtomic([string]$Path, $Object) {
    $tmp = "$Path.$PID.tmp"
    $Object | ConvertTo-Json -Depth 5 | Set-Content $tmp -Encoding utf8
    Move-Item $tmp $Path -Force
}

function Send-CumNotification([string]$Title, [string]$Body, $Config) {
    Write-CumLog "NOTIFY $Title - $Body"
    if (-not $Config.Notifications -or $env:CUM_NO_TOAST) { return }
    $esc = { param($s) [Security.SecurityElement]::Escape($s) }
    # Toasts need the WinRT projection, which only Windows PowerShell 5.1 has.
    $ps = @"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
`$x = New-Object Windows.Data.Xml.Dom.XmlDocument
`$x.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$(& $esc $Title)</text><text>$(& $esc $Body)</text></binding></visual></toast>")
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show([Windows.UI.Notifications.ToastNotification]::new(`$x))
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps))
    try { Start-Process powershell.exe -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $enc -WindowStyle Hidden }
    catch { Write-CumLog "toast failed: $($_.Exception.Message)" }
}

#endregion
#region probe

function Resolve-CumClaudePath {
    param($Config)
    if ($Config.ClaudePath) {
        if (Test-Path $Config.ClaudePath) { return $Config.ClaudePath }
        throw "ClaudePath '$($Config.ClaudePath)' in config.json does not exist."
    }
    $cmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { throw "claude CLI not found on PATH. Install it or set ClaudePath in config.json." }
    $cmd.Source
}

# Returns the next simulated probe output when CUM_FIXTURE_DIR is set (tests only):
# files are consumed in name order, and the last one is reused once the rest are gone.
function Get-CumFixtureLines {
    $files = @(Get-ChildItem $env:CUM_FIXTURE_DIR -Filter '*.jsonl' | Sort-Object Name)
    if (-not $files) { throw "no fixtures left in $env:CUM_FIXTURE_DIR" }
    $lines = Get-Content $files[0].FullName
    if ($files.Count -gt 1) { Rename-Item $files[0].FullName "$($files[0].Name).used" }
    $lines
}

# Runs the probe and returns raw stdout lines. Refuses to run when an API key is in
# the environment, because the probe would then bill the API instead of the plan.
function Invoke-CumProbe {
    param($Config)
    if ($env:CUM_FIXTURE_DIR) { return [pscustomobject]@{ Lines = Get-CumFixtureLines; ExitCode = 0 } }
    foreach ($var in 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN') {
        if ([Environment]::GetEnvironmentVariable($var)) {
            throw "$var is set; refusing to probe because it would use paid API billing instead of the subscription."
        }
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Resolve-CumClaudePath $Config))
    foreach ($a in @(
        '-p', 'ok',
        '--model', $Config.ProbeModel,
        '--output-format', 'stream-json', '--verbose',
        '--max-turns', '1',
        '--tools', '',
        '--system-prompt', 'Reply with the single word ok.',
        '--strict-mcp-config',
        '--setting-sources', 'project',   # skips user settings, so our own hook never recurses
        '--disable-slash-commands',
        '--no-session-persistence')) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory       = Get-CumStateDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $null = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($Config.ProbeTimeoutSeconds * 1000)) {
        try { $proc.Kill($true) } catch {}
        throw "probe timed out after $($Config.ProbeTimeoutSeconds)s"
    }
    $proc.WaitForExit()
    [pscustomobject]@{ Lines = $outTask.Result -split "`r?`n" | Where-Object { $_ }; ExitCode = $proc.ExitCode }
}

# Parses probe stdout into a raw reading. Pure function, used by the tests.
function ConvertFrom-CumProbeOutput {
    param([string[]]$Lines, [datetimeoffset]$ProbedAt = [datetimeoffset]::Now)
    $reading = [ordered]@{
        Source        = 'claude -p stream-json rate_limit_event (five_hour)'
        ProbedAt      = $ProbedAt
        UsedFraction  = $null
        ResetsAtUnix  = $null
        LimitStatus   = $null
        Overage       = $null
        ApiKeySource  = $null
        ParseProblems = [System.Collections.Generic.List[string]]::new()
    }
    $event = $null
    foreach ($line in $Lines) {
        $j = $null
        try { $j = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($j.type -eq 'system' -and $j.subtype -eq 'init') { $reading.ApiKeySource = $j.apiKeySource }
        if ($j.type -eq 'rate_limit_event') { $event = $j }   # keep the last one
    }
    if (-not $event) { $reading.ParseProblems.Add('no rate_limit_event in probe output'); return [pscustomobject]$reading }

    $info = $event.rate_limit_info
    $reading.LimitStatus = $info.status
    $reading.Overage     = $info.overageStatus
    $win = $info.unifiedWindows.five_hour
    if ($win) {
        $reading.UsedFraction = $win.utilization
        $reading.ResetsAtUnix = $win.resetsAt
    } elseif ($info.rateLimitType -eq 'five_hour') {
        $reading.ResetsAtUnix = $info.resetsAt
        $reading.ParseProblems.Add('five_hour window has no utilization field')
    } else {
        $reading.ParseProblems.Add('rate_limit_event has no five_hour window')
    }
    [pscustomobject]$reading
}

#endregion
#region evaluation

# Turns a raw reading into a verdict. Anything that cannot be trusted yields UNKNOWN.
function Resolve-CumUsage {
    param($Reading, $Config, [datetimeoffset]$Now = [datetimeoffset]::Now)
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $Reading.ParseProblems) { $problems.Add($p) }

    if ($Reading.ApiKeySource -and $Reading.ApiKeySource -ne 'none') {
        $problems.Add("probe authenticated with '$($Reading.ApiKeySource)', not the subscription login")
    }

    $used = $null
    if ($null -ne $Reading.UsedFraction) {
        if ($Reading.UsedFraction -isnot [ValueType] -or [double]$Reading.UsedFraction -lt 0 -or [double]$Reading.UsedFraction -gt 1.5) {
            $problems.Add("utilization '$($Reading.UsedFraction)' is not a number in the expected 0..1 range")
        } else { $used = [math]::Round([double]$Reading.UsedFraction * 100, 1) }
    } elseif (-not $problems.Count) { $problems.Add('utilization missing') }

    $resetsAt = $null
    if ($null -ne $Reading.ResetsAtUnix -and $Reading.ResetsAtUnix -is [ValueType]) {
        $resetsAt = [datetimeoffset]::FromUnixTimeSeconds([long]$Reading.ResetsAtUnix).ToLocalTime()
        if ($resetsAt -le $Now) {
            $problems.Add("reset time $($resetsAt.ToString('yyyy-MM-dd HH:mm:ss')) has already passed; reading belongs to an expired window")
        } elseif ($resetsAt -gt $Now.AddHours(5).AddMinutes(5)) {
            $problems.Add('reset time is more than 5 hours away; not a 5-hour window')
        }
    } else { $problems.Add('reset time missing') }

    $age = ($Now - $Reading.ProbedAt).TotalSeconds
    if ($age -gt $Config.MaxDataAgeSeconds) {
        $problems.Add("data is $([int]$age)s old (max $($Config.MaxDataAgeSeconds)s)")
    } elseif ($age -lt -60) { $problems.Add('probe timestamp is in the future') }

    $status = if ($problems.Count) { 'UNKNOWN' } else { 'OK' }
    $action = if ($status -eq 'UNKNOWN') { 'UNKNOWN' }
              elseif ($used -ge $Config.StopThresholdPercent -or $Reading.LimitStatus -eq 'rejected') { 'STOP' }
              else { 'CONTINUE' }

    [pscustomobject]@{
        Status           = $status
        Action           = $action
        UsedPercent      = if ($status -eq 'OK') { $used } else { $null }
        RemainingPercent = if ($status -eq 'OK') { [math]::Round(100 - $used, 1) } else { $null }
        ResetsAtLocal    = if ($status -eq 'OK') { $resetsAt } else { $null }
        ResetsAtUnix     = if ($status -eq 'OK') { [long]$Reading.ResetsAtUnix } else { $null }
        TimeToReset      = if ($status -eq 'OK') { $resetsAt - $Now } else { $null }
        ThresholdPercent = $Config.StopThresholdPercent
        LimitStatus      = $Reading.LimitStatus
        Source           = $Reading.Source
        CheckedAt        = $Reading.ProbedAt
        DataAgeSeconds   = [int]$age
        Problems         = @($problems)
    }
}

#endregion
#region readings and history

function Save-CumReading {
    param($Reading)
    $Reading | Select-Object Source, @{n='ProbedAt';e={$_.ProbedAt.ToString('o')}}, UsedFraction, ResetsAtUnix,
        LimitStatus, Overage, ApiKeySource, ParseProblems |
        ForEach-Object { Write-CumJsonAtomic (Get-CumPath 'last-reading.json') $_ }
}

function Read-CumReading {
    $path = Get-CumPath 'last-reading.json'
    if (-not (Test-Path $path)) { return $null }
    try { $r = Get-Content $path -Raw | ConvertFrom-Json } catch { return $null }
    $r.ProbedAt = [datetimeoffset]::Parse($r.ProbedAt)
    if ($null -eq $r.ParseProblems) { $r.ParseProblems = @() }
    $r
}

function Add-CumHistory {
    param($Usage)
    if ($Usage.Status -ne 'OK') { return }
    $path = Get-CumPath 'history.jsonl'
    $line = @{ t = $Usage.CheckedAt.ToString('o'); used = $Usage.UsedPercent; resets = $Usage.ResetsAtUnix } | ConvertTo-Json -Compress
    $keep = @(if (Test-Path $path) { Get-Content $path | Select-Object -Last 49 }) + $line
    Set-Content "$path.$PID.tmp" $keep
    Move-Item "$path.$PID.tmp" $path -Force
}

function Read-CumHistory {
    $path = Get-CumPath 'history.jsonl'
    if (-not (Test-Path $path)) { return @() }
    @(Get-Content $path | ForEach-Object {
        try { $h = $_ | ConvertFrom-Json; [pscustomobject]@{ T = [datetimeoffset]::Parse($h.t); Used = [double]$h.used; Resets = [long]$h.resets } } catch {}
    })
}

# Percent per second over the last 10 minutes of the current window; 0 when unknown.
function Get-CumBurnRate {
    param([object[]]$History, [datetimeoffset]$Now = [datetimeoffset]::Now)
    if ($History.Count -lt 2) { return 0.0 }
    $last = $History[-1]
    $win = @($History | Where-Object { $_.Resets -eq $last.Resets -and ($Now - $_.T).TotalSeconds -le 600 })
    if ($win.Count -lt 2) { return 0.0 }
    $dt = ($win[-1].T - $win[0].T).TotalSeconds
    if ($dt -lt 5) { return 0.0 }
    [math]::Max(0.0, ($win[-1].Used - $win[0].Used) / $dt)
}

# Seconds until the next probe: a band by usage level, shortened when usage is climbing
# fast enough that the threshold could be crossed before the band's interval elapses.
function Get-CumPollInterval {
    param([double]$UsedPercent, [double]$RatePerSecond, $Config)
    $band = $Config.MaxPollSeconds
    foreach ($b in $Config.PollBands) { if ($UsedPercent -lt $b.BelowPercent) { $band = $b.Seconds; break } }
    $interval = [double]$band
    if ($RatePerSecond -gt 0) {
        $secondsToThreshold = ($Config.StopThresholdPercent - $UsedPercent) / $RatePerSecond
        $interval = [math]::Min($interval, $secondsToThreshold / 4)
    }
    [int][math]::Max($Config.MinPollSeconds, [math]::Min($Config.MaxPollSeconds, $interval))
}

#endregion
#region pause state

function Read-CumPause {
    $path = Get-CumPath 'pause.json'
    if (-not (Test-Path $path)) { return $null }
    try { Get-Content $path -Raw | ConvertFrom-Json } catch { $null }
}

function Set-CumPause($Usage, [string]$Reason, [long]$ResetsAtUnix = $Usage.ResetsAtUnix) {
    Write-CumJsonAtomic (Get-CumPath 'pause.json') ([ordered]@{
        Since = [datetimeoffset]::Now.ToString('o'); UsedPercent = $Usage.UsedPercent
        ResetsAtUnix = $ResetsAtUnix; Reason = $Reason })
}

function Clear-CumPause { Remove-Item (Get-CumPath 'pause.json') -ErrorAction SilentlyContinue }

# Nap test (Start-NapTest.ps1): a temporary, self-expiring override that lowers the stop
# threshold and pretends the reset is a few seconds away, so the whole pause/resume cycle
# can be exercised for real without waiting hours. The waiter removes it on resume.
function Read-CumNapTest {
    $path = Get-CumPath 'nap-test.json'
    if (-not (Test-Path $path)) { return $null }
    try { $t = Get-Content $path -Raw | ConvertFrom-Json } catch { return $null }
    if ([datetimeoffset]::Parse($t.ExpiresAt) -le [datetimeoffset]::Now) { return $null }
    $t
}

function Clear-CumNapTest { Remove-Item (Get-CumPath 'nap-test.json') -ErrorAction SilentlyContinue }

#endregion
#region main entry points

# Fresh probe (default), cached reading, or fixture file for tests.
function Get-ClaudeUsage {
    [CmdletBinding()]
    param(
        [switch]$FromCache,
        [string]$FixturePath,
        [datetimeoffset]$Now = [datetimeoffset]::Now,
        [datetimeoffset]$FixtureProbedAt = $Now,
        $Config = (Get-CumConfig)
    )
    try {
        if ($FixturePath) {
            $reading = ConvertFrom-CumProbeOutput -Lines (Get-Content $FixturePath) -ProbedAt $FixtureProbedAt
            return Resolve-CumUsage -Reading $reading -Config $Config -Now $Now
        }
        if ($FromCache) {
            $reading = Read-CumReading
            if (-not $reading) { throw 'no cached reading yet; run without -FromCache first' }
            return Resolve-CumUsage -Reading $reading -Config $Config -Now $Now
        }
        $probedAt = [datetimeoffset]::Now
        $probe = Invoke-CumProbe $Config
        $reading = ConvertFrom-CumProbeOutput -Lines $probe.Lines -ProbedAt $probedAt
        if ($probe.ExitCode -ne 0 -and $null -eq $reading.UsedFraction -and -not $reading.ParseProblems.Count) {
            $reading.ParseProblems.Add("claude exited with code $($probe.ExitCode)")
        }
        Save-CumReading $reading
        $usage = Resolve-CumUsage -Reading $reading -Config $Config -Now ([datetimeoffset]::Now)
        Add-CumHistory $usage
        $usage
    } catch {
        [pscustomobject]@{
            Status = 'UNKNOWN'; Action = 'UNKNOWN'; UsedPercent = $null; RemainingPercent = $null
            ResetsAtLocal = $null; ResetsAtUnix = $null; TimeToReset = $null
            ThresholdPercent = $Config.StopThresholdPercent; LimitStatus = $null; Source = 'none'
            CheckedAt = $Now; DataAgeSeconds = $null; Problems = @("$($_.Exception.Message)")
        }
    }
}

# Probes only if the cached reading is older than the dynamic interval and no other
# hook is already probing. Concurrent callers (parallel subagents) reuse the cache.
function Get-CumGateUsage {
    param($Config)
    $history  = Read-CumHistory
    $rate     = Get-CumBurnRate $history
    $cached   = Read-CumReading
    $lastUsed = if ($history.Count) { $history[-1].Used } else { 0 }
    $interval = Get-CumPollInterval $lastUsed $rate $Config
    $age      = if ($cached) { ([datetimeoffset]::Now - $cached.ProbedAt).TotalSeconds } else { [double]::MaxValue }

    if ($age -ge $interval) {
        $lock = Get-CumPath 'probe.lock'
        if ((Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalSeconds -gt 120) {
            Remove-Item $lock -ErrorAction SilentlyContinue   # left behind by a killed probe
        }
        $handle = $null
        try { $handle = [IO.File]::Open($lock, 'CreateNew', 'Write', 'None') } catch {}
        if ($handle) {
            try {
                $usage = Get-ClaudeUsage -Config $Config
                $history = Read-CumHistory
                $rate = Get-CumBurnRate $history
                $interval = if ($usage.Status -eq 'OK') { Get-CumPollInterval $usage.UsedPercent $rate $Config } else { $Config.MinPollSeconds }
                return [pscustomobject]@{ Usage = $usage; Rate = $rate; Interval = $interval; Probed = $true; LastGood = $history | Select-Object -Last 1 }
            } finally { $handle.Dispose(); Remove-Item $lock -ErrorAction SilentlyContinue }
        }
    }
    # Use the cache, accepting data up to a few intervals old.
    $cacheCfg = $Config.PSObject.Copy()
    $cacheCfg.MaxDataAgeSeconds = [math]::Max($Config.MaxDataAgeSeconds, $interval * 3)
    $usage = if ($cached) { Resolve-CumUsage -Reading $cached -Config $cacheCfg } else { Get-ClaudeUsage -FromCache -Config $cacheCfg }
    [pscustomobject]@{ Usage = $usage; Rate = $rate; Interval = $interval; Probed = $false; LastGood = $history | Select-Object -Last 1 }
}

function Test-CumExemptTool {
    param($HookInput)
    $ti = $HookInput.tool_input
    switch -Regex ($HookInput.tool_name) {
        '^(Write|Edit|MultiEdit)$' {
            $p = "$($ti.file_path)" -replace '/', '\'
            $ck = (Get-CumPath 'checkpoints') -replace '/', '\'
            return $p.StartsWith($ck, [StringComparison]::OrdinalIgnoreCase)
        }
        '^(Bash|PowerShell)$' { return "$($ti.command)" -match '(Wait-ClaudeReset|Check-ClaudeUsage|Start-NapTest)\.ps1' }
    }
    $false
}

function Get-CumCheckpointPath([string]$SessionId) {
    $dir = Get-CumPath 'checkpoints'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $safe = if ($SessionId) { $SessionId -replace '[^\w-]', '_' } else { 'session' }
    Join-Path $dir "$safe.md"
}

function Get-CumStopInstructions {
    param($HookInput, [string]$Why)
    if ($HookInput.agent_id) {
        return "[claude-nap] $Why You are a subagent: make no more tool calls. Return to your parent now with what you completed (with evidence) and what remains."
    }
    $ck   = Get-CumCheckpointPath $HookInput.session_id
    $wait = Join-Path $script:Root 'Wait-ClaudeReset.ps1'
    @"
[claude-nap] $Why Do not start new work. Follow the claude-nap skill:
1. Write a checkpoint to $ck : the task exactly as the user authorized it, completed items with evidence, the in-progress item and its exact state, remaining items, constraints.
2. Start this as a BACKGROUND shell command (run_in_background): pwsh -NoProfile -File "$wait" -Checkpoint "$ck"
3. End your turn with one line saying work is paused until the reset. The waiter's exit will wake you; then follow its output.
"@
}

# PreToolUse decision. Returns $null to allow (normal permission flow continues),
# or an object to emit as hook JSON.
function Get-CumGateDecision {
    param($HookInput, $Config = (Get-CumConfig))
    $deny = { param($reason) @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } }

    if (Test-CumStopFile) {
        return & $deny "[claude-nap] STOP file present ($(Get-CumPath 'STOP')). The user requested an immediate halt: make no more tool calls, summarize where you stopped, and end your turn."
    }
    if (-not $Config.Enabled) { return $null }
    if (Test-CumExemptTool $HookInput) { return $null }

    $test = Read-CumNapTest
    if ($test) {
        $Config = $Config.PSObject.Copy()
        $Config.StopThresholdPercent = [double]$test.ThresholdPercent
        $Config.DryRun = $false
        $Config.PredictiveStop = $false
    }

    $pause = Read-CumPause
    if ($pause -and -not $Config.DryRun) {
        $at = [datetimeoffset]::FromUnixTimeSeconds([long]$pause.ResetsAtUnix).ToLocalTime().ToString('HH:mm:ss zzz')
        return & $deny (Get-CumStopInstructions $HookInput "Usage paused at $($pause.UsedPercent)% until the 5-hour reset (expected $at).")
    }

    $g = Get-CumGateUsage $Config
    $u = $g.Usage
    if ($u.Status -eq 'OK') {
        $projected = [math]::Round($u.UsedPercent + $g.Rate * $g.Interval, 1)
        $why = $null
        if ($u.Action -eq 'STOP') { $why = "5-hour usage is $($u.UsedPercent)% (threshold $($Config.StopThresholdPercent)%)." }
        elseif ($Config.PredictiveStop -and $g.Rate -gt 0 -and $projected -ge $Config.StopThresholdPercent) {
            $why = "5-hour usage is $($u.UsedPercent)% and climbing $([math]::Round($g.Rate * 60, 1))%/min; projected $projected% before the next check (threshold $($Config.StopThresholdPercent)%)."
        }
        if (-not $why) {
            # Near the limit, block new subagent fan-out: parallel agents can jump 90% -> 100% in seconds.
            if ($HookInput.tool_name -in $Config.HeavyTools -and $u.UsedPercent -ge $Config.HeavyToolsBlockPercent) {
                $msg = "[claude-nap] 5-hour usage is $($u.UsedPercent)% (>= $($Config.HeavyToolsBlockPercent)%): not spawning new subagents/workflows near the limit. Continue the work yourself in this conversation, in small steps."
                if ($Config.DryRun) { return @{ systemMessage = "[claude-nap DRY RUN] would block $($HookInput.tool_name): usage $($u.UsedPercent)%." } }
                return & $deny $msg
            }
            return $null
        }
        $resetUnix = $u.ResetsAtUnix
        if ($test) {
            $resetUnix = [datetimeoffset]::Now.AddSeconds([int]$test.FakeResetSeconds).ToUnixTimeSeconds()
            $why = "[NAP TEST] $why"
        }
        $when = [datetimeoffset]::FromUnixTimeSeconds($resetUnix).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
        if ($Config.DryRun) {
            if (-not (Test-Path (Get-CumPath "dryrun-notified-$($u.ResetsAtUnix)"))) {
                New-Item (Get-CumPath "dryrun-notified-$($u.ResetsAtUnix)") -Force | Out-Null
                Send-CumNotification 'Claude usage threshold (dry run)' "$why Would pause until $when." $Config
            }
            Write-CumLog "DRYRUN would stop: $why"
            return @{ systemMessage = "[claude-nap DRY RUN] would pause now: $why Reset $when." }
        }
        if (-not (Read-CumPause)) {
            Set-CumPause $u $why $resetUnix
            Write-CumLog "PAUSE $why reset $when"
            Send-CumNotification 'Claude usage threshold reached' "$why Paused until $when." $Config
        }
        return & $deny (Get-CumStopInstructions $HookInput "$why Expected reset $when.")
    }

    # UNKNOWN: never guess. Block only if the last good reading was already near the threshold.
    Write-CumLog "UNKNOWN in gate: $($u.Problems -join '; ')"
    if (-not $Config.DryRun -and $g.LastGood -and $g.LastGood.Used -ge ($Config.StopThresholdPercent - $Config.UnknownBlockMarginPercent)) {
        return & $deny "[claude-nap] Usage cannot be verified right now ($($u.Problems -join '; ')) and the last good reading was $($g.LastGood.Used)%. Not starting this tool call; retry in a minute, and if this repeats, checkpoint and stop as the claude-nap skill describes."
    }
    $null
}

#endregion
#region display

function Format-CumDuration($t) {
    if ($null -eq $t) { return 'UNKNOWN' }
    $t = [timespan]$t
    '{0}h {1:00}m {2:00}s' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds
}

function Show-ClaudeUsage {
    param($Usage)
    $na = 'UNKNOWN'
    $color = switch ($Usage.Action) { 'CONTINUE' { 'Green' } 'STOP' { 'Red' } default { 'Yellow' } }
    Write-Host "Claude Code 5-hour usage  [$($Usage.Status)]  action: $($Usage.Action)" -ForegroundColor $color
    $rows = [ordered]@{
        'Used'          = if ($null -ne $Usage.UsedPercent) { "$($Usage.UsedPercent) %" } else { $na }
        'Remaining'     = if ($null -ne $Usage.RemainingPercent) { "$($Usage.RemainingPercent) %" } else { $na }
        'Resets at'     = if ($Usage.ResetsAtLocal) { $Usage.ResetsAtLocal.ToString('yyyy-MM-dd HH:mm:ss zzz') + ' (local)' } else { $na }
        'Time to reset' = Format-CumDuration $Usage.TimeToReset
        'Stop at'       = "$($Usage.ThresholdPercent) %"
        'Server status' = if ($Usage.LimitStatus) { $Usage.LimitStatus } else { $na }
        'Data source'   = $Usage.Source
        'Checked at'    = if ($Usage.CheckedAt) { $Usage.CheckedAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz') } else { $na }
        'Data age'      = if ($null -ne $Usage.DataAgeSeconds) { "$($Usage.DataAgeSeconds) s" } else { $na }
    }
    foreach ($k in $rows.Keys) { Write-Host ('  {0,-14} {1}' -f "${k}:", $rows[$k]) }
    foreach ($p in $Usage.Problems) { Write-Host "  ! $p" -ForegroundColor Yellow }
}

#endregion

Export-ModuleMember -Function Get-CumConfig, Get-CumStateDir, Get-CumPath, Test-CumStopFile, Write-CumLog,
    Send-CumNotification, ConvertFrom-CumProbeOutput, Resolve-CumUsage, Read-CumReading, Read-CumHistory,
    Get-CumBurnRate, Get-CumPollInterval, Read-CumPause, Set-CumPause, Clear-CumPause, Read-CumNapTest, Clear-CumNapTest, Get-ClaudeUsage,
    Get-CumGateUsage, Get-CumGateDecision, Test-CumExemptTool, Get-CumCheckpointPath, Format-CumDuration,
    Show-ClaudeUsage
