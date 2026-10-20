# Changelog

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
