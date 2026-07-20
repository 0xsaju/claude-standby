# claude-standby — User Guide

Everything you need to install, use, configure, and troubleshoot
claude-standby. For design internals, see
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

- **Claude Code** (the `claude` CLI)
- **bash** (any modern version; the scripts avoid GNU-only and BSD-only
  constructs)
- **macOS or Linux**. Windows via Git Bash or WSL is best-effort:
  functional, but desktop notifications are written to the log instead.
- Optional: `jq` (recommended) or `python3`. Without either, a built-in
  pure-shell fallback handles state — slower and less robust, but working.

## 2. Installation

**One command** (recommended — installs the tool to `~/.claude-standby`
and links the CLI into `~/.local/bin`, no root needed):

```sh
curl -fsSL https://raw.githubusercontent.com/0xsaju/claude-standby/main/install.sh | bash
```

That single command sets up everything: the CLI on your PATH. After that the
tool manages itself: `claude-standby update` / `uninstall` / `doctor`.
(Re-running the curl command also updates; `... | bash -s -- --uninstall`
also uninstalls.)

Verify:

```sh
cd ~/any/project
claude-standby status
```

You should see "No tracked task for this workspace". If the command isn't
found, `~/.local/bin` isn't on your PATH — the installer printed the line
to add. Suggested alias for your shell rc: `alias cs='claude-standby'`.

If you'd rather work from your own clone, skip the installer and link the
CLI manually:

```sh
ln -s /path/to/claude-standby/bin/claude-standby ~/.local/bin/
```

### 2.1 How detection works (no setup required)

The CLI is the whole control surface — the install is just the CLI on your
PATH, nothing written to `~/.claude/settings.json`. You arm the tool for a
task by scheduling a resume (`claude-standby resume-at auto`); from then
on a small background daemon watches for the reset and continues your
conversation.

To find the reset time, the daemon prefers your **local rate snapshot** —
Claude Code streams your live usage and exact reset (`used_percentage`,
`resets_at`) to its status line, and many setups already cache it on disk
(HOOK-FINDINGS F4). When that data is present, auto-detect schedules to the
exact reset with **zero setup and no quota**. If nothing local carries it,
run `claude-standby setup-statusline` (opt-in — see §3 and §5) to install
a tiny sensor, or fall back to a single limit-message probe (HOOK-FINDINGS
F1). The conversation to resume is discovered from the Claude Code session
store (HOOK-FINDINGS F2) and pinned at schedule time.

## 3. Core concepts

**Workspace.** One tracked task per directory. All commands operate on the
directory Claude Code is running in.

**Importance tiers** decide what happens when the reset time arrives:

| Tier | At reset time |
|---|---|
| `critical` | Resumes immediately, no confirmation. |
| `normal` | Sends a notification, waits 5 minutes, then resumes — unless you `claude-standby cancel` inside that window. |
| `low` | Sends a notification only. You resume manually. |

**The daemon.** Scheduling spawns a small background process that survives
your Claude Code session ending. It wakes every 60 seconds, re-reads state,
and acts when the reset time passes. Because it re-reads state each tick,
cancelling or rescheduling always takes effect within a minute. One daemon
per workspace; scheduling twice doesn't stack daemons.

**Exact reset detection (no polling).** Claude Code streams your live
usage — `used_percentage` and the exact `resets_at` — to its status-line
command. When that data is available locally, auto mode reads it and
schedules the resume for the **exact** reset moment, with no probe and no
quota spent. Many setups already cache this (e.g. a status-line script that
writes `/tmp/claude_rate_cache_$USER.json`), in which case it works with
**zero setup** — `claude-standby doctor` shows the reset time it found.
If nothing local has it, run `claude-standby setup-statusline` to
install a tiny sensor, or point the tool at your own cache with
`AR_CFG_RATE_SOURCE` (see §6). With no rate data at all, auto mode falls
back to probing (below).

The resume fires a short **safety buffer after** the reset (default 60s,
`AR_RESET_GRACE_SECS`), never on the exact instant — a resume attempted a
second early bounces off a still-active limit and wastes an attempt. (Even
if it does bounce, the daemon backs off and retries, bounded by
`max_resumes`.)

**Resume prompt.** The default resume prompt is:

> Limit reset. Continue from where you stopped.

The resumed session continues your conversation (`--resume`), so it already
has its context. If your project keeps a progress/handoff file, a custom
`--prompt` pointing at it makes resumes even more reliable.

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
claude-standby resume-at reset
```

`reset` means "I just hit a limit — resume at the reset time my usage data
already knows." It reads the exact reset straight from local data and
schedules a precise, quota-free resume; because *you* confirmed the limit,
it never has to guess from a usage percentage. Output:

```text
Resume scheduled.
  workspace  : /Users/you/myproject
  resume at  : 2026-07-18T20:00:00+0600 (~184 min) — exact reset from your usage data +60s
  session    : 612fb08b — the original conversation continues (claude --resume)
  importance : critical
  daemon     : running detached, wakes every 60s
```

(If no local reset time is available yet, `reset` tells you so and points you
at `resume-at auto` or `setup-statusline` — see the table below.)

Note the `session` line: the resume **continues the conversation that got
interrupted**, via `claude --resume <session-id>` — it does not open a new
chat. By default the workspace's most recent session is pinned. To pick a
different one:

```text
claude-standby sessions          # numbered list, newest first
claude-standby resume-at auto --session 2
```

`--session` also accepts a session id (or unique prefix), `latest`, or
`new` (deliberately start a fresh chat). The id is pinned at schedule
time, so the daemon's own probe calls can never hijack "most recent".

You can also choose *what the resumed session is told* and *which project
this is for* — all in one command:

```text
claude-standby resume-at auto --session 2 \
  --prompt "Continue the migration; skip the seeding step we discussed" \
  --workspace ~/projects/other-app
```

`--prompt` replaces the default resume message ("Limit reset. Continue
from where you stopped.") for this task from now on; `--workspace`
schedules for another project directory without cd-ing there.

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
claude-standby resume-at 20:00
```

| Input | Meaning |
|---|---|
| `reset` | You hit a limit: resume at the exact reset time from your local usage data (+ a safety buffer), no probe. The everyday choice. |
| *(nothing)* or `auto` | Arm and watch: resume whenever a limit hits and then lifts (uses live usage, or a probe when there's no local data) |
| `20:00` | Next occurrence of 20:00 local time (today, or tomorrow if already past) |
| `2h30m`, `45m`, `3h` | Relative from now |
| `2026-07-18T20:00:00+0600` | Exact ISO-8601 timestamp |
| `now` | Immediately (useful for "just try again") |

A tier argument works with either form: `claude-standby resume-at normal` (auto
mode) or `claude-standby resume-at 20:00 normal`. A task scheduled on a previously
untracked workspace defaults to `critical` — you explicitly asked for a
resume, so it doesn't ask again.

Auto mode gives up after 6 hours of continuous limitation (configurable):
a 5-hour rolling window always resets within that; if it's still limited,
you've likely hit a **weekly cap**, which no amount of waiting today will
fix — you get a notification saying exactly that.

### 4.2 Track a long task before starting it

```text
claude-standby start critical Migrate the billing service to the new API
```

This registers the workspace with a tier and your task description. Today,
tracking gives you `claude-standby status` bookkeeping and means a later
`claude-standby resume-at` keeps the tier and prompt you chose. Once automatic
detection ships, tracked tasks are the ones that will self-schedule at the
moment a limit hits, with no manual step.

### 4.3 Watch, cancel, reschedule

```text
claude-standby status      # status, tier, attempts used, resume time, journal
claude-standby cancel      # daemon stands down within one tick (≤ 60s)
claude-standby resume-at 22:15   # reschedule — the running daemon picks it up
```

### 4.4 After a failure

If `claude-standby status` shows `failed` (cap exhausted or unparseable state), fix
the cause, then reschedule with `claude-standby resume-at <when>` — that resets the
task to `waiting` and the journal keeps the full history.

## 5. Command reference

### `claude-standby resume-at [when] [critical|normal|low] [--session …] [--prompt …] [--workspace …]`

Schedules an auto-resume for the current workspace and spawns the daemon.
`when` = `reset` reads the exact reset time from your local usage data and
schedules a known-time resume (+ a safety buffer) with no probe and no
`used_percentage` check — use it when you've just hit a limit (it refuses,
with guidance, if no local reset time exists). `when` = `auto` (or nothing)
arms the daemon to watch and resume whenever a limit hits and then lifts. A
literal time resumes at that time. Creates the task if the workspace wasn't
tracked (default tier `critical`); otherwise keeps the existing tier unless
you pass one. Re-running it reschedules — the running daemon picks up the
change within one tick.

Pins which Claude Code conversation the resume continues: by default the
workspace's newest session (a previously pinned session is kept on
reschedule). `--session` overrides — an index from
`claude-standby sessions`, a session id or unique prefix, `latest`, or `new`
for a fresh chat. An unknown value refuses rather than silently starting
a new conversation.

`--prompt "<text>"` sets the message delivered to the resumed session
(stored as the task's resume prompt; omitting it keeps whatever was set
before, or the default). `--workspace <path>` (or `-w`) schedules for
another project directory instead of the current one — session pinning
and `--session` indexes then refer to *that* workspace's sessions.

### `claude-standby sessions [--workspace <path>]`

Lists a workspace's Claude Code sessions (from `~/.claude/projects/`;
default: the current directory), newest first: pick index, short id, age,
size, and the first real prompt as a summary. Marks the session currently
pinned for resume.

### `claude-standby start <critical|normal|low> <task description>`

Registers the current workspace as a tracked task with status `running`.
Resets the attempt counter. Does not spawn a daemon (nothing to wait for
yet).

### `claude-standby status`

Shows status, tier, attempts used / cap, resume time (if scheduled), the
task prompt, and the last journal entries.

### `claude-standby cancel`

Sets the task to `cancelled`, journals it, and immediately stops the
workspace's daemon **and any resume already in flight** (the claude
process it launched). Cancelling during a `normal` tier's 5-minute grace
window aborts that resume.

### `claude-standby list`

All tracked workspaces with their status and tier.

### `claude-standby log [n]` / `claude-standby watch`

Show the last `n` lines (default 40) of the tool's log, or follow it live.

### `claude-standby doctor`

Environment self-check: install location, claude binary on PATH, JSON
engine in use, state file health, running/stale daemons, notification
mechanism, and — when a local rate snapshot is available — the exact reset
time it found and which source it read (so you can confirm exact-reset
detection is working before you rely on it). Exits nonzero if resumes can't
work (claude missing).

### `claude-standby update`

Updates the install in place: downloads a fresh copy, sanity-checks it,
then swaps it in (no git involved — a failed download never leaves a
broken install). Prints a one-line summary (`Updated 0.6.0 → 0.7.0.`).
If you're running from your own git clone of the repo, `update` refuses
and tells you to `git pull` instead — it will never touch a development
checkout.

### `claude-standby uninstall [--yes]`

Removes the install directory and the CLI link after confirmation
(`--yes` skips the prompt). Your task state and logs under
`~/.claude/auto-resume` are kept; the command prints how to remove them.
A git checkout with uncommitted changes is refused so it can't eat a
development copy — except the installer-managed directory
(`~/.claude-standby`), which is always removable (host filesystems can
dirty an installed clone through no fault of yours; you'll get a note that
local changes go with it).

### `claude-standby setup-statusline` / `claude-standby remove-statusline`

Install or remove the optional status-line **sensor** that captures the
exact reset time into `~/.claude/auto-resume/rate.json`, so auto mode can
schedule to the exact moment without probing (see "Exact reset detection"
in §3). Opt-in because it touches your status line — if you already have
one, its command is **chained** (run with the same input, output passed
through) so your display is unchanged, and `remove-statusline` restores it.
A timestamped backup is written before any change and re-running does
nothing; if a registration points at an old install location, re-running
refreshes the path. Requires `python3`. You don't need this if a local cache already
carries the reset time (`doctor` will tell you) — it's only for setups that
have none.

### `claude-standby version`

Prints the version and git revision.

## 6. Configuration

Optional config file: `~/.claude/auto-resume/config` (plain shell,
`AR_CFG_*` variables only). Environment variables always override it.

| Config variable | Env override | Default | Purpose |
|---|---|---|---|
| `AR_CFG_CLAUDE_BIN` | `CLAUDE_STANDBY_CLAUDE_BIN` | `claude` | Binary the daemon invokes to resume |
| `AR_CFG_EXTRA_ARGS` | `CLAUDE_STANDBY_EXTRA_ARGS` | *(empty)* | Extra CLI args appended to the resume command (word-split) |
| — | `CLAUDE_STANDBY_STATE` | `~/.claude/auto-resume/state.json` | State file location |
| — | `AR_DAEMON_TICK_SECS` | `60` | Daemon wake interval |
| — | `AR_NORMAL_GRACE_SECS` | `300` | `normal` tier confirmation window (notify → wait → resume, so you can cancel) |
| `AR_CFG_RESET_GRACE` | `AR_RESET_GRACE_SECS` | `60` | Safety buffer added *after* a detected reset before attempting the resume (avoids bouncing off a still-active limit at the exact reset instant). `0` = attempt on the dot |
| — | `AR_BACKOFF_BASE_SECS` | `300` | Backoff unit after a failed attempt |
| — | `AR_PROBE_INTERVAL_SECS` | `1800` | Auto mode: seconds between limit probes (fallback path only) |
| `AR_CFG_PROBE_MODEL` | `AR_PROBE_MODEL` | `haiku` | Auto mode: model for the probe call |
| — | `AR_AUTO_GIVEUP_SECS` | `21600` | Auto mode: give up after this long still limited (6 h ≈ "must be a weekly cap") |
| `AR_CFG_RATE_SOURCE` | `CLAUDE_STANDBY_RATE_FILE` | *(auto)* | Path to the rate snapshot with the exact reset time. Resolution order: this env → this config → our sensor's `rate.json` → `/tmp/claude_rate_cache_$USER.json` |
| — | `AR_LIMIT_PCT` | `100` | Auto mode: `used_percentage` at which the sensor treats you as limited (conservative default; unverified against a real limit). Below it, the daemon still probes to be sure — it never trusts the sensor's "not limited" alone |
| — | `AR_ARMED_MAX_SECS` | `86400` | Auto mode: stand down after this long armed with no limit seen (`0` = never; protects quota) |
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
| `~/.claude/auto-resume/logs/plugin.log` | Timestamped log of everything: daemon ticks, probes, resume attempts, errors. First stop when debugging. |
| `~/.claude/auto-resume/rate.json` | Exact reset snapshot (`resets_at`, `used_percentage`) written by the optional status-line sensor; read by auto mode. Absent unless `setup-statusline` is installed (a `/tmp` cache may be used instead — see §3). |
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
`claude-standby resume-at <when>`. (Reboot-surviving schedules are on the roadmap.)

**Resume ran but the session did nothing useful.**
Check `last_output_tail` in state.json and your `PROGRESS.md`. Headless
sessions can't ask for permissions — if the tail shows permission refusals,
set an allowlist (section 6).

**It keeps retrying and failing.**
The journal (via `claude-standby status`) shows each attempt's reason. A resume that
bounces off a still-active limit backs off automatically; hitting the cap
means the reset time you gave was too optimistic — schedule later.

**`claude-standby status` says no task, but I scheduled one.**
Commands key by directory. Run them from the same directory you scheduled
from.

**Stale pidfile after a crash.**
Harmless — the next daemon detects the dead pid and replaces it.

## 9. FAQ

**Does this get me more quota?** No. It spends the quota you get at reset
without you having to be present. Weekly caps are unaffected by anything
this tool does.

**Does scheduling have to happen before the limit hits?** No — that's the
main flow: run `claude-standby resume-at` *after* the limit, and you don't even need
to know the reset time. Pre-tracking with `claude-standby start` just adds
bookkeeping.

**What do the auto-mode probes cost?** Failed probes (limit still active)
are rejected calls and are believed to cost nothing. Each *successful*
probe costs one minimal `haiku` call — and in the normal case there are
exactly two probes total: one failed probe that reveals the reset time,
and one successful probe at that time confirming it before the resume. If
you want zero probe overhead, pass an explicit time.

**How does auto-detect know the reset time without me typing it?** It reads
your local rate snapshot when one exists (the exact reset Claude Code streams
to its status line, cached on disk — HOOK-FINDINGS F4), scheduling to the
exact moment with no probe. If none exists, it falls back to a minimal
`haiku` probe that reads the reset from the measured limit *message*
(HOOK-FINDINGS F1). Both use formats we measured, not guesses.

**Can two workspaces wait at once?** Yes. Each gets its own daemon and its
own task entry.

**What happens if I suspend my laptop while waiting?** Fine. The daemon
compares wall-clock time on every wake, so it fires on the first tick after
the machine is awake past the reset time.

## 10. Uninstalling

```sh
claude-standby uninstall
```

This removes the install and the CLI link (and the status-line sensor if you
added one). Then remove runtime data if you want a clean slate:

```sh
rm -rf ~/.claude/auto-resume
```

Any waiting daemon exits on its next tick once the state file is gone.
