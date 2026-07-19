# Hook findings — limit-hit behavior

**STATUS: the measured formats we depend on — headless stdout limit message
(F1), session store layout (F2), resume flags (F3), and the status-line rate
stream (F4) — are documented below and in active use.**

> **The Stop/SessionEnd hook detection path was DROPPED on 2026-07-19.**
> It never worked (detection stayed a stub) and turned out to be
> unnecessary: the exact reset time comes from the **status-line rate
> stream** (F4, measured — *not* the hook payload), and a limit is otherwise
> confirmed by the F1 probe message; the session id to resume comes from the
> store (F2). The `on-stop.sh` hook, `setup-hooks`, and the payload-capture
> log were removed. The file name and the historical "Open questions" table
> below are kept for provenance — the findings F1–F4 are what the code cites.

Detection logic must cite this file and match only formats documented here.
No invented formats.

## Open questions (historical — the hook path was dropped, see note above)

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

### F2 — 2026-07-18 — Session store on disk (MEASURED)

Inspected `~/.claude/projects/` directly (macOS, Claude Code 2.1.214):

```
~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl
```

- `<encoded-cwd>` is the workspace's absolute path with every
  non-alphanumeric character replaced by `-`. Measured example:
  `/Users/sazzad/Documents/claude-auto-resume` →
  `-Users-sazzad-Documents-claude-auto-resume`. Only `/` and `.`-free
  paths were sampled locally; the general `[^A-Za-z0-9] → -` rule matches
  every project dir on this machine.
- One JSONL file per session; the filename (minus `.jsonl`) IS the session
  id accepted by `claude --resume <id>`.
- Non-session entries can live in the same dir (e.g. a `memory/` subdir) —
  session listing must filter to UUID-named `*.jsonl` files.
- Line format (sampled): objects with `"type"` (`user`, `assistant`,
  `file-history-snapshot`, `mode`, …), `"sessionId"`, `"timestamp"` (ISO,
  Z), `"cwd"`, and for user/assistant a `"message"` object with
  `role`/`content` (content = string or array of `{type:"text",text:...}`
  blocks). Command invocations appear as user lines whose text contains
  `<command-name>…` tags.
- File mtime tracks last activity — safe sort key for "most recent".
- Code citing this finding: `ar_project_dir` / `ar_sessions_list` in
  `plugin/scripts/lib.sh`, session listing in the VS Code extension.

### F3 — 2026-07-18 — Resume flags of the claude CLI (MEASURED)

From `claude --help`, Claude Code 2.1.214:

```
-r, --resume [value]   Resume a conversation by session ID, or open
                       interactive picker with optional search term
-c, --continue         Continue the most recent conversation in the
                       current directory
    --fork-session     When resuming, create a new session ID instead of
                       reusing the original (use with --resume or --continue)
```

- `-p/--print` is a boolean; the prompt is a positional argument, so
  `claude --resume <id> -p "<prompt>"` is a valid headless resume.
- `--continue` is NOT used by the daemon: its own probes (`claude -p ok`)
  run in the workspace directory and would become the "most recent
  conversation". The session id must be pinned at schedule time instead.
- Code citing this finding: `do_resume()` in `plugin/scripts/daemon.sh`,
  `plugin/scripts/task-resume-at.sh` session pinning.

### F4 — 2026-07-19 — Exact rate-limit state via the statusline (MEASURED)

Claude Code passes live rate-limit state to the **status line** command on
stdin (it does NOT write it to any standalone file, and — measured below —
it does NOT put it in Stop/SessionEnd hook payloads). Fields, read straight
from a working statusline (`~/.claude/statusline-command.sh`, Claude Code
2.1.214, macOS):

```
.rate_limits.five_hour.used_percentage      # integer 0..100
.rate_limits.five_hour.resets_at            # exact reset time
```

- `resets_at` sample: `1784462400` — a **Unix epoch** (= 2026-07-19
  18:00:00 +06). The reference statusline (line 203) also handles an ISO-8601
  form, so the raw value may be **epoch or ISO** depending on version;
  consumers must accept both.
- `used_percentage` sample: `19`, observed ticking `19 → 22` live while
  Claude Code ran — so the statusline is refreshed continuously and the
  value is current.
- This is the same data third-party monitors (e.g. Orca) display
  ("Session 18% used · resets in 3h 17m"). It matched F1's limit-message
  reset time and the account's real window.
- There is very likely also a `.rate_limits.weekly` (and per-model) window —
  Orca shows Weekly + a model cap — but only `five_hour` was read here; the
  weekly path name is **unconfirmed**.

**Measured negative — the hook does NOT carry this.** With hooks installed,
`~/.claude/auto-resume/logs/hook-payloads.log` held 815 captured
Stop/SessionEnd payloads (3.2 MB); grep for
`rate_limits|resets_at|five_hour|used_percentage` returned **zero**. So the
reset time is reachable from the **statusline surface only**, not the hook
sensor. This answers part of Q1/Q4: the Stop hook alone can't supply the
reset time.

**UNVERIFIED against a real limit (like C6):** the exact `used_percentage`
value at the moment Claude Code actually blocks is not measured (no limited
sample captured with the statusline). Detection defaults to "limited when
`used_percentage >= 100`" (`AR_LIMIT_PCT`, configurable) — conservative, but
confirm the true value on the next real limit hit. Also unknown: whether the
statusline keeps refreshing (and thus keeps `rate.json` fresh) once blocked.

- Code citing this finding: `plugin/scripts/statusline.sh` (the sensor that
  writes `~/.claude/auto-resume/rate.json`), `ar_rate_*` in
  `plugin/scripts/lib.sh`, the rate-aware auto path in
  `plugin/scripts/daemon.sh`, and `setup-statusline` registration.

## Status of the once-open plans

- ~~`on-stop.sh` `detect_limit()` gets real matching~~ — **obsolete**: the
  hook path was dropped 2026-07-19 (see the note at the top). Detection runs
  off F4 (rate stream) + the F1 probe message instead.
- `resume_at` parser is written against F1's measured format
  (`ar_parse_reset_time` in `plugin/scripts/lib.sh`).
- `test/fake-claude.sh` emits the F1 format (see DECISIONS D5).
- ~~supervisor-wrapper fallback if nothing fires~~ — **not needed**: nothing
  depends on a hook firing anymore.
