#Requires -Version 7.0
<#
.SYNOPSIS
  Runs a real pause/resume cycle in a few minutes instead of hours.
.DESCRIPTION
  Arms a temporary override (state\nap-test.json) for -Minutes. While it is active the gate:
    - enforces even in DryRun,
    - uses a stop threshold of your current usage + -AbovePercent (default 0 = stop at the next check),
    - records the "reset" as -FakeResetSeconds from the moment it trips.
  Everything else is real: live probes, the hook in your open sessions, the deny message,
  the checkpoint, the background waiter and the session wake-up. The waiter confirms with a
  real probe against your normal threshold, so it resumes because real usage is below
  StopThresholdPercent, then removes the override.
  Note: while armed, every Claude Code session on this machine is gated.
.EXAMPLE
  pwsh -File .\Start-NapTest.ps1            # arm; then ask Claude to do any small task
  pwsh -File .\Start-NapTest.ps1 -Cancel    # disarm and clear any test pause
#>
param(
    [double]$AbovePercent = 0,
    [int]$FakeResetSeconds = 60,
    [int]$Minutes = 15,
    [switch]$Cancel
)
Import-Module (Join-Path $PSScriptRoot 'ClaudeUsageManager.psm1') -Force

if ($Cancel) {
    Clear-CumNapTest
    $pause = Read-CumPause
    if ($pause -and $pause.Reason -match 'NAP TEST') { Clear-CumPause }
    Write-Host 'Nap test disarmed.'
    exit 0
}

$u = Get-ClaudeUsage
if ($u.Status -ne 'OK') {
    Write-Host "Cannot arm: usage is UNKNOWN ($($u.Problems -join '; '))." -ForegroundColor Yellow
    exit 20
}
$threshold = [math]::Floor($u.UsedPercent) + $AbovePercent
$expires = [datetimeoffset]::Now.AddMinutes($Minutes)
$test = [ordered]@{
    ThresholdPercent = $threshold
    FakeResetSeconds = $FakeResetSeconds
    ArmedAt          = [datetimeoffset]::Now.ToString('o')
    ExpiresAt        = $expires.ToString('o')
}
$test | ConvertTo-Json | Set-Content (Get-CumPath 'nap-test.json')
Write-CumLog "NAP TEST armed: threshold $threshold% (real usage $($u.UsedPercent)%), fake reset +$FakeResetSeconds s, expires $($expires.ToString('HH:mm:ss'))"

Write-Host "Nap test armed until $($expires.ToString('HH:mm:ss'))." -ForegroundColor Cyan
Write-Host "  Real usage now:    $($u.UsedPercent)%"
Write-Host "  Test threshold:    $threshold%"
Write-Host "  Fake reset:        $FakeResetSeconds s after the gate trips"
Write-Host "Ask Claude to do any small task. Expect: deny -> checkpoint -> background waiter -> RESUME."
Write-Host "Disarm early: pwsh -File `"$PSCommandPath`" -Cancel"
