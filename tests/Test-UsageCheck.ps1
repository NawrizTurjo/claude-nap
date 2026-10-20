#Requires -Version 7.0
# Simulated tests for the usage-check logic. No network, no claude calls.
Import-Module (Join-Path $PSScriptRoot '../ClaudeUsageManager.psm1') -Force

$now    = [datetimeoffset]::new(2026, 10, 20, 18, 0, 0, [timespan]::FromHours(6))
$config = Get-CumConfig
$config.StopThresholdPercent = 98
$config.MaxDataAgeSeconds    = 180
$fixtures = Join-Path ([IO.Path]::GetTempPath()) "cum-fixtures-$PID"
New-Item -ItemType Directory -Force $fixtures | Out-Null

function New-Fixture([string]$Name, $Utilization, $ResetsAt, [string]$Status = 'allowed', [string]$ApiKeySource = 'none', [switch]$NoEvent, [switch]$NoWindow) {
    $lines = @(@{ type = 'system'; subtype = 'init'; apiKeySource = $ApiKeySource } | ConvertTo-Json -Compress)
    if (-not $NoEvent) {
        $info = [ordered]@{ status = $Status; resetsAt = $ResetsAt; rateLimitType = 'five_hour'; overageStatus = 'rejected' }
        if (-not $NoWindow) { $info.unifiedWindows = @{ five_hour = @{ utilization = $Utilization; resetsAt = $ResetsAt } } }
        $lines += @{ type = 'rate_limit_event'; rate_limit_info = $info } | ConvertTo-Json -Compress -Depth 5
    }
    $lines += '{"type":"result","subtype":"success"}'
    $path = Join-Path $fixtures "$Name.jsonl"
    Set-Content $path $lines
    $path
}

$inTwoHours = $now.AddHours(2).ToUnixTimeSeconds()
$results = [System.Collections.Generic.List[object]]::new()

function Test-Case([string]$Name, [string]$Fixture, [string]$ExpectStatus, [string]$ExpectAction, $ProbedAt = $now, $Now = $now, $ExpectUsed) {
    $u = Get-ClaudeUsage -FixturePath $Fixture -Now $Now -FixtureProbedAt $ProbedAt -Config $config
    $ok = $u.Status -eq $ExpectStatus -and $u.Action -eq $ExpectAction
    if ($PSBoundParameters.ContainsKey('ExpectUsed')) { $ok = $ok -and $u.UsedPercent -eq $ExpectUsed }
    if ($ExpectStatus -eq 'UNKNOWN') { $ok = $ok -and $null -eq $u.UsedPercent -and $null -eq $u.ResetsAtLocal }
    $results.Add([pscustomobject]@{
        Result = if ($ok) { 'PASS' } else { 'FAIL' }; Case = $Name
        Got = "$($u.Status)/$($u.Action) used=$($u.UsedPercent)"; Why = ($u.Problems -join '; ')
    })
}

Test-Case '97% -> continue'            (New-Fixture u97 0.97 $inTwoHours)              OK CONTINUE -ExpectUsed 97
Test-Case '98% -> stop'                (New-Fixture u98 0.98 $inTwoHours)              OK STOP     -ExpectUsed 98
Test-Case '97.9% -> continue'          (New-Fixture u979 0.979 $inTwoHours)            OK CONTINUE -ExpectUsed 97.9
Test-Case 'server rejected at 95%'     (New-Fixture rej 0.95 $inTwoHours 'rejected')   OK STOP
Test-Case 'missing: no event'          (New-Fixture none 0 0 -NoEvent)                 UNKNOWN UNKNOWN
Test-Case 'missing: no 5h window'      (New-Fixture nowin 0 $inTwoHours -NoWindow)     UNKNOWN UNKNOWN
Test-Case 'missing: null utilization'  (New-Fixture nullu $null $inTwoHours)           UNKNOWN UNKNOWN
Test-Case 'missing: null reset'        (New-Fixture nullr 0.5 $null)                   UNKNOWN UNKNOWN
Test-Case 'bad: utilization as text'   (New-Fixture text '0.5' $inTwoHours)            UNKNOWN UNKNOWN
Test-Case 'bad: utilization 250%'      (New-Fixture huge 2.5 $inTwoHours)              UNKNOWN UNKNOWN
Test-Case 'bad: reset > 5h away'       (New-Fixture far 0.5 $now.AddHours(9).ToUnixTimeSeconds()) UNKNOWN UNKNOWN
Test-Case 'bad: API-key auth'          (New-Fixture api 0.5 $inTwoHours -ApiKeySource 'ANTHROPIC_API_KEY') UNKNOWN UNKNOWN
Test-Case 'stale: probed 10 min ago'   (New-Fixture stale 0.5 $inTwoHours)             UNKNOWN UNKNOWN -ProbedAt $now.AddMinutes(-10)
Test-Case 'fresh enough: 2 min old'    (New-Fixture fresh 0.5 $inTwoHours)             OK CONTINUE -ProbedAt $now.AddMinutes(-2)

# Delayed reset: the expected reset time (18:00) has passed.
$expectedReset = $now.AddMinutes(-1).ToUnixTimeSeconds()
Test-Case 'delayed: old window still reported' (New-Fixture dly1 0.99 $expectedReset 'rejected') UNKNOWN UNKNOWN
Test-Case 'delayed: server moved reset later'  (New-Fixture dly2 1.0 $now.AddMinutes(20).ToUnixTimeSeconds() 'rejected') OK STOP
Test-Case 'after reset: fresh window at 2%'    (New-Fixture post 0.02 $now.AddHours(5).ToUnixTimeSeconds()) OK CONTINUE -ExpectUsed 2

# Threshold is configurable.
$config.StopThresholdPercent = 90
Test-Case 'threshold 90: 92% -> stop'  (New-Fixture u92 0.92 $inTwoHours)              OK STOP
$config.StopThresholdPercent = 98

# Safety: an API key in the environment must block the live probe before claude runs.
$saved = $env:ANTHROPIC_API_KEY
$env:ANTHROPIC_API_KEY = 'sk-test-not-real'
$u = Get-ClaudeUsage -Config $config
$env:ANTHROPIC_API_KEY = $saved
$results.Add([pscustomobject]@{
    Result = if ($u.Status -eq 'UNKNOWN' -and ($u.Problems -join '') -match 'refusing' -and ($u.Problems -join '') -notmatch 'sk-test') { 'PASS' } else { 'FAIL' }
    Case = 'API key in env blocks probe, key not echoed'; Got = "$($u.Status)/$($u.Action)"; Why = ($u.Problems -join '; ')
})

Remove-Item $fixtures -Recurse -Force
$results | Format-Table -AutoSize -Wrap
$failed = @($results | Where-Object Result -eq 'FAIL').Count
Write-Host "$($results.Count - $failed)/$($results.Count) passed" -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
exit $failed
