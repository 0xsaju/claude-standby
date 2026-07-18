# Hook findings — limit-hit behavior

**STATUS: PARTIALLY VERIFIED — headless stdout format measured (F1); hook
payloads and transcript format still unmeasured.**

All detection code must stay stubbed (TODO(C1) markers in
`plugin/scripts/on-stop.sh`) until the **Findings** section below contains
real probe output. Detection logic must cite this file and match only
formats documented here. No invented payload shapes.

## How to produce the data

Capture is automatic: with the hooks registered (`setup-hooks` or the
plugin), `on-stop.sh` appends every Stop/SessionEnd payload plus a 40-line
transcript tail to `~/.claude/auto-resume/logs/hook-payloads.log`. After a
limit hit, copy the entries around that timestamp into **Findings** below
(note whether the session was interactive or headless).

Contributors welcome: if you hit a limit with the hooks installed, a
sanitized excerpt of that log is the single most valuable contribution
this project can receive — see CONTRIBUTING.md.

Caveat: only Stop and SessionEnd are captured. If a real limit hit shows
nothing on those events (Q7), temporarily add SessionStart/Notification
hooks the same way to answer Q3. (A standalone probe plugin that captured
all four events existed early on; it was removed once capture moved into
on-stop.sh — see git history if needed.)

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
