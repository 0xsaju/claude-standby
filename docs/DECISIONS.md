# Decisions

Append-only log. Newest at the bottom. Format: ID, date, decision, reasoning.

---

## D1 — 2026-07-18 — Engine is a Claude Code plugin; UI is a separate VS Code extension; state.json is the only contract

Editor-agnostic engine (hooks + detached daemon) serves terminal/SSH/
JetBrains/VS Code users. The extension is a pure UI shell over
`~/.claude/auto-resume/state.json` and never spawns or parses Claude Code.
Decided before Phase 0 in planning; recorded here for the record.

## D2 — 2026-07-18 — JSON access fallback chain: jq → python3 → awk/sed on canonical layout

C2 forbids a hard jq dependency and requires a sed/grep-class fallback. Pure
sed/grep JSON editing is fragile, so the chain is: `jq` when present (most
robust), else `python3` (present on ~all target systems, fully robust), else
a text tier using awk/sed. The text tier is viable because *this library is
the only writer* of state.json and always writes a canonical 2-space-indent,
one-key-per-line layout (jq's and `json.dumps(indent=2)`'s shared style), so
line-oriented matching is reliable. The text tier's string unescaping is
best-effort on adversarial content (e.g. literal `\\n` sequences); accepted
for a last-resort tier. Engine is overridable via `AR_JSON_ENGINE` for tests.

## D3 — 2026-07-18 — Workspace key = absolute $PWD at /task-start time; one task per workspace

Simplest identity that both hooks (cwd in payload) and the daemon can agree
on without coordination. Multi-task-per-workspace is deferred to the task
queue feature (phase 4+).

## D4 — 2026-07-18 — on-stop.sh wired to both Stop and SessionEnd until probe data says otherwise

We don't yet know which event fires on a limit hit (C1). Wiring both is
harmless (the stub only logs) and means the probe findings can prune rather
than add. The script takes the event name as $1 so one file serves both.

## D5 — 2026-07-18 — fake-claude's transcript/limit-message format is an explicit guess

`test/fake-claude.sh` emits a JSONL transcript whose first line is a
`fake_meta` marker stating the format is GUESSED. When HOOK-FINDINGS.md
lands, fake-claude gets re-pointed at the real format; the test suite's
structure doesn't change, only the fixture text.

## D6 — 2026-07-18 — session_id is filled by hooks, not by /task-start

Slash commands don't receive the session id; hook payloads do. `/task-start`
leaves `session_id` empty and the Stop/SessionEnd hook fills it (Phase 1).

## D7 — 2026-07-18 — Notifications: osascript → notify-send → log-only; no Windows toast in v1

A blocking mechanism (e.g. PowerShell MessageBox) is unacceptable in a hook
path (C4), and non-blocking Windows toasts need modules we can't assume.
Windows users get log-only notifications in v1; documented limitation,
revisit in Phase 3.

## D8 — 2026-07-18 — Not a git repo yet

Phase 0 work order didn't ask for `git init`; left to the user (flagged in
PROGRESS.md handoff). **Superseded same day:** user requested repo init +
commit after the Phase 0 cleanup pass; repo initialized with `main` as the
default branch.

## D9 — 2026-07-18 — claude-limit-hook-probe/ stays at repo root

It predates the scaffold, is referenced by HOOK-FINDINGS.md as the measuring
instrument, and is throwaway after the probe. Its zip is gitignored.

## D10 — 2026-07-18 — Manual post-limit scheduling ships before automatic detection (Phase 2 before Phase 1)

User insight: scheduling doesn't have to precede the limit hit. A user who
just saw the limit message knows the reset time and can schedule the resume
manually (`/task-resume-at`). This requires zero payload parsing, so it
doesn't violate C1 — the human is the detector. Consequence: the daemon
(Phase 2) was built now and is fully testable against fake-claude, while
hook detection (Phase 1) stays blocked on probe data. Detection, when it
lands, plugs into the same daemon by writing the same state fields.
Untracked workspaces scheduled post-hoc default to importance=critical: an
explicit schedule means "resume without asking".

## D11 — 2026-07-18 — Daemon pidfiles live outside state.json

One daemon per workspace is enforced with a pidfile at
`~/.claude/auto-resume/daemons/<cksum-of-path>.pid`. Pids are host-local
runtime facts, not contract data a UI needs, so keeping them out of
state.json avoids a schema version bump. Stale pidfiles (dead pid) are
detected and replaced on the next spawn.

## D12 — 2026-07-18 — Configurable claude binary + extra args via AR_CFG_* config file

`~/.claude/auto-resume/config` (plain shell, AR_CFG_* names only) provides
`AR_CFG_CLAUDE_BIN` and `AR_CFG_EXTRA_ARGS`. Environment variables
(CLAUDE_AUTO_RESUME_*) always win because consumers read
`${ENV:-${AR_CFG:-default}}` — this is what lets tests point the daemon at
fake-claude (C6) and what lets users add a permission allowlist without the
tool ever adding `--dangerously-skip-permissions` itself (C5). Distinct
AR_CFG_* names prevent the sourced config from clobbering env overrides.

## D13 — 2026-07-18 — Auto reset detection via probe calls; state schema v2 adds resume_mode

User asked for automatic resume without typing the reset time. Parsing the
reset time from the limit message stays blocked on probe data (C1), but a
probe loop needs no parsing at all: `claude -p "ok" --model haiku` fails
while limited and succeeds the moment the limit lifts — exit-code-only
detection, C1-safe. `/task-resume-at` with no time (or `auto`) sets
`resume_mode=auto`; the daemon then treats `resume_at` as the *next probe
time* (default every 30 min, `AR_PROBE_INTERVAL_SECS`), probes, and on
success falls into the normal tier/resume flow. Probe failures never count
against `max_resumes`. A give-up window (`AR_AUTO_GIVEUP_SECS`, default 6 h)
catches weekly caps, which never lift within a rolling window. Cost
honesty: each successful probe spends one minimal haiku call; failed probes
are believed free (the call is rejected). Schema: new optional task field
`resume_mode: "at" | "auto"` (absent ⇒ "at"), version bumped to 2; v1 files
remain readable since all readers default the field.

## D14 — 2026-07-18 — First measured limit surface (F1); detection trusts the message, never exit codes alone

User captured the real headless limit output:
`You've hit your session limit · resets 4:10pm (Asia/Dhaka)` — recorded as
HOOK-FINDINGS F1, the first C1-compliant detection surface. Implemented:

- `AR_LIMIT_PATTERN` ("hit your session limit") and `ar_parse_reset_time()`
  in lib.sh (h:mm am/pm + IANA zone → next-occurrence epoch; uses the
  zone's current offset — no DST-transition handling, acceptable for a
  <24 h horizon).
- Auto mode upgraded: a failed probe's output is parsed for the announced
  reset time, so the daemon waits for the exact moment instead of blind
  polling (sanity window >1 min and <23 h; if the announced time has
  arrived but the limit hasn't lifted, retry every 5 min).
- The exit code of a limited call is STILL unmeasured (the first capture
  piped through tee, so `$?` was tee's). Therefore: probe success requires
  exit 0 AND no limit pattern in output; a resume whose output contains
  the pattern is treated as a bounce even if it exits 0 — this prevents
  falsely marking tasks done.
- fake-claude's stdout fixture re-pointed to the measured format per D5
  (transcript format remains a guess); `FAKE_CLAUDE_LIMIT_EXIT` emulates
  either exit-code behavior in tests.

## D15 — 2026-07-18 — Terminal CLI (`bin/claude-auto-resume`) as the zero-token, works-while-limited interface

User observation: slash commands consume a model turn (the `!` bash runs
locally free, but its output is injected into context and Claude relays
it) — and, worse, model turns are unavailable exactly when this tool
matters: while rate-limited. `/task-resume-at` therefore cannot be invoked
at the moment it exists for. Resolution: `bin/claude-auto-resume`
(suggested alias `car`) fronts the same task-*.sh scripts with zero tokens
and no Claude Code session — status | start | resume-at | cancel | log |
watch. Slash commands stay for convenience when unlimited; the CLI is the
documented path while limited. Command scripts now also ar_log their
actions for a terminal-visible audit trail.

## D16 — 2026-07-18 — One-command installer; repo goes open source

`curl -fsSL .../install.sh | bash` installs without root: repo cloned (or
tarball-extracted when git is absent) to `~/.claude-auto-resume`, CLI
symlinked into `~/.local/bin`, PATH hint printed if needed. Re-running
updates in place (`git pull --ff-only`); `--uninstall` removes app + link
but keeps runtime state at `~/.claude/auto-resume` (user data outlives the
tool). Plugin registration stays a manual in-session `/plugin` step —
driving Claude Code's plugin manager from an installer script would depend
on unversioned CLI surface. Roles clarified after review: CLI-first
product, plugin's long-term value is the hook sensor (unattended detection
+ session_id capture); slash commands are optional sugar. Native Windows
support deferred: the plan is a Task Scheduler one-shot at resume time
instead of a ported sleep-loop daemon, which also opens the door to
launchd/cron reboot-surviving schedules on macOS/Linux.

## D17 — 2026-07-18 — Slash commands removed; plugin is a hook sensor only

Follow-through on D15's role split, confirmed by the user ("if the CLI
alone solves it, why the plugin?"): the four /task-* command files are
deleted. They duplicated the CLI, cost a model turn per use, and could not
run in the one state the tool exists for (rate-limited). The plugin now
ships exactly one thing — the Stop/SessionEnd hooks — whose value the CLI
cannot replicate: unattended detection at the moment a session stops, with
the session_id for a true --resume. The task-*.sh scripts remain as the
CLI's backends; user-facing strings now show CLI syntax. Users who
installed the earlier plugin build should reinstall (or /plugin update) to
drop the stale commands.

## D18 — 2026-07-18 — Full tool surface: version / update / uninstall / doctor / list; version 0.2.0

User direction (reversing the earlier "no versioning, no updating" after
reflection): the CLI must behave like a real terminal tool, not a script.
Added: `version` (single source of truth = plugin.json's version field,
plus git short rev), `update` (git pull --ff-only in the install root;
falls back to pointing at the installer), `uninstall [--yes]` (removes
install dir + CLI link, keeps runtime state, refuses on a dirty checkout
so it can't delete a development copy, requires a TTY or --yes),
`doctor` (claude binary, JSON engine, state health, running/stale daemons,
notifier — exits nonzero when resumes can't work), and `list`
(all tracked workspaces via new lib.sh `ar_task_list`, all three JSON
engines). Deliberately stopping there — no shell completions, man pages,
or config subcommands until someone needs them.

## D19 — 2026-07-18 — cancel kills the daemon and in-flight resume immediately

Real-world find: the user cancelled during a resume; the state flip
preserved `cancelled` (post-D17 fix) but the already-launched claude
process kept running — ~15 minutes of quota spent after an explicit
cancel. `task-cancel.sh` now also reads the workspace's pidfile (shared
helper `ar_daemon_pidfile` in lib.sh), kills the daemon and its
descendants (best-effort via pgrep; skipped where pgrep is absent), and
removes the pidfile. Cancel means stop — not "stop after the current
attempt finishes".

## D20 — 2026-07-18 — Hooks register via settings.json (`setup-hooks`); installer delivers the whole environment

Deep-dive outcome: settings-file hooks and plugin hooks are functionally
identical, so the plugin is not required for detection — `setup-hooks`
writes our two Stop/SessionEnd entries directly into
`~/.claude/settings.json`. Safety contract: merge-never-overwrite (only
entries whose command references on-stop.sh are touched), timestamped
backup before every edit, idempotent, python3 required (manual snippet
printed otherwise — sed is not safe against arbitrary user JSON), and it
refuses to register when the Claude Code plugin is detected (hooks would
fire twice; --force overrides). install.sh now runs setup-hooks
(CAR_NO_HOOKS skips), and both uninstall paths run remove-hooks — the
curl one-liner is now the complete environment. The plugin remains as
alternative packaging only. brew/apt explicitly declined for now.

## D21 — 2026-07-18 — VS Code cockpit MVP: plain JS, reads state.json, writes through the CLI

Built as a dependency-free plain-JavaScript extension (no bundler, no
node_modules): status bar item per workspace (watch on the state dir +
5 s fallback poll, since atomic mv breaks file-level fs.watch),
quick-pick menu (schedule / status / cancel / open log), and onboarding
that offers to run the curl installer in an integrated terminal when the
CLI is missing. All writes go through the CLI rather than the state
file's `commands` array — one logic path; the commands array stays in
the schema, unused, for a future where a UI can't shell out. Runs from
source (F5) or a locally packaged .vsix; not published to the
marketplace yet. Extension has no automated tests (would need the VS
Code test harness) — verified by `node --check` + manual run;
acceptable for a thin shell that must stay thin.

## D22 — 2026-07-18 — Standalone probe plugin removed (supersedes D9)

`claude-limit-hook-probe/` was deleted (user removed it from disk; the
deletion rode along in commit 0949926). Correct call: its capture
function moved into `on-stop.sh` (hook-payloads.log), so the standalone
plugin was redundant. One capability was lost knowingly: the probe also
captured SessionStart and Notification events. If a real limit hit shows
nothing on Stop/SessionEnd (HOOK-FINDINGS Q7), temporarily add hooks for
those events; the old probe remains in git history for reference.

## D23 — 2026-07-18 — True session resume: pin the session id at schedule time

The gap that defeated the product's primary goal: `do_resume()` already
passed `--resume <session_id>`, but nothing ever set `session_id`, so
every resume opened a NEW chat instead of continuing the interrupted
conversation. Fixed by measuring the surfaces first (HOOK-FINDINGS F2:
`~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` session store;
F3: `-r/--resume <id>` headless-compatible), then:

- `ar_sessions_list`/`ar_session_latest` in lib.sh discover a
  workspace's sessions (read-only, newest first, UUID-filtered).
- `resume-at` pins a session id INTO state at schedule time — default
  the workspace's newest session, `--session <n|id|latest|new>` to
  override; new `sessions` command lists them with pick indexes. An
  already-pinned id is kept on reschedule.
- Pinning happens at schedule time, not resume time, deliberately: the
  daemon's own probes (`claude -p ok`) run in the workspace directory
  and create new session files, so any later "most recent" lookup (or
  `--continue`) would resume a probe stub instead of the real work.
  For the same reason `--continue` is never used.
- The cockpit shows session plates (summary · id · age · size) in the
  schedule composer; selection flows through `resume-at --session`.
  Extension reads the session store directly — still read-only, so D21's
  "writes only through the CLI" holds.

state.json schema unchanged (v2 already had `session_id`; it just was
never written). Plugin 0.3.0, extension 0.5.0.

## D24 — 2026-07-18 — Full schedule composer: project · session · prompt · time

Extended D23's session pinning into the complete scheduling surface, on
both interfaces. CLI: `resume-at` gains `--prompt "<text>"` (writes
`resume_prompt_template`, which the daemon already delivered but nothing
could set) and `--workspace <path>` (schedule any project without cd);
`sessions` gains `--workspace` to match. Cockpit 0.6.0: the per-card
composers were replaced by ONE composer — project select (open folder
first, then tracked tasks, then any project with sessions on disk),
session plates that swap when the project changes (client-side, from an
embedded JSON block — no round trip, no lost input state), optional
prompt field, then when/tier. "Schedule" on other-workspace cards jumps
to the composer with that project preselected.

Two notable mechanics: (1) the encoded project-dir names in
`~/.claude/projects` are lossy (`[^A-Za-z0-9] → -`), so real workspace
paths are recovered from the `cwd` field inside session lines (measured,
F2) rather than by decoding directory names; (2) plates are built with
DOM APIs, never innerHTML — summaries are conversation text and must not
be interpretable as markup. Schema untouched (both fields existed in v2).
