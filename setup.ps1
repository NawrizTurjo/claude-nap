<#
  claude-nap one-line installer / updater:

    irm https://raw.githubusercontent.com/NawrizTurjo/claude-nap/main/setup.ps1 | iex

  With options (e.g. turn on blocking right away):

    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/NawrizTurjo/claude-nap/main/setup.ps1))) -Enforce

  Linux/macOS (experimental): curl -fsSL https://raw.githubusercontent.com/NawrizTurjo/claude-nap/main/setup.sh | bash

  Downloads the latest release into %LOCALAPPDATA%\claude-nap or ~/.local/share/claude-nap (keeping config.local.json
  and state\ on updates), then runs Install.ps1 with PowerShell 7.
  Runs from Windows PowerShell 5.1 or PowerShell 7 (any OS).
#>
param(
    [switch]$Enforce,
    [string]$InstallDir,     # default: %LOCALAPPDATA%\claude-nap, or ~/.local/share/claude-nap
    [string]$Source,        # zip URL or local zip path; default: latest release
    [switch]$SkipSetup      # only download/extract (used by tests)
)
$ErrorActionPreference = 'Stop'
$repo = 'NawrizTurjo/claude-nap'

function Say($m, $c = 'Cyan') { Write-Host "[claude-nap] $m" -ForegroundColor $c }

$onWindows = $env:OS -eq 'Windows_NT'
if (-not $InstallDir) {
    $InstallDir = if ($onWindows) { Join-Path $env:LOCALAPPDATA 'claude-nap' }
                  else { Join-Path $(if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' }) 'claude-nap' }
}
if (-not $onWindows) { Say 'Linux/macOS support is experimental. Please report results: https://github.com/NawrizTurjo/claude-nap/issues' Yellow }

$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwsh -and -not $SkipSetup) {
    Say 'PowerShell 7 (pwsh) is required. Install it with:' Yellow
    Write-Host $(if ($onWindows) { '  winget install --id Microsoft.PowerShell --source winget' } else { '  https://learn.microsoft.com/powershell/scripting/install/installing-powershell  (macOS: brew install --cask powershell)' })
    Write-Host 'then open a new terminal and run the install command again.'
    return
}
if (-not (Get-Command claude -ErrorAction SilentlyContinue) -and -not $SkipSetup) {
    Say 'The Claude Code CLI is required. Install it with:' Yellow
    Write-Host $(if ($onWindows) { '  irm https://claude.ai/install.ps1 | iex' } else { '  curl -fsSL https://claude.ai/install.sh | bash' })
    Write-Host 'then sign in with your claude.ai account (claude, then /login) and run this again.'
    return
}

# Resolve what to download.
$tag = 'main'
if (-not $Source) {
    try {
        $tag = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'claude-nap-setup' }).tag_name
        $Source = "https://github.com/$repo/archive/refs/tags/$tag.zip"
    } catch {
        $Source = "https://github.com/$repo/archive/refs/heads/main.zip"
    }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("claude-nap-setup-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $work | Out-Null
try {
    $zip = Join-Path $work 'src.zip'
    if (Test-Path $Source) { Copy-Item $Source $zip } else {
        Say "Downloading $tag ..."
        Invoke-WebRequest $Source -OutFile $zip -UseBasicParsing
    }
    Expand-Archive $zip (Join-Path $work 'x') -Force
    $src = Get-ChildItem (Join-Path $work 'x') -Directory | Select-Object -First 1
    if (-not (Test-Path (Join-Path $src.FullName 'ClaudeUsageManager.psm1'))) { throw 'Downloaded archive does not look like claude-nap.' }

    # Replace program files; keep the user's overrides and runtime state.
    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    Get-ChildItem $InstallDir -Force | Where-Object { $_.Name -notin 'state', 'config.local.json' } | Remove-Item -Recurse -Force
    Get-ChildItem $src.FullName -Force | Copy-Item -Destination $InstallDir -Recurse -Force
    Say "Files installed to $InstallDir" Green
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($SkipSetup) { return }

$installArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $InstallDir 'Install.ps1'))
if ($Enforce) { $installArgs += '-Enforce' }
& $pwsh.Source @installArgs

Write-Host ''
Say 'Done. Next steps:' Green
Write-Host "  Try it:     pwsh -File `"$InstallDir\Start-NapTest.ps1`"   (real pause/resume in ~2 min)"
Write-Host "  Enforce:    pwsh -File `"$InstallDir\Install.ps1`" -Enforce"
Write-Host "  Uninstall:  pwsh -File `"$InstallDir\Uninstall.ps1`""
