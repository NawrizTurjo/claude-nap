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
$gate     = Join-Path $root 'hooks\UsageGate.ps1'
$pwsh     = (Get-Process -Id $PID).Path
$claudeDir = Join-Path $HOME '.claude'
$settings = Join-Path $claudeDir 'settings.json'
$skillLink = Join-Path $claudeDir 'skills\claude-nap'

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    throw 'claude CLI not found on PATH. Install it first: irm https://claude.ai/install.ps1 | iex'
}

# settings.json: back up, drop any previous gate entry, add the current one.
$json = if (Test-Path $settings) { Get-Content $settings -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
if (Test-Path $settings) {
    $backup = "$settings.cum-backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item $settings $backup
    Write-Host "Backed up settings.json -> $backup"
}
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

# Skill link (a junction needs no admin rights).
if (-not (Test-Path $skillLink)) {
    New-Item -ItemType Directory -Force (Split-Path $skillLink) | Out-Null
    New-Item -ItemType Junction -Path $skillLink -Target $root | Out-Null
    Write-Host "Linked skill: $skillLink -> $root"
}

if ($Enforce) {
    $cfgPath = Join-Path $root 'config.json'
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.DryRun = $false
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding utf8
    Write-Host 'DryRun disabled: the gate will now block tool calls at the threshold.' -ForegroundColor Yellow
} else {
    Write-Host 'DryRun is on (config.json): the gate only warns. Re-run with -Enforce to block for real.'
}

Write-Host "`nFirst usage check:"
& (Join-Path $root 'Check-ClaudeUsage.ps1')
Write-Host "`nRestart open Claude Code sessions (or run /hooks) so they pick up the hook."
