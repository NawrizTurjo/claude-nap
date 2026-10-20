#Requires -Version 7.0
# Removes the usage gate hook from ~/.claude/settings.json (after a backup), removes
# the skill link, and clears any pause. The tool folder itself is left in place.
$ErrorActionPreference = 'Stop'
$root      = $PSScriptRoot
$settings  = Join-Path $HOME '.claude' 'settings.json'
$skillLink = Join-Path $HOME '.claude' 'skills' 'claude-nap'

if (Test-Path $settings) {
    $json = Get-Content $settings -Raw | ConvertFrom-Json -AsHashtable
    if ($json.hooks -and $json.hooks.PreToolUse) {
        Copy-Item $settings "$settings.cum-backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
        $pre = @($json.hooks.PreToolUse | Where-Object { -not (($_ | ConvertTo-Json -Depth 10) -match 'UsageGate\.ps1') })
        if ($pre.Count) { $json.hooks.PreToolUse = $pre } else { $json.hooks.Remove('PreToolUse') }
        if (-not $json.hooks.Count) { $json.Remove('hooks') }
        $json | ConvertTo-Json -Depth 20 | Set-Content $settings -Encoding utf8
        Write-Host "Removed usage gate from $settings"
    }
}
if (Test-Path $skillLink) {
    (Get-Item $skillLink -Force).Delete()   # deletes the link only, never the target
    Write-Host "Removed skill link $skillLink"
}
Remove-Item (Join-Path $root 'state' 'pause.json') -ErrorAction SilentlyContinue
Write-Host "Done. To delete the tool itself: Remove-Item '$root' -Recurse -Force"
