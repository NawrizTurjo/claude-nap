#Requires -Version 7.0
<#
.SYNOPSIS
  Waits for the 5-hour window to reset, confirms it with a fresh probe, then exits.
.DESCRIPTION
  Meant to be started by Claude as a background shell command after the usage gate
  pauses work. Its exit re-invokes the Claude session that started it, and its last
  lines tell Claude what to do:
    RESUME   - fresh probe confirmed usage is below the threshold; continue from the checkpoint
    STOPPED  - the STOP file was found; do not resume
    GAVE UP  - no confirmed reset within MaxWaitHours; do not resume
  It never assumes the timer alone proves a reset: after the expected reset it probes,
  and keeps waiting (with backoff) while the server still reports the old window,
  the limit, or no data.
  Also usable in a terminal: Ctrl+C stops it.
  Exit codes: 0 RESUME, 3 STOPPED, 4 GAVE UP.
#>
param(
    [string]$Checkpoint,
    [double]$MaxWaitHours
)
Import-Module (Join-Path $PSScriptRoot 'ClaudeUsageManager.psm1') -Force
$config = Get-CumConfig
if (-not $PSBoundParameters.ContainsKey('MaxWaitHours')) { $MaxWaitHours = $config.MaxWaitHours }

function Say([string]$m) {
    $line = '[{0}] {1}' -f [datetimeoffset]::Now.ToString('HH:mm:ss'), $m
    Write-Output $line
    Write-CumLog "WAITER $m"
}

$deadline = [datetimeoffset]::Now.AddHours($MaxWaitHours)
$pause = Read-CumPause
if ($pause) {
    $target = [datetimeoffset]::FromUnixTimeSeconds([long]$pause.ResetsAtUnix).ToLocalTime()
} else {
    $u = Get-ClaudeUsage -Config $config
    if ($u.Action -eq 'CONTINUE') {
        Say "RESUME: usage is $($u.UsedPercent)% (below $($config.StopThresholdPercent)%), no wait needed. Continue the task from checkpoint: $Checkpoint"
        exit 0
    }
    $target = if ($u.ResetsAtLocal) { $u.ResetsAtLocal } else { [datetimeoffset]::Now.AddSeconds($config.RetrySeconds[0]) }
}

Say "Waiting for the 5-hour reset expected at $($target.ToString('yyyy-MM-dd HH:mm:ss zzz')). STOP file: $(Get-CumPath 'STOP')"
$nextProbe   = $target.AddSeconds($config.ResetGraceSeconds)
$preNotified = $false
$retryIndex  = 0

try {
    while ($true) {
        $now = [datetimeoffset]::Now
        if (Test-CumStopFile) {
            Say "STOPPED: STOP file found. Do not resume the task; tell the user it was stopped manually. Checkpoint: $Checkpoint"
            exit 3
        }
        if ($now -gt $deadline) {
            Say "GAVE UP: no confirmed reset within $MaxWaitHours h. Do not resume; tell the user. Checkpoint: $Checkpoint"
            Send-CumNotification 'Claude usage waiter gave up' "No confirmed reset within $MaxWaitHours h." $config
            exit 4
        }
        if (-not $preNotified -and $now -ge $target.AddMinutes(-$config.PreNotifyMinutes)) {
            $preNotified = $true
            Send-CumNotification 'Claude usage resets soon' "Expected reset at $($target.ToString('HH:mm:ss')). Will verify, then resume." $config
        }
        if ($now -ge $nextProbe) {
            $u = Get-ClaudeUsage -Config $config
            if ($u.Status -eq 'OK' -and $u.Action -eq 'CONTINUE') {
                Clear-CumPause
                Say "RESUME: reset confirmed by a fresh probe: $($u.UsedPercent)% used, next reset $($u.ResetsAtLocal.ToString('yyyy-MM-dd HH:mm:ss zzz')). Continue the previously authorized task from checkpoint: $Checkpoint . Verify completed items before skipping them; do not redo finished work or add new scope."
                Send-CumNotification 'Claude work resuming' "Usage $($u.UsedPercent)% after reset. Resuming from checkpoint." $config
                exit 0
            }
            $delay = $config.RetrySeconds[[math]::Min($retryIndex, $config.RetrySeconds.Count - 1)]
            $retryIndex++
            if ($u.Status -eq 'OK' -and $u.ResetsAtLocal -gt $target) {
                $target = $u.ResetsAtLocal
                $nextProbe = $target.AddSeconds($config.ResetGraceSeconds)
                $preNotified = $false
                Say "Still limited ($($u.UsedPercent)%, server status $($u.LimitStatus)); server now reports reset at $($target.ToString('HH:mm:ss zzz')). Waiting."
            } else {
                $nextProbe = [datetimeoffset]::Now.AddSeconds($delay)
                $state = if ($u.Status -eq 'OK') { "still at $($u.UsedPercent)%" } else { "UNKNOWN ($($u.Problems -join '; '))" }
                Say "Reset not confirmed yet: $state. Re-checking in $delay s."
            }
        }
        Start-Sleep -Seconds 1
    }
} finally {
    # Reached on Ctrl+C as well as on normal exits.
    Write-CumLog 'WAITER exited'
}
