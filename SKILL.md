---
name: claude-nap
description: Pause Claude Code work before the claude.ai 5-hour usage limit and resume the same task automatically after the reset. Use when a tool call is denied with a "[claude-nap]" message, when a background Wait-ClaudeReset.ps1 command finishes (its output starts with RESUME, STOPPED or GAVE UP), or when the user asks to check 5-hour usage, the reset time, or to install/test/uninstall the usage manager.
---

# Claude Usage Manager

A `PreToolUse` hook (the **gate**) checks the account's 5-hour usage before tool calls.
When usage reaches the stop threshold (default 98%), or is climbing fast enough to cross
it before the next check, the gate denies tool calls and tells you what to do. A background
PowerShell process (the **waiter**) sleeps until the reset, confirms it with a fresh probe,
and exits. Its exit wakes this session so you can resume.

All scripts live in this skill's base directory (shown as `<skill-dir>` below).

## Check usage on request

```powershell
pwsh -NoProfile -File "<skill-dir>\Check-ClaudeUsage.ps1"
```

Report the printed numbers as they are. If the status is `UNKNOWN`, say so and list the
reasons it printed. Never estimate a percentage or reset time yourself.

## When the gate denies a tool call

Read the denial text. It names the checkpoint path and the waiter command.

**If you are a subagent:** make no more tool calls. Return to your parent with what you
finished (with evidence such as file paths or test results) and what remains.

**If you are the main conversation:**

1. Don't retry the denied call, start other work, or spawn subagents.
2. Write the checkpoint file at the path the denial gives. Write it from what you already
   know, without reading more files. Use this template:

   ```markdown
   # Checkpoint
   - Paused at: <time>, usage <n>%, expected reset <time>
   ## Task as authorized
   <the user's request, quoted verbatim or as close as possible, plus any constraints they gave>
   ## Done (with evidence)
   - <item> - <evidence: file path, commit, test output>
   ## In progress
   - <item> - <exact state: which files are half-edited, what was about to happen next>
   ## Remaining
   - <item>
   ## Notes
   - <anything needed to continue safely: commands, decisions made, things NOT to do>
   ```

3. Start the waiter as a **background** shell command (`run_in_background: true`), using
   the exact command from the denial:
   `pwsh -NoProfile -File "<skill-dir>\Wait-ClaudeReset.ps1" -Checkpoint "<checkpoint path>"`
4. End your turn with one short line: work is paused until the reset, and where the
   checkpoint is.

Writing the checkpoint and starting the waiter are the only tool calls the gate allows
while paused.

## When the waiter finishes

The waiter's output ends with one of these:

- **`RESUME: ...`**: a fresh probe confirmed usage is below the threshold. Read the
  checkpoint, then:
  - Check the "Done" items against the actual files (for example `git status`, or check
    that a file or test exists) before relying on them. Don't redo work that is really done.
  - Finish the "In progress" item first. Re-check its file state, because an edit may
    have been partly applied.
  - Continue with "Remaining". Don't add scope the user didn't authorize.
  - Write a one-line note that you resumed, then continue.
- **`STOPPED: ...`**: the user created the STOP file. Don't resume. Say where work stopped.
- **`GAVE UP: ...`**: no confirmed reset within the wait limit. Don't resume. Tell the user.

## Other denials

- **"not spawning new subagents/workflows near the limit"**: usage is at 90% or more.
  Continue the task yourself in the main conversation, in small steps, without new subagents.
- **"Usage cannot be verified"**: the usage probe failed while the last reading was near
  the threshold. Try the next step once more. If it's denied again, follow the
  main-conversation steps above. The waiter probes on its own and resumes as soon as usage
  is confirmed below the threshold.
- **"STOP file present"**: the user asked for a halt. Stop, summarize, end the turn.

## Native auto-continue

Claude Code v2.1.234+ resumes on its own after it actually hits a usage limit
(`autoContinueAtUsageLimit`, interactive sessions only). This skill stops *before* the
limit, so that native wait doesn't start. If a burst overshoots the limit before the gate
reacts, the native wait takes over in interactive CLI sessions. Either way, you resume
from the checkpoint the same way.

## Setup

Installation, testing, configuration and removal for people are in `README.md` next to
this file. Requires PowerShell 7 (Windows verified; Linux and macOS experimental) and the
`claude` CLI on PATH, signed in with a claude.ai subscription (not an API key). The script
paths above use `\`; on Linux and macOS use `/`.
