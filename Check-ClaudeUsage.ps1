#Requires -Version 7.0
<#
.SYNOPSIS
  Prints the current Claude Code 5-hour usage, reset time and data source.
.DESCRIPTION
  Default: runs a fresh probe (one tiny Haiku turn on your subscription login).
  -FromCache: re-evaluates the last saved reading without probing (age-checked).
  -Json: emits the result as JSON instead of the table.
  Exit codes: 0 = below threshold, 10 = at/above threshold, 20 = UNKNOWN.
#>
param(
    [switch]$FromCache,
    [switch]$Json,
    [double]$Threshold
)
Import-Module (Join-Path $PSScriptRoot 'ClaudeUsageManager.psm1') -Force

$config = Get-CumConfig
if ($PSBoundParameters.ContainsKey('Threshold')) { $config.StopThresholdPercent = $Threshold }

$usage = Get-ClaudeUsage -FromCache:$FromCache -Config $config
if ($Json) {
    $usage | Select-Object Status, Action, UsedPercent, RemainingPercent,
        @{n='ResetsAtLocal';e={ if ($_.ResetsAtLocal) { $_.ResetsAtLocal.ToString('o') } }},
        @{n='TimeToReset';e={ Format-CumDuration $_.TimeToReset }},
        ThresholdPercent, LimitStatus, Source,
        @{n='CheckedAt';e={ if ($_.CheckedAt) { $_.CheckedAt.ToString('o') } }},
        DataAgeSeconds, Problems | ConvertTo-Json
} else {
    Show-ClaudeUsage $usage
}

exit $(switch ($usage.Action) { 'CONTINUE' { 0 } 'STOP' { 10 } default { 20 } })
