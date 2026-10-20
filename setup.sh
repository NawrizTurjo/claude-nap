#!/usr/bin/env bash
# claude-nap one-line installer for Linux and macOS (experimental):
#
#   curl -fsSL https://raw.githubusercontent.com/NawrizTurjo/claude-nap/main/setup.sh | bash
#
# Options are passed to setup.ps1, e.g. turn on blocking right away:
#
#   curl -fsSL https://raw.githubusercontent.com/NawrizTurjo/claude-nap/main/setup.sh | bash -s -- -Enforce
set -euo pipefail

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[claude-nap] PowerShell 7 (pwsh) is required:"
  echo "  macOS:  brew install --cask powershell"
  echo "  Linux:  https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux"
  exit 1
fi

src="${CLAUDE_NAP_SETUP_PS1:-https://raw.githubusercontent.com/NawrizTurjo/claude-nap/main/setup.ps1}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [ -f "$src" ]; then cp "$src" "$tmp/setup.ps1"; else curl -fsSL "$src" -o "$tmp/setup.ps1"; fi
pwsh -NoProfile -File "$tmp/setup.ps1" "$@"