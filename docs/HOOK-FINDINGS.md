# Hook findings — limit-hit behavior

**STATUS: PARTIALLY VERIFIED — headless stdout format measured (F1); hook
payloads and transcript format still unmeasured.**

All detection code must stay stubbed (TODO(C1) markers in
`plugin/scripts/on-stop.sh`) until the **Findings** section below contains
real probe output. Detection logic must cite this file and match only
formats documented here. No invented payload shapes.

## How to produce the data

Use the instrumentation plugin in `claude-limit-hook-probe/` (see its
README). Short version:

1. Install the probe hooks (copy hook blocks into `~/.claude/settings.json`
   or install the folder as a local plugin).
2. Verify liveness: run a trivial prompt, check
   `~/.claude/limit-hook-probe/hooks.log` shows SessionStart/Stop entries.
3. Near the end of a usage window, run a real agentic task until the limit
   message appears. Note the wall-clock time.
4. Repeat once in headless mode if affordable:
   `claude -p "…" --output-format stream-json`.
5. Paste the relevant `hooks.log` excerpts into **Findings** below.

## Open questions

| # | Question | Why it matters | Answer |
|---|---|---|---|
| Q1 | Does `Stop` fire at the limit hit? | If yes, detection is trivial and instant | *unknown* |
| Q2 | Does `SessionEnd` fire, and with what `reason` value? | A distinct reason = clean structured detection | *unknown* |
| Q3 | Does only `Notification` carry the limit message? | Then Notification becomes the detection point | *unknown* |
| Q4 | Does the transcript tail contain the limit text + reset time? | That's the parse source for `resume_at` | *unknown* |
| Q5 | Exact wording/format of the limit message and reset timestamp? | Drives the `resume_at` parser and fake-claude fixture | **F1** for headless stdout; hooks/transcript pending |
| Q6 | Same behavior in headless (`-p`) mode as interactive? | The daemon resumes headlessly; detection must work there | *unknown* |
| Q7 | Does *nothing* fire? | Then we switch to the supervisor-wrapper fallback (see ARCHITECTURE.md) | *unknown* |

## Findings

### F1 — 2026-07-18 — Headless stdout limit message (MEASURED)

User ran `claude -p "ok" --model haiku` on an already-limited subscription
(headless, macOS, zsh). Stdout:

```
You've hit your session limit · resets 4:10pm (Asia/Dhaka)
```

- Format: `You've hit your session limit · resets <h:mm(am|pm)> (<IANA zone>)`
  — 12-hour clock, no date, IANA timezone name in parentheses, `·` (U+00B7)
  separator.
- Answers **Q5 for the headless stdout surface only**.
- **Exit code: NOT yet measured.** The first capture piped through `tee`,
  so `$?` reported tee's status. Re-run needed:
  `claude -p "ok" --model haiku >/dev/null 2>&1; echo $?`
  Until measured, all detection treats exit codes as unreliable and matches
  the message text as well.
- Detection code citing this finding: `AR_LIMIT_PATTERN` in
  `plugin/scripts/lib.sh` (`hit your session limit`),
  `ar_parse_reset_time()` in lib.sh, and the probe/resume-bounce checks in
  `plugin/scripts/daemon.sh`.
- One sample; wording may differ for weekly caps or other limit types —
  capture those when seen.
- Hook payloads and transcript format: still unmeasured (Q1–Q4, Q6–Q7 open).

## Consequences once filled

- `plugin/scripts/on-stop.sh` `detect_limit()` gets real matching.
- `resume_at` parser written against Q5's exact format.
- `test/fake-claude.sh` fixture text updated from GUESSED to the real
  format (see DECISIONS D5).
- If Q7 is "yes, nothing fires": build the supervisor wrapper; on-stop.sh
  keeps its shape, only the trigger changes.
