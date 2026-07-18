# claude-auto-resume — User Guide

Everything you need to install, use, configure, and troubleshoot
claude-auto-resume. For design internals, see
[ARCHITECTURE.md](ARCHITECTURE.md).

## Contents

1. [Requirements](#1-requirements)
2. [Installation](#2-installation)
3. [Core concepts](#3-core-concepts)
4. [Workflows](#4-workflows)
5. [Command reference](#5-command-reference)
6. [Configuration](#6-configuration)
7. [Files and logs](#7-files-and-logs)
8. [Troubleshooting](#8-troubleshooting)
9. [FAQ](#9-faq)
10. [Uninstalling](#10-uninstalling)

---

## 1. Requirements

- **Claude Code** (the `claude` CLI; plugin support only needed for the
  optional detection hooks)
- **bash** (any modern version; the scripts avoid GNU-only and BSD-only
  constructs)
- **macOS or Linux**. Windows via Git Bash or WSL is best-effort:
  functional, but desktop notifications are written to the log instead.
- Optional: `jq` (recommended) or `python3`. Without either, a built-in
  pure-shell fallback handles state — slower and less robust, but working.

## 2. Installation

**One command** (recommended — installs the repo to `~/.claude-auto-resume`
and links the CLI into `~/.local/bin`, no root needed):

```sh
curl -fsSL https://raw.githubusercontent.com/0xsaju/claude-auto-resume/main/install.sh | bash
```

Re-running the same command updates the install. Uninstall with
`... | bash -s -- --uninstall` (your task state and logs are kept unless
you delete `~/.claude/auto-resume` yourself).

Verify:

```sh
cd ~/any/project
claude-auto-resume status
```

You should see "No tracked task for this workspace". If the command isn't
found, `~/.local/bin` isn't on your PATH — the installer printed the line
to add. Suggested alias for your shell rc: `alias car='claude-auto-resume'`.

If you'd rather work from your own clone, skip the installer and link the
CLI manually:

```sh
ln -s /path/to/claude-auto-resume/bin/claude-auto-resume ~/.local/bin/
```

### 2.1 The optional plugin (detection hooks)

The CLI is the whole control surface. The Claude Code plugin in this repo
contributes one thing: **hooks** that will detect a limit hit the moment it
happens — unattended, with the session id — and schedule the resume with no
human action. That detection is still in development (it's built only
against measured hook data), but you can install the plugin now so it's in
place when it lights up:

```text
/plugin marketplace add ~/.claude-auto-resume
/plugin install claude-auto-resume@auto-resume
```

(From a clone, use its path instead of `~/.claude-auto-resume`.) The
plugin adds no commands and costs no tokens; its hooks log to
`~/.claude/auto-resume/logs/plugin.log` and always exit cleanly.

## 3. Core concepts

**Workspace.** One tracked task per directory. All commands operate on the
directory Claude Code is running in.

**Importance tiers** decide what happens when the reset time arrives:

| Tier | At reset time |
|---|---|
| `critical` | Resumes immediately, no confirmation. |
| `normal` | Sends a notification, waits 60 seconds, then resumes — unless you `claude-auto-resume cancel` inside that window. |
| `low` | Sends a notification only. You resume manually. |

**The daemon.** Scheduling spawns a small background process that survives
your Claude Code session ending. It wakes every 60 seconds, re-reads state,
and acts when the reset time passes. Because it re-reads state each tick,
cancelling or rescheduling always takes effect within a minute. One daemon
per workspace; scheduling twice doesn't stack daemons.

**PROGRESS.md.** Keep one in your workspace. The default resume prompt is:

> Limit reset. Continue from where you stopped. Check PROGRESS.md first.

The better your PROGRESS.md, the better the resumed session performs. Ask
your tracked sessions to update it before they end.

**Safety rails.** A task is resumed at most `max_resumes` times (default 3).
If a resume attempt fails — most commonly because the limit hadn't actually
reset yet — the daemon backs off (5 min × attempt number by default) and
retries, still bounded by the cap. After the cap: status `failed`, you get
notified, nothing runs again until you reschedule.

## 4. Workflows

### 4.1 You just hit a limit (the common case)

Claude can't answer while you're limited — but the CLI doesn't need it.
From the project directory:

```sh
cd ~/my/project
claude-auto-resume resume-at
```

Output:

```text
Resume scheduled.
  workspace  : /Users/you/myproject
  resume at  : auto-detect (probing every 30 min until the limit lifts)
  importance : critical
  daemon     : running detached, wakes every 60s
```

You can close the terminal. The daemon makes one minimal, near-free `haiku`
probe call; while limited, that call returns the limit message — whose
format is measured, e.g. `You've hit your session limit · resets 4:10pm
(Asia/Dhaka)` — so the daemon reads the announced reset time out of it and
waits for exactly that moment. If the message can't be parsed, it falls
back to re-probing every 30 minutes. Either way: no reset time to look up
or type.

If you'd rather resume at an exact time (slightly cheaper — zero probe
calls — and precise to the minute), pass it explicitly:

```text
claude-auto-resume resume-at 20:00
```

| Input | Meaning |
|---|---|
| *(nothing)* or `auto` | Probe until the limit lifts, then resume |
| `20:00` | Next occurrence of 20:00 local time (today, or tomorrow if already past) |
| `2h30m`, `45m`, `3h` | Relative from now |
| `2026-07-18T20:00:00+0600` | Exact ISO-8601 timestamp |
| `now` | Immediately (useful for "just try again") |

A tier argument works with either form: `claude-auto-resume resume-at normal` (auto
mode) or `claude-auto-resume resume-at 20:00 normal`. A task scheduled on a previously
untracked workspace defaults to `critical` — you explicitly asked for a
resume, so it doesn't ask again.

Auto mode gives up after 6 hours of continuous limitation (configurable):
a 5-hour rolling window always resets within that; if it's still limited,
you've likely hit a **weekly cap**, which no amount of waiting today will
fix — you get a notification saying exactly that.

### 4.2 Track a long task before starting it

```text
claude-auto-resume start critical Migrate the billing service to the new API
```

This registers the workspace with a tier and your task description. Today,
tracking gives you `claude-auto-resume status` bookkeeping and means a later
`claude-auto-resume resume-at` keeps the tier and prompt you chose. Once automatic
detection ships, tracked tasks are the ones that will self-schedule at the
moment a limit hits, with no manual step.

### 4.3 Watch, cancel, reschedule

```text
claude-auto-resume status      # status, tier, attempts used, resume time, journal
claude-auto-resume cancel      # daemon stands down within one tick (≤ 60s)
claude-auto-resume resume-at 22:15   # reschedule — the running daemon picks it up
```

### 4.4 After a failure

If `claude-auto-resume status` shows `failed` (cap exhausted or unparseable state), fix
the cause, then reschedule with `claude-auto-resume resume-at <when>` — that resets the
task to `waiting` and the journal keeps the full history.

## 5. Command reference

### `claude-auto-resume resume-at [when] [critical|normal|low]`

Schedules an auto-resume for the current workspace and spawns the daemon.
With no `when` (or `auto`), the daemon probes until the limit lifts and
resumes then; with a time, it resumes at that time. Creates the task if the
workspace wasn't tracked (default tier `critical`); otherwise keeps the
existing tier unless you pass one. Re-running it reschedules — the running
daemon picks up the change within one tick.

### `claude-auto-resume start <critical|normal|low> <task description>`

Registers the current workspace as a tracked task with status `running`.
Resets the attempt counter. Does not spawn a daemon (nothing to wait for
yet).

### `claude-auto-resume status`

Shows status, tier, attempts used / cap, resume time (if scheduled), the
task prompt, and the last journal entries.

### `claude-auto-resume cancel`

Sets the task to `cancelled` and journals it. The daemon notices on its
next tick and stands down. Cancelling during a `normal` tier's 60-second
grace window aborts that resume.

### `claude-auto-resume log [n]` / `claude-auto-resume watch`

Show the last `n` lines (default 40) of the tool's log, or follow it live.

## 6. Configuration

Optional config file: `~/.claude/auto-resume/config` (plain shell,
`AR_CFG_*` variables only). Environment variables always override it.

| Config variable | Env override | Default | Purpose |
|---|---|---|---|
| `AR_CFG_CLAUDE_BIN` | `CLAUDE_AUTO_RESUME_CLAUDE_BIN` | `claude` | Binary the daemon invokes to resume |
| `AR_CFG_EXTRA_ARGS` | `CLAUDE_AUTO_RESUME_EXTRA_ARGS` | *(empty)* | Extra CLI args appended to the resume command (word-split) |
| — | `CLAUDE_AUTO_RESUME_STATE` | `~/.claude/auto-resume/state.json` | State file location |
| — | `AR_DAEMON_TICK_SECS` | `60` | Daemon wake interval |
| — | `AR_NORMAL_GRACE_SECS` | `60` | `normal` tier confirmation window |
| — | `AR_BACKOFF_BASE_SECS` | `300` | Backoff unit after a failed attempt |
| — | `AR_PROBE_INTERVAL_SECS` | `1800` | Auto mode: seconds between limit probes |
| `AR_CFG_PROBE_MODEL` | `AR_PROBE_MODEL` | `haiku` | Auto mode: model for the probe call |
| — | `AR_AUTO_GIVEUP_SECS` | `21600` | Auto mode: give up after this long still limited (6 h ≈ "must be a weekly cap") |
| — | `AR_NOTIFY_SILENT` | *(unset)* | Set to `1` to suppress desktop notifications |

Example config:

```sh
# ~/.claude/auto-resume/config
AR_CFG_EXTRA_ARGS="--allowedTools Edit,Read,Bash(npm:*)"
```

**Permissions note.** Resumed sessions run headless, so they need
pre-approved permissions to do real work. Configure an allowlist via
`AR_CFG_EXTRA_ARGS`. Do **not** put `--dangerously-skip-permissions` there
unless you fully understand the implications — the tool never adds it for
you.

## 7. Files and logs

| Path | What it is |
|---|---|
| `~/.claude/auto-resume/state.json` | All task state. Human-readable JSON; safe to inspect, edited only via the commands. |
| `~/.claude/auto-resume/logs/plugin.log` | Timestamped log of everything: hook firings, daemon ticks, resume attempts, errors. First stop when debugging. |
| `~/.claude/auto-resume/logs/hook-payloads.log` | Raw hook payloads + transcript tails captured at every session stop (feeds limit-detection development). |
| `~/.claude/auto-resume/daemons/*.pid` | One pidfile per waiting workspace; auto-removed when the daemon exits. |
| `~/.claude/auto-resume/config` | Optional configuration (see above). |

## 8. Troubleshooting

**Scheduled but nothing happened at reset time.**
Check `~/.claude/auto-resume/logs/plugin.log` for `daemon[<pid>]` lines. No
lines → the daemon never started (see next item). Lines ending in
`standing down` tell you exactly why it stopped.

**Is the daemon alive?**
`cat ~/.claude/auto-resume/daemons/*.pid` and `ps -p <pid>`. If the machine
rebooted while waiting, the daemon died with it — re-arm with
`claude-auto-resume resume-at <when>`. (Reboot-surviving schedules are on the roadmap.)

**Resume ran but the session did nothing useful.**
Check `last_output_tail` in state.json and your `PROGRESS.md`. Headless
sessions can't ask for permissions — if the tail shows permission refusals,
set an allowlist (section 6).

**It keeps retrying and failing.**
The journal (via `claude-auto-resume status`) shows each attempt's reason. A resume that
bounces off a still-active limit backs off automatically; hitting the cap
means the reset time you gave was too optimistic — schedule later.

**`claude-auto-resume status` says no task, but I scheduled one.**
Commands key by directory. Run them from the same directory you scheduled
from.

**Stale pidfile after a crash.**
Harmless — the next daemon detects the dead pid and replaces it.

## 9. FAQ

**Does this get me more quota?** No. It spends the quota you get at reset
without you having to be present. Weekly caps are unaffected by anything
this tool does.

**Does scheduling have to happen before the limit hits?** No — that's the
main flow: run `claude-auto-resume resume-at` *after* the limit, and you don't even need
to know the reset time. Pre-tracking with `claude-auto-resume start` just adds
bookkeeping and (soon) hook-based instant detection.

**What do the auto-mode probes cost?** Failed probes (limit still active)
are rejected calls and are believed to cost nothing. Each *successful*
probe costs one minimal `haiku` call — and in the normal case there are
exactly two probes total: one failed probe that reveals the reset time,
and one successful probe at that time confirming it before the resume. If
you want zero probe overhead, pass an explicit time.

**Why is automatic detection not built yet, when hooks exist?** Because the
payloads Claude Code emits at a limit hit are undocumented, and code built
on guessed payloads fails silently at the worst moment. We measure first
(`claude-limit-hook-probe/`), then build against the measurements
([HOOK-FINDINGS.md](HOOK-FINDINGS.md)).

**Can two workspaces wait at once?** Yes. Each gets its own daemon and its
own task entry.

**What happens if I suspend my laptop while waiting?** Fine. The daemon
compares wall-clock time on every wake, so it fires on the first tick after
the machine is awake past the reset time.

## 10. Uninstalling

```text
/plugin uninstall claude-auto-resume
```

Then remove runtime data if you want a clean slate:

```sh
rm -rf ~/.claude/auto-resume
```

Any waiting daemon exits on its next tick once the state file is gone.
