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

### Sensor — Claude Code hooks (`on-stop.sh`)

Hooks fire when a session stops — the one mechanism that can detect a
limit hit unattended and capture the session_id for a true `--resume`.
Detection logic is stubbed until HOOK-FINDINGS has the payload data (C1).
Canonical registration is **directly in `~/.claude/settings.json`** via
`setup-hooks` (D20), done automatically by the installer; the Claude Code
plugin (`plugin/hooks/`) packages the same hooks as an alternative — use
one or the other, never both.

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
- **session_id** — filled from hook payloads once a session stops (hooks
  receive it; the CLI has no way to know it). Empty until then.
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

1. **Manual scheduling (implemented — D10):** the user saw the limit
   message and runs `claude-auto-resume resume-at <when>`. The command sets
   `status=waiting` + `resume_at` and spawns the daemon. No detection
   involved; the human is the detector.
2. **Probe-based auto detection (implemented — D13):** `claude-auto-resume resume-at`
   with no time. The daemon fires a minimal `claude -p "ok" --model haiku`
   every 30 min; while limited it fails, and the first success means the
   limit has provably reset — exit-code-only, so C1 is untouched. Bounded
   by a give-up window (default 6 h) to catch weekly caps.
3. **Hook-based detection (Phase 1, blocked on HOOK-FINDINGS.md):**
   `on-stop.sh` recognizes the limit in the hook payload/transcript, writes
   the same fields, spawns the same daemon. This upgrades auto mode from
   "poll every 30 min" to "know the exact reset time instantly, zero probe
   cost" — same state contract, same daemon.

This is why the daemon could ship before detection: the state contract
decouples them.

## Lifecycle loop

1. User starts a tracked task: `claude-auto-resume start <importance> <prompt>`.
2. Session runs. If the limit hits, the session stops → **Stop/SessionEnd
   hook** fires → `on-stop.sh` inspects the transcript tail.
3. Not a limit? Mark the task done. Limit? Write resume state (`limit-hit`,
   `resume_at`), notify the user, spawn a detached daemon
   (`nohup ... & disown`).
4. Daemon sleep-loops until `resume_at`: wake every 60 s and compare wall
   clock — never one long `sleep`, because laptop suspend breaks it.
5. Daemon resumes: `claude --resume <session_id> -p "<resume prompt>"` in
   headless mode with pre-approved permissions.
6. The resumed session ends → hook fires again → the loop closes: task done,
   or another limit hit → schedule the next resume. Bounded by `max_resumes`
   and stuck detection (two consecutive resumes with no PROGRESS.md change →
   stop and notify).

## Importance tiers

| Importance | Behavior at reset |
|---|---|
| `critical` | Resume automatically, no confirmation |
| `normal`   | Notify, then auto-proceed after a 60 s window |
| `low`      | Notify only; user resumes manually |

## Resume context strategy

Tasks maintain a `PROGRESS.md`. Resume prompts reference it, with a
two-stage fallback: if the resumed session seems confused, re-send the task
summary + PROGRESS.md contents.

## Detection: the C1 rule

Which hooks fire on a limit hit — and what their payloads and the transcript
contain — is **unknown until measured on a real limit hit**. The registered
hooks capture every Stop/SessionEnd payload to
`~/.claude/auto-resume/logs/hook-payloads.log`; results land in
`docs/HOOK-FINDINGS.md`. All detection logic must match only against
documented findings. Until then, `on-stop.sh`'s detection is a
clearly-marked stub.

**Fallback design:** if findings show hooks don't fire on limit-hit, we
switch to a supervisor wrapper script that launches and watches the claude
process. `on-stop.sh` is structured so only its *trigger* changes (hook vs
supervisor); the daemon and state logic stay identical.

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
