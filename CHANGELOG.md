# Changelog

## 0.3.0 - 2026-10-20

- Experimental **Linux and macOS** support: the same PowerShell 7 scripts, `setup.sh` one-liner,
  `~/.local/share/claude-nap`, symlinked skill, `notify-send` / `osascript` notifications.
  All 56 tests pass on Ubuntu 24.04 (WSL); live use on Linux/macOS is not verified yet.
- Fix: `Install.ps1` failed on a fresh machine without `~/.claude`.
- `CONTRIBUTING.md`, issue forms for platform test reports and bugs.

## 0.2.1 - 2026-10-20

- One-line install/update: `irm https://raw.githubusercontent.com/NawrizTurjo/claude-nap/main/setup.ps1 | iex`.
  Works from Windows PowerShell 5.1 or 7 and keeps `config.local.json` and `state\` on update.

## 0.2.0 - 2026-10-20

- `Start-NapTest.ps1`: run a real pause/resume cycle in about 2 minutes (temporary threshold =
  current usage, fake reset). Verified end to end in the VS Code extension on a Team plan.
- Demo GIF built from that run's real output.
- Fix: `Time to reset` printed as `0h m s`.
- Personal overrides go in git-ignored `config.local.json`; `Install.ps1 -Enforce` writes there.
- Social preview card: `docs/social-preview.png`.
- Tests: 56 cases.

## 0.1.0 - 2026-10-20

First release.

- `Check-ClaudeUsage.ps1`: 5-hour usage, remaining, reset time, time to reset, data source and
  check time, read from Claude Code's `rate_limit_event`. Unverifiable data is reported as `UNKNOWN`.
- `PreToolUse` gate with a 98% threshold, dynamic polling, predictive stop and a 90% block on
  new subagent spawns. Dry-run by default.
- `Wait-ClaudeReset.ps1`: waits for the reset, confirms it with a fresh probe, retries delayed
  resets, and supports a STOP file and Ctrl+C.
- Windows toast notifications at the threshold, before the reset, and on resume.
- `SKILL.md` with the checkpoint and resume procedure for Claude.
- Simulated tests: 52 cases, with no Claude calls.
