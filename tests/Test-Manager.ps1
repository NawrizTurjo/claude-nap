#Requires -Version 7.0
# Simulated tests for the gate hook, dynamic polling and the reset waiter.
# Uses an isolated temp state dir and fixture probes: no claude calls, no toasts.
$root = Split-Path $PSScriptRoot
Import-Module (Join-Path $root 'ClaudeUsageManager.psm1') -Force

$tmp = Join-Path ([IO.Path]::GetTempPath()) "cum-test-$PID"
$env:CUM_NO_TOAST = '1'
$results = [System.Collections.Generic.List[object]]::new()
function Check([string]$Case, [bool]$Ok, [string]$Got = '') {
    $results.Add([pscustomobject]@{ Result = if ($Ok) { 'PASS' } else { 'FAIL' }; Case = $Case; Got = $Got })
}

function Reset-Env([hashtable]$ConfigOverrides = @{}) {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Force "$tmp/state", "$tmp/fx" | Out-Null
    $env:CUM_STATE_DIR   = "$tmp/state"
    $env:CUM_FIXTURE_DIR = "$tmp/fx"
    $cfg = [ordered]@{ DryRun = $false; Notifications = $false }
    foreach ($k in $ConfigOverrides.Keys) { $cfg[$k] = $ConfigOverrides[$k] }
    $cfg | ConvertTo-Json | Set-Content "$tmp/config.json"
    $env:CUM_CONFIG = "$tmp/config.json"
}

$script:fxCount = 0
function Add-Probe($Utilization, [long]$ResetsAt, [string]$Status = 'allowed') {
    $script:fxCount++
    $info = [ordered]@{ status = $Status; resetsAt = $ResetsAt; rateLimitType = 'five_hour'
        unifiedWindows = @{ five_hour = @{ utilization = $Utilization; resetsAt = $ResetsAt } } }
    @(
        '{"type":"system","subtype":"init","apiKeySource":"none"}'
        (@{ type = 'rate_limit_event'; rate_limit_info = $info } | ConvertTo-Json -Compress -Depth 5)
    ) | Set-Content ("$tmp/fx\{0:000}.jsonl" -f $script:fxCount)
}
function Add-BrokenProbe { $script:fxCount++; '{"type":"result"}' | Set-Content ("$tmp/fx\{0:000}.jsonl" -f $script:fxCount) }

function Hook([string]$Tool = 'Bash', $ToolInput = @{ command = 'ls' }, [string]$AgentId) {
    $h = [ordered]@{ session_id = 'sess-1'; hook_event_name = 'PreToolUse'; tool_name = $Tool; tool_input = $ToolInput }
    if ($AgentId) { $h.agent_id = $AgentId; $h.agent_type = 'general-purpose' }
    Get-CumGateDecision -HookInput ([pscustomobject]$h | ConvertTo-Json | ConvertFrom-Json) -Config (Get-CumConfig)
}
function DecisionOf($d) { if ($null -eq $d) { 'allow' } elseif ($d.hookSpecificOutput) { $d.hookSpecificOutput.permissionDecision } else { 'message' } }

$soon = [datetimeoffset]::Now.AddHours(2).ToUnixTimeSeconds()

# --- dynamic polling interval -------------------------------------------------
$cfg = Get-CumConfig
Check 'interval: 40%, idle -> 300s'           ((Get-CumPollInterval 40 0 $cfg) -eq 300)  (Get-CumPollInterval 40 0 $cfg)
Check 'interval: 80%, idle -> 60s'            ((Get-CumPollInterval 80 0 $cfg) -eq 60)   (Get-CumPollInterval 80 0 $cfg)
Check 'interval: 90%, idle -> 8s band'        ((Get-CumPollInterval 93 0 $cfg) -eq 8)    (Get-CumPollInterval 93 0 $cfg)
Check 'interval: 60% burning 0.33%/s -> 29s'  ((Get-CumPollInterval 60 0.33 $cfg) -eq 29) (Get-CumPollInterval 60 0.33 $cfg)
Check 'interval: 96% burning 0.33%/s -> 5s floor' ((Get-CumPollInterval 96 0.33 $cfg) -eq 5) (Get-CumPollInterval 96 0.33 $cfg)
$now = [datetimeoffset]::Now
$hist = @([pscustomobject]@{ T = $now.AddSeconds(-30); Used = 90; Resets = 1 }, [pscustomobject]@{ T = $now; Used = 100; Resets = 1 })
Check 'burn rate: 90->100 in 30s = 0.333%/s'  ([math]::Abs((Get-CumBurnRate $hist $now) - 0.3333) -lt 0.001) (Get-CumBurnRate $hist $now)
$hist2 = @([pscustomobject]@{ T = $now.AddSeconds(-30); Used = 90; Resets = 1 }, [pscustomobject]@{ T = $now; Used = 2; Resets = 2 })
Check 'burn rate ignores previous window'     ((Get-CumBurnRate $hist2 $now) -eq 0)

# --- gate ---------------------------------------------------------------------
Reset-Env; Add-Probe 0.97 $soon
$d = Hook; Check 'gate: 97% -> allow' ((DecisionOf $d) -eq 'allow') (DecisionOf $d)

Reset-Env; Add-Probe 0.98 $soon
$d = Hook; $r = $d.hookSpecificOutput.permissionDecisionReason
Check 'gate: 98% -> deny'                     ((DecisionOf $d) -eq 'deny') (DecisionOf $d)
Check 'gate: deny tells main agent checkpoint + waiter' ($r -match 'checkpoints[\\/]sess-1\.md' -and $r -match 'Wait-ClaudeReset\.ps1')
Check 'gate: pause.json written'              ($null -ne (Read-CumPause))
$d = Hook 'Read' @{ file_path = 'C:\x.txt' }
Check 'gate: paused -> later calls denied'    ((DecisionOf $d) -eq 'deny') (DecisionOf $d)
$ck = Get-CumCheckpointPath 'sess-1'
Check 'gate: paused, checkpoint Write allowed' ((DecisionOf (Hook 'Write' @{ file_path = $ck; content = 'x' })) -eq 'allow')
Check 'gate: paused, other Write denied'      ((DecisionOf (Hook 'Write' @{ file_path = 'C:\src\a.py'; content = 'x' })) -eq 'deny')
Check 'gate: paused, waiter launch allowed'   ((DecisionOf (Hook 'PowerShell' @{ command = "pwsh -NoProfile -File `"$root/Wait-ClaudeReset.ps1`" -Checkpoint `"$ck`"" })) -eq 'allow')
$d = Hook 'Bash' @{ command = 'ls' } 'agent-7'
Check 'gate: subagent told to return to parent' ($d.hookSpecificOutput.permissionDecisionReason -match 'subagent' -and $d.hookSpecificOutput.permissionDecisionReason -notmatch 'Wait-ClaudeReset')

Reset-Env; Add-Probe 0.91 $soon
Check 'gate: 91% -> Agent spawn denied'       ((DecisionOf (Hook 'Agent' @{ prompt = 'x' })) -eq 'deny')
Check 'gate: 91% -> normal tools still allowed' ((DecisionOf (Hook 'Edit' @{ file_path = 'C:\a.py' })) -eq 'allow')
Reset-Env; Add-Probe 0.85 $soon
Check 'gate: 85% -> Agent spawn allowed'      ((DecisionOf (Hook 'Agent' @{ prompt = 'x' })) -eq 'allow')

Reset-Env @{ DryRun = $true }; Add-Probe 0.98 $soon
$d = Hook
Check 'gate dry-run: 98% -> warn only, no pause' ((DecisionOf $d) -eq 'message' -and $null -eq (Read-CumPause)) (DecisionOf $d)

# Subagent burst: 92% ten seconds ago, 96% now -> 0.4%/s, projected >= 98% before next check.
Reset-Env; Add-Probe 0.96 $soon
@{ t = [datetimeoffset]::Now.AddSeconds(-10).ToString('o'); used = 92; resets = $soon } | ConvertTo-Json -Compress | Set-Content "$tmp/state\history.jsonl"
$d = Hook
Check 'gate: burst 92->96 in 10s -> predictive deny' ((DecisionOf $d) -eq 'deny' -and $d.hookSpecificOutput.permissionDecisionReason -match 'projected') (DecisionOf $d)

Reset-Env; Add-Probe 0.60 $soon; Add-Probe 0.61 $soon; Add-Probe 0.62 $soon
$null = Hook; $null = Hook
$used = @(Get-ChildItem "$tmp/fx" -Filter '*.used').Count
Check 'gate: 2nd call within interval reuses cache (1 probe)' ($used -eq 1) "probes=$used"

Reset-Env; Add-BrokenProbe
@{ t = [datetimeoffset]::Now.AddMinutes(-10).ToString('o'); used = 96; resets = $soon } | ConvertTo-Json -Compress | Set-Content "$tmp/state\history.jsonl"
Check 'gate: UNKNOWN + last good 96% -> deny' ((DecisionOf (Hook)) -eq 'deny')
Reset-Env; Add-BrokenProbe
@{ t = [datetimeoffset]::Now.AddMinutes(-10).ToString('o'); used = 50; resets = $soon } | ConvertTo-Json -Compress | Set-Content "$tmp/state\history.jsonl"
Check 'gate: UNKNOWN + last good 50% -> allow' ((DecisionOf (Hook)) -eq 'allow')

Reset-Env; Add-Probe 0.10 $soon; New-Item "$tmp/state\STOP" | Out-Null
Check 'gate: STOP file -> deny even at 10%'   ((DecisionOf (Hook)) -eq 'deny')

# Nap test override: enforces in dry-run, lowers threshold, fakes a near reset; expires.
Reset-Env @{ DryRun = $true }; Add-Probe 0.55 $soon
@{ ThresholdPercent = 55; FakeResetSeconds = 60; ExpiresAt = [datetimeoffset]::Now.AddMinutes(5).ToString('o') } | ConvertTo-Json | Set-Content "$tmp/state\nap-test.json"
$d = Hook; $p = Read-CumPause
$fake = $p -and ([long]$p.ResetsAtUnix - [datetimeoffset]::Now.ToUnixTimeSeconds()) -in 55..61
Check 'nap test: 55% vs test threshold 55 -> deny despite dry-run' ((DecisionOf $d) -eq 'deny' -and $d.hookSpecificOutput.permissionDecisionReason -match 'NAP TEST') (DecisionOf $d)
Check 'nap test: pause uses fake reset (+60s)' $fake
Check 'nap test: Start-NapTest -Cancel allowed while paused' ((DecisionOf (Hook 'PowerShell' @{ command = 'pwsh -File .\Start-NapTest.ps1 -Cancel' })) -eq 'allow')
Reset-Env @{ DryRun = $true }; Add-Probe 0.55 $soon
@{ ThresholdPercent = 55; FakeResetSeconds = 60; ExpiresAt = [datetimeoffset]::Now.AddMinutes(-1).ToString('o') } | ConvertTo-Json | Set-Content "$tmp/state\nap-test.json"
Check 'nap test: expired override ignored'    ((DecisionOf (Hook)) -eq 'allow')

# End-to-end through the real hook script (stdin JSON -> stdout JSON).
Reset-Env; Add-Probe 0.99 $soon
$out = '{"session_id":"e2e","tool_name":"Bash","tool_input":{"command":"ls"}}' | pwsh -NoProfile -File "$root/hooks\UsageGate.ps1"
$ok = $false; try { $ok = ($out | ConvertFrom-Json).hookSpecificOutput.permissionDecision -eq 'deny' } catch {}
Check 'hook script e2e: 99% -> deny JSON, exit 0' ($ok -and $LASTEXITCODE -eq 0) "$out".Substring(0, [math]::Min(60, "$out".Length))

# --- waiter (real time, ~15 s) -------------------------------------------------
Reset-Env @{ ResetGraceSeconds = 1; RetrySeconds = @(2); PreNotifyMinutes = 0.1 }
$t0 = [datetimeoffset]::Now
$expected = $t0.AddSeconds(4).ToUnixTimeSeconds()
@{ Since = $t0.ToString('o'); UsedPercent = 98; ResetsAtUnix = $expected; Reason = 'test' } | ConvertTo-Json | Set-Content "$tmp/state\pause.json"
Add-Probe 0.99 $expected 'rejected'                                   # delayed: still the old window
Add-Probe 1.0 $t0.AddSeconds(12).ToUnixTimeSeconds() 'rejected'       # server pushed the reset later
Add-Probe 0.01 $t0.AddHours(5).ToUnixTimeSeconds()                    # fresh window
$out = pwsh -NoProfile -File "$root/Wait-ClaudeReset.ps1" -Checkpoint 'C:\ck.md' 2>&1
$code = $LASTEXITCODE
$text = $out -join "`n"
Check 'waiter: delayed reset not trusted (UNKNOWN -> retry)' ($text -match 'Reset not confirmed yet: UNKNOWN')
Check 'waiter: follows server-moved reset time' ($text -match 'Still limited')
Check 'waiter: RESUME only after fresh probe, exit 0' ($code -eq 0 -and $text -match 'RESUME: reset confirmed' -and $text -match 'C:\\ck\.md') "exit=$code"
Check 'waiter: pause cleared on resume'      ($null -eq (Read-CumPause))
Check 'waiter: resumed after server reset, not before' (([datetimeoffset]::Now - $t0).TotalSeconds -ge 12) ("{0:n1}s" -f ([datetimeoffset]::Now - $t0).TotalSeconds)

Reset-Env @{ ResetGraceSeconds = 1; RetrySeconds = @(2) }
@{ Since = (Get-Date).ToString('o'); UsedPercent = 98; ResetsAtUnix = [datetimeoffset]::Now.AddMinutes(10).ToUnixTimeSeconds(); Reason = 'test' } | ConvertTo-Json | Set-Content "$tmp/state\pause.json"
$job = Start-ThreadJob { param($r) pwsh -NoProfile -File "$r\Wait-ClaudeReset.ps1" -Checkpoint 'C:\ck.md'; "EXIT=$LASTEXITCODE" } -ArgumentList $root
Start-Sleep 3; New-Item "$tmp/state\STOP" | Out-Null
$jobOut = ($job | Wait-Job -Timeout 20 | Receive-Job) -join "`n"
Check 'waiter: STOP file -> STOPPED, exit 3, no resume' ($jobOut -match 'STOPPED' -and $jobOut -match 'EXIT=3' -and $jobOut -cnotmatch 'RESUME:') ($jobOut -replace '\s+', ' ')

Reset-Env
@{ Since = (Get-Date).ToString('o'); UsedPercent = 98; ResetsAtUnix = [datetimeoffset]::Now.AddMinutes(10).ToUnixTimeSeconds(); Reason = 'test' } | ConvertTo-Json | Set-Content "$tmp/state\pause.json"
$out = pwsh -NoProfile -File "$root/Wait-ClaudeReset.ps1" -MaxWaitHours 0.0005 2>&1
Check 'waiter: gives up after MaxWaitHours, exit 4' ($LASTEXITCODE -eq 4 -and ($out -join '') -match 'GAVE UP')

# --- cleanup and report --------------------------------------------------------
Remove-Item Env:CUM_STATE_DIR, Env:CUM_FIXTURE_DIR, Env:CUM_CONFIG, Env:CUM_NO_TOAST -ErrorAction SilentlyContinue
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
$results | Format-Table -AutoSize -Wrap
$failed = @($results | Where-Object Result -eq 'FAIL').Count
Write-Host "$($results.Count - $failed)/$($results.Count) passed" -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
exit $failed
