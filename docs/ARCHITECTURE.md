# Architecture

## Problem

Developers running long agentic Claude Code tasks hit usage limits mid-task
and must babysit the terminal waiting for reset. claude-auto-resume removes
the babysitting: it detects the limit hit, waits until the reset time, and
resumes the same session with proper context — with behavior graded by task
importance.

## Components, one contract

### Engine — portable scripts + daemon (`plugin/scripts/`)

All the logic: state access (lib.sh), the wait-and-resume daemon, the
task commands. Editor-agnostic plain bash.

### Control surface — terminal CLI (`bin/claude-auto-resume`)

The primary interface (D15/D17): a thin dispatcher over the engine
scripts. Zero token cost, and works while rate-limited — when nothing
needing a model turn can run.

### Sensor — status-line rate capture (`statusline.sh`)

Claude Code streams live usage — `rate_limits.five_hour.{used_percentage,
resets_at}` — to the status-line command on stdin (measured; HOOK-FINDINGS
F4). This optional sensor captures that into `rate.json` so the daemon can
schedule to the **exact** reset moment with no probe and no quota (D29).
Opt-in via `setup-statusline`, which **chains** (never clobbers) any
existing status line. The daemon also reads a pre-existing cache when one
is present (e.g. `/tmp/claude_rate_cache_$USER.json`), so many setups get
exact-reset detection with zero setup. Resolution order:
`CLAUDE_AUTO_RESUME_RATE_FILE` → `AR_CFG_RATE_SOURCE` → our `rate.json` →
the common `/tmp` cache. With no snapshot at all, auto mode falls back to
the `haiku` probe path. Note: this reset time is **not** in any Stop/
SessionEnd hook payload (F4 measured that; it's why the hook path was
dropped) — only the status-line stream carries it.

### Cockpit — VS Code extension (`vscode-extension/`)

A pure UI shell (MVP, run from source): status bar over the state file,
quick-pick actions, and install onboarding. Reads come from state.json;
writes go through the CLI (D21). It never spawns or parses Claude Code
itself.

### Contract — `~/.claude/auto-resume/state.json`

Everything the daemon knows lives here; anything a UI needs, it reads here.
The `commands` array is the UI→daemon channel (e.g.
`{"cmd": "resume-now", "workspace": "..."}`).

Schema changes require a `version` bump and an entry in `docs/DECISIONS.md`.

## state.json schema (v2)

```json
{
  "version": 2,
  "tasks": {
    "<workspace-abs-path>": {
      "session_id": "",
      "status": "running | limit-hit | waiting | resuming | done | failed | cancelled",
      "importance": "critical | normal | low",
      "original_prompt": "",
      "resume_at": "ISO-8601 with timezone",
      "resume_mode": "at | auto",
      "resume_count": 0,
      "max_resumes": 3,
      "resume_prompt_template": "Limit reset. Continue from where you stopped. Check PROGRESS.md first.",
      "last_output_tail": "",
      "progress_file": "PROGRESS.md",
      "limit_seen": "0 | 1 — a limit was actually observed (gates auto-mode resume, D27)",
      "limit_seen_at": "epoch when the limit was first observed (give-up window)",
      "armed_noted": "0 | 1 — the 'armed, waiting for a limit' note was journaled once",
      "armed_since": "epoch when arming began (bounds the armed window, D28)",
      "daemon_pid": "pid of the daemon that owns this task (interrupted-resume detection, D28)",
      "journal": [
        { "ts": "", "event": "limit-hit | resumed | done | failed | cancelled", "detail": "" }
      ]
    }
  },
  "commands": []
}
```

Field notes:

- **workspace key** — the absolute working directory at `claude-auto-resume start` time;
  one tracked task per workspace (see DECISIONS D3).
- **session_id** — the conversation to continue, discovered from the
  session store (HOOK-FINDINGS F2) and pinned at schedule time so the
  daemon's own probe calls can't hijack "most recent".
- **resume_at** — ISO-8601 with timezone so the daemon compares wall clock
  unambiguously across suspend/resume. In `auto` mode it holds the *next
  probe time* instead of a known reset time (D13).
- **resume_mode** (v2, D13) — `at` = resume at a known time; `auto` = probe
  with a minimal cheap call until the limit provably lifts, then resume.
  Absent field ⇒ `at` (v1 files stay readable).
- **resume_count / max_resumes** — safety rail C5; the daemon refuses to
  resume past the cap.
- **last_output_tail** — final transcript lines at stop time, used for
  resume-verification (fallback prompt) and for the UI.
- **journal** — append-only event history; the UI's timeline source.

## Two entry points into the wait-and-resume cycle

The daemon doesn't care *who* decided a resume is needed — it only reads
state. Two things write that state:

1. **Manual scheduling (D10):** the user saw the limit message and runs
   `claude-auto-resume resume-at <when>`. The command sets `status=waiting`
   + `resume_at` and spawns the daemon. No detection involved; the human is
   the detector.
2. **Auto detection (D13/D29):** `claude-auto-resume resume-at` with no
   time. The daemon knows the exact reset time from a local rate snapshot
   (HOOK-FINDINGS F4) and waits for it — zero probe cost; or, with no
   snapshot, it falls back to a minimal `claude -p "ok" --model haiku` probe
   that trusts the measured limit message (F1). Bounded by a give-up /
   armed window to catch weekly caps and stand down cleanly.

This is why the daemon could ship before detection: the state contract
decouples them.

## Lifecycle loop

1. You hit a limit and run `claude-auto-resume resume-at` (auto), or
   `resume-at <when>` for a known time. The command writes resume state
   (`status=waiting`, `resume_at`, the pinned `session_id`) and spawns a
   detached daemon (`nohup ... & disown`).
2. In auto mode the daemon learns the exact reset time from the local rate
   snapshot (F4), or falls back to a minimal probe that reads the measured
   limit message (F1). It waits for that reset (plus a safety buffer).
3. Daemon sleep-loops until `resume_at`: wake every 60 s and compare wall
   clock — never one long `sleep`, because laptop suspend breaks it.
4. Daemon resumes: `claude --resume <session_id> -p "<resume prompt>"` in
   headless mode with pre-approved permissions.
5. The resume finishes: task done, or another limit → schedule the next
   resume. Bounded by `max_resumes` and stuck detection (two consecutive
   resumes with no PROGRESS.md change → stop and notify).

## Importance tiers

| Importance | Behavior at reset |
|---|---|
| `critical` | Resume automatically, no confirmation |
| `normal`   | Notify, then auto-proceed after a 5-minute window (cancellable) |
| `low`      | Notify only; user resumes manually |

## Resume context strategy

Tasks maintain a `PROGRESS.md`. Resume prompts reference it, with a
two-stage fallback: if the resumed session seems confused, re-send the task
summary + PROGRESS.md contents.

## Detection: the C1 rule

Detection logic may only match formats **measured** and documented in
`docs/HOOK-FINDINGS.md` — never invented shapes. The formats we rely on are
F1 (the limit-hit **message** wording + announced reset time), F2 (the
session-store layout, for discovering the session id to resume), and F4 (the
status-line rate stream: `used_percentage` + exact `resets_at`). If a format
isn't measured there, the code doesn't parse it.

**Auto-mode detection (measured formats only).** A scheduled auto-detect
task detects and times a reset from local data documented in HOOK-FINDINGS,
never from invented shapes:

1. **Rate snapshot (F4) for the exact reset TIME.** If a rate snapshot is
   available (`rate.json` from the sensor, or a pre-existing cache — see the
   status-line sensor component), the daemon reads `used_percentage` and the
   exact `resets_at`. `used_percentage >= AR_LIMIT_PCT` (default 100) is taken
   as limited; it then waits for the exact reset — no probe, no quota. But the
   sensor's `used_percentage` at a real block is **unverified** (C6) and can
   under-report, so the daemon does **not** trust "not limited" from it: below
   the threshold, with no limit yet seen, it falls through to the probe below
   (F4 must not blind F1). It still stands down after `AR_ARMED_MAX_SECS` (C6).
2. **Probe (F1) as the detector.** The daemon fires one minimal `haiku` probe
   (whenever no snapshot exists, or the snapshot is below the limit threshold).
   A limit is trusted from the measured limit **message**, not the exit code
   (claude may exit 0 while limited). If the message announces a reset time
   (`…resets 4:10pm (Asia/Dhaka)`), the daemon waits for exactly that moment;
   otherwise it polls on `AR_PROBE_INTERVAL_SECS`.

Either way a resume only fires after a limit was actually **observed** and
then lifted (`limit_seen`) — scheduling auto-detect while healthy leaves the
task armed, never resuming into a live session (D27). The scheduled resume
time carries a post-reset safety buffer (`AR_RESET_GRACE_SECS`, default 60s):
attempting on the exact reset instant risks bouncing off a still-active limit
(clock skew, or the server rounding the window up), which would waste an
attempt.

## Window warm-up scheduling (phase 3)

An OS-level scheduled job (cron / launchd / Task Scheduler, managed by
`/warmup`) fires a minimal prompt (`claude -p "hi" --model haiku`) at a
user-chosen time so the 5-hour usage window starts earlier. This helps the
rolling window only, **not** weekly caps — UI and docs must say so honestly.

## Later phases

Usage burn-rate awareness, pre-limit checkpointing (force a PROGRESS.md
update at ~90% usage), model downshift, task queue.

## Testing strategy (C6)

Real quota is precious. All iterative testing runs against
`test/fake-claude.sh`, which mimics the claude CLI (`-p`, `--resume`,
`--output-format stream-json`) and can be told to run N seconds then hit a
limit, or finish clean, while emitting a realistic transcript. Real limit
burns are reserved for milestone verification.
