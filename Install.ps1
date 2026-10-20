#Requires -Version 7.0
<#
.SYNOPSIS
  Installs the usage gate hook into ~/.claude/settings.json and links the skill.
.DESCRIPTION
  - Backs up settings.json, then adds one PreToolUse hook (matcher "*") that runs
    hooks\UsageGate.ps1. Re-running replaces the old entry instead of duplicating it.
  - Links this folder as ~/.claude/skills/claude-nap.
  - Leaves DryRun as set in config.json; pass -Enforce to turn DryRun off.
  Applies to every Claude Code session on this machine (CLI and IDE extensions).
#>
param([switch]$Enforce)
$ErrorActionPreference = 'Stop'

$root     = $PSScriptRoot
$gate     = Join-Path $root 'hooks' 'UsageGate.ps1'
$pwsh     = (Get-Process -Id $PID).Path
$claudeDir = Join-Path $HOME '.claude'
$settings = Join-Path $claudeDir 'settings.json'
$skillLink = Join-Path $claudeDir 'skills' 'claude-nap'

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    $hint = if ($IsWindows) { 'irm https://claude.ai/install.ps1 | iex' } else { 'curl -fsSL https://claude.ai/install.sh | bash' }
    throw "claude CLI not found on PATH. Install it first: $hint"
}

# settings.json: back up, drop any previous gate entry, add the current one.
$json = if (Test-Path $settings) { Get-Content $settings -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
if (Test-Path $settings) {
    $backup = "$settings.cum-backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item $settings $backup
    Write-Host "Backed up settings.json -> $backup"
}
New-Item -ItemType Directory -Force $claudeDir | Out-Null   # fresh machines may not have it yet
if (-not $json.ContainsKey('hooks')) { $json.hooks = [ordered]@{} }
$pre = @($json.hooks.PreToolUse | Where-Object { $_ -and -not (($_ | ConvertTo-Json -Depth 10) -match 'UsageGate\.ps1') })
$pre += [ordered]@{
    matcher = '*'
    hooks   = @([ordered]@{
        type    = 'command'
        command = $pwsh
        args    = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gate)
        timeout = 60
    })
}
$json.hooks.PreToolUse = $pre
$json | ConvertTo-Json -Depth 20 | Set-Content $settings -Encoding utf8
Write-Host "Added PreToolUse usage gate to $settings"

# Skill link.
if (-not (Test-Path $skillLink)) {
    New-Item -ItemType Directory -Force (Split-Path $skillLink) | Out-Null
    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }   # a junction needs no admin rights
    New-Item -ItemType $linkType -Path $skillLink -Target $root | Out-Null
    Write-Host "Linked skill: $skillLink -> $root"
}

if ($Enforce) {
    # Personal overrides go to the git-ignored config.local.json, never the shipped config.json.
    $localPath = Join-Path $root 'config.local.json'
    $local = if (Test-Path $localPath) { Get-Content $localPath -Raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
    $local.DryRun = $false
    $local | ConvertTo-Json -Depth 5 | Set-Content $localPath -Encoding utf8
    Write-Host "DryRun disabled in $localPath : the gate will now block tool calls at the threshold." -ForegroundColor Yellow
} else {
    Write-Host 'DryRun is on: the gate only warns. Re-run with -Enforce to block for real.'
}

Write-Host "`nFirst usage check:"
& (Join-Path $root 'Check-ClaudeUsage.ps1')
Write-Host "`nRestart open Claude Code sessions (or run /hooks) so they pick up the hook."
