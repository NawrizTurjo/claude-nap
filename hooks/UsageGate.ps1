#Requires -Version 7.0
# PreToolUse hook. Reads the hook JSON on stdin; prints a decision only when it
# blocks (or, in dry-run, when it would have). Any internal error allows the call,
# so a bug here can never wedge a session; errors are logged to state\events.log.
Import-Module (Join-Path $PSScriptRoot '..\ClaudeUsageManager.psm1') -Force
try {
    $hookInput = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $decision = Get-CumGateDecision -HookInput $hookInput
    if ($decision) { $decision | ConvertTo-Json -Depth 5 -Compress }
} catch {
    Write-CumLog "gate error (allowed the call): $($_.Exception.Message)"
}
exit 0
