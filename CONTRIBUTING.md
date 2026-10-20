# Contributing to claude-nap

Thanks for helping. The most useful contribution right now needs no code:
**a test report from Linux or macOS.**

## Test on your platform (about 10 minutes)

You need PowerShell 7 (`pwsh`) and the Claude Code CLI signed in with a claude.ai
subscription (Pro, Max, Team or Enterprise), not an API key.

```bash
# 1. Install (Linux/macOS). On Windows: irm https://raw.githubusercontent.com/NawrizTurjo/claude-nap/main/setup.ps1 | iex
curl -fsSL https://raw.githubusercontent.com/NawrizTurjo/claude-nap/main/setup.sh | bash
cd ~/.local/share/claude-nap

# 2. Simulated tests (no Claude calls, about 30 s)
pwsh -File tests/Test-UsageCheck.ps1
pwsh -File tests/Test-Manager.ps1

# 3. Live usage reading. Compare with claude.ai/settings/usage
pwsh -File Check-ClaudeUsage.ps1

# 4. Real pause/resume in about 2 minutes: arm, then ask Claude for any small task
pwsh -File Start-NapTest.ps1
```

In step 4, you should see Claude's next tool call denied, a checkpoint written, the
waiter started in the background, and about 90 seconds later the session waking up with
`RESUME`. Then open a [test report](https://github.com/NawrizTurjo/claude-nap/issues/new?template=test_report.yml)
with what happened.

Useful things to attach:
- Output of the commands above
- The last lines of `state/events.log` (it contains no secrets, but skim it first)
- OS version, `pwsh --version`, `claude --version`, your plan, and whether you used the CLI or an IDE extension

**Never share** tokens, `~/.claude/.credentials.json`, API keys, or full transcripts that
contain private code.

To undo everything: `pwsh -File Uninstall.ps1`, then delete the folder.

## Code changes

- Keep it dependency-free: PowerShell 7 only, the same scripts on every OS.
- Use `Join-Path` or `/` for paths. `\` breaks on Linux and macOS.
- Never guess usage. Anything unverified must become `UNKNOWN`.
- Don't read OAuth tokens or credential files, and don't add calls to undocumented web endpoints.
- Add or adjust tests in `tests/`. Both suites must pass:
  ```bash
  pwsh -File tests/Test-UsageCheck.ps1 && pwsh -File tests/Test-Manager.ps1
  ```
  They use fixture probes (`CUM_FIXTURE_DIR`), a temp state dir (`CUM_STATE_DIR`) and a temp
  config (`CUM_CONFIG`), so they never call Claude or touch your real install.
- One logical change per pull request, with a short description of what you tested and on which OS.

## Project layout

| Path | Purpose |
|---|---|
| `ClaudeUsageManager.psm1` | Probe, validation, gate decision, polling, pause state, notifications |
| `hooks/UsageGate.ps1` | `PreToolUse` hook entry point |
| `Wait-ClaudeReset.ps1` | Background waiter: confirms the reset, then exits so the session wakes |
| `Check-ClaudeUsage.ps1` | Human-facing usage check |
| `Start-NapTest.ps1` | Temporary test mode for a real 2-minute cycle |
| `Install.ps1` / `Uninstall.ps1` | Hook + skill registration in `~/.claude` |
| `setup.ps1` / `setup.sh` | One-line installers |
| `SKILL.md` | Instructions Claude follows when paused and resumed |
