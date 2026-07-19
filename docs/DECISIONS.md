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

## D25 — 2026-07-18 — Dashboard visual direction: design option 1a "VS Code native"

The user iterated the dashboard in Claude design (project "Claude
Auto-Resume Dashboard", file `Dashboard Options.dc.html`), producing
three directions: 1a VS Code native, 1b operator console, 1c calm
center, plus 1d (narrow-width collapse). We implemented **1a** with 1d's
collapse and 1b's colored timeline glyphs. Why 1a: it reads as a
first-class VS Code panel (flat widgets, small type, theme variables
everywhere), its always-visible composer maps 1:1 to the four-step
schedule flow, and its select-based session picker scales better than
plates for workspaces with many sessions. 1b's mono-console styling and
1c's sentence composer were more opinionated and fragile at narrow
widths. Notable mock→real adaptations: hardcoded `--ch-*` colors became
`var(--vscode-charts-*, fallback)`; the mock's static "2h 14m 09s"
became the live 1s countdown; attempts became real max_resumes segments;
the session/prompt selects bind to the measured session store (F2) and
`resume-at --session/--prompt`. Extension 0.7.0.

## D26 — 2026-07-19 — Cockpit redesign: onboarding gate + professional dashboard (Auto-Resume.dc.html)

The user rejected the 0.7.x dashboard as "childish" and specced a fuller
product: a welcome/onboarding + setup screen first, then the dashboard,
then a status-bar tool-status popup — reference bar Linear/Vercel/GitHub
settings. Iterated in Claude design (same project, new file
`Auto-Resume.dc.html`) and implemented as extension **0.8.0**. Three
surfaces:

- **Screen A (onboarding/setup)** — a 3-step "what it does" strip and a
  live setup checklist (CLI installed · hooks registered · Claude Code
  detected · state file healthy), each row with ✓ / ✗ + an inline action
  (Install runs the one-command installer; Register runs
  `claude-auto-resume setup-hooks`). Shown automatically until the tool
  is ready (`cliFound && hooks registered`); reachable afterward via a
  "Setup" link. Replaces the old bare "CLI not installed" card.
- **Screen B (dashboard)** — small header (never a giant centered logo —
  the explicit anti-goal), a fixed-project current-workspace composer
  (no in-card project select; the project is the open folder), a
  Scheduled-resumes list, an Other-workspaces project picker that reveals
  the *same* composer for any project, activity timeline, a collapsible
  CLI reference, and an About row (author name + GitHub/LinkedIn/Buy Me a
  Coffee, each rendered only when its URL is configured).
- **Screen C (status bar + tooltip)** — the status item now speaks the
  tool's state (`waiting · resumes 8:30 PM`, `auto · reset ~1:01 PM`,
  `resuming…`, `done · HH:MM`, `failed · N attempts used`); its hover is
  a rich MarkdownString "tool-status popup" (status, resume time,
  pinned session, attempts, Open-dashboard/Cancel command links). The
  Orca account-usage popup was style reference only — we show OUR status,
  not Claude account quotas.

Mechanics: the composer's **When** control is chips (Auto-detect / 30m /
1h / 2h) plus an **AM/PM** time picker (hour · min · AM|PM segmented),
converted to 24h `HH:MM` client-side for `resume-at`; the prompt field is
prefilled with the default *value* (not placeholder) with a "reset to
default" affordance, and is omitted from the CLI call when unchanged. View
state (setup vs dashboard, selected other-project, CLI-reference open) is
persisted host-side so the 5 s auto-refresh doesn't reset it. Author
links are four VS Code settings (`claudeAutoResume.author.*`); nothing
fake ships — a link renders only when its URL is set.

Deferred (needs engine work, not shipped in 0.8.0): (a) **multiple
schedules per workspace** — the list is rendered list-shaped but
state.json is still one task per workspace (schema v3 + per-schedule
daemon/cancel is the next slice); (b) the **inferred reset time** shown
in the When caption — the 5-hour window is derivable from local
transcript timestamps with zero quota (verified locally on the F2 store),
but the inference belongs in the bash engine (D21/C1), so the caption is
generic until the engine populates a concrete time. Documented for a
future HOOK-FINDINGS F4.

## D27 — 2026-07-19 — Auto-detect resumes only after a limit is actually seen

**Bug.** Scheduling auto-detect (`resume-at auto`) while the account was
NOT rate-limited caused an immediate, wrong resume. In auto mode the
daemon resumes as soon as a probe (`claude -p ok`) succeeds — the probe
means "the limit is gone." But if there was never a limit, the very first
probe succeeds, so the daemon declared "limit-lifted" and ran
`claude --resume <id> -p "<resume prompt>"` against the user's *live*
session — spawning a parallel headless agent that continued (and even
committed to) the running conversation. Observed live: a healthy session
with hours of quota left was resumed seconds after scheduling.

**Fix.** A resume may fire only after a limit has actually been *observed*
and then lifted. New per-task flag `limit_seen` (reset to 0 on every
schedule): a failing probe sets it (journals `limit-hit` + `limit_seen_at`);
resume is allowed only when it is set. If a probe succeeds while
`limit_seen` is unset, the task is *armed* — it keeps watching at the probe
interval so a FUTURE limit+reset triggers the resume, but it never touches
a healthy session (journals `armed` once). The auto give-up window is now
measured from `limit_seen_at` (when the limit was first seen), not from
daemon start, so a long-armed task doesn't spuriously give up the moment a
limit finally appears.

**Testing.** Added `AR_DAEMON_ONESHOT` (run one loop iteration then stand
down) for hermetic single-iteration daemon tests. 7 regression assertions
cover: not-limited → stays waiting / count 0 / journaled `armed` / no false
`limit-lifted`|`resumed`; limit observed → `limit_seen=1`, still waiting;
then lifts → resumes. Also validated live against the installed daemon.
This class of bug (state fields correct, *semantics* wrong) is why field
assertions alone were insufficient — the regression tests assert behavior.

**Note.** A prior "C6 verified" PROGRESS entry (commit 442c47a) was written
by the rogue resume this bug caused; it was corrected — C6 remains
unverified against a real limit.

## D28 — 2026-07-19 — Bound the armed window; detect interrupted resumes

Two follow-ups to the D27 auto-detect work, found by code review.

**1. Armed window is now bounded (C6).** After D27, an auto-detect task
scheduled on a healthy session stays *armed* — probing (`claude -p ok
--model haiku`) every `AR_PROBE_INTERVAL_SECS` — until a limit finally
appears or the user cancels. With no limit ever hit that is an unbounded
probe loop that slowly burns quota. The daemon now records `armed_since`
on the first armed pass and stands down (status `failed`, journal + notify
"armed …s with no limit — stood down; reschedule when you expect one")
once `AR_ARMED_MAX_SECS` (default 24h) elapses. `AR_ARMED_MAX_SECS=0` opts
out for anyone who genuinely wants indefinite arming. The give-up is
measured from arming start, independent of the D27 `limit_seen_at`
give-up (which times how long a *seen* limit takes to lift).

**2. Interrupted resumes are now detectable (cockpit).** If a daemon dies
mid-resume (crash, kill, machine reset), the task stays at status
`resuming` with no live daemon — the cockpit previously showed a forever
"resuming" spinner. The daemon now writes its pid to `daemon_pid` at
startup; the extension flags `status == resuming && daemon_pid not alive`
as an interrupted resume (status bar "resume interrupted", tooltip +
dashboard rows in red with a Reschedule/Cancel prompt). A genuine in-flight
resume always has a live daemon, so this never false-flags one; a blank
`daemon_pid` is treated as NOT stuck, so a resume by a pre-upgrade daemon
can't trip a false alarm.

**Schema.** Two additive per-task fields, `armed_since` and `daemon_pid`
(both default `""`), added to all three JSON engines (jq / python3 / text)
and reset on every schedule. Following the D27 precedent (which added
`limit_seen` et al. without a bump), the additive daemon-bookkeeping fields
do NOT bump `state.json` `version` — it stays `2`; `version: 3` remains
reserved for the multi-schedule-per-workspace change (tasks gain ids).

**Testing.** +5 regression assertions: daemon records a numeric pid; armed
task stands down after the window (status failed, journaled, no resume);
`ARMED_MAX=0` keeps waiting. The cockpit `isDaemonStuck` logic is exercised
out-of-tree over all four cases (non-resuming, alive, dead→stuck, blank→
not-stuck). Plugin 0.4.0, extension 0.8.5.

## D29 — 2026-07-19 — Exact reset time from local data (no polling)

Auto-detect used to blind-probe every 30 min because it didn't know the
reset time. It turns out Claude Code streams the exact rate-limit state to
the **status line** — `.rate_limits.five_hour.{used_percentage, resets_at}`
(HOOK-FINDINGS F4, measured). It does NOT write this to any file itself, and
it is NOT in the Stop-hook payload (measured: 815 captured payloads, zero
hits). But a status line that caches it (common) leaves it on disk.

**Design — read a file if one exists; produce one only if needed.**
- The daemon reads a rate snapshot resolved in priority order (`ar_rate_file`):
  `CLAUDE_AUTO_RESUME_RATE_FILE` → `AR_CFG_RATE_SOURCE` (point us at your own
  cache) → our sensor's `rate.json` → a common status-line cache
  (`/tmp/claude_rate_cache_$USER.json`). Fields tolerate `used_percentage`
  **or** `rate_pct`, and `resets_at` as epoch **or** ISO.
- If a file already has the time, we just read it — **zero setup** (this is
  the answer to "why an extra command?"). The sensor
  (`statusline.sh` + `setup-statusline`, opt-in, chains any existing status
  line) is only the fallback that PRODUCES the file for users who have none.
- Auto mode: rate usable → detection via `used_percentage >= AR_LIMIT_PCT`
  (default 100) and the resume is scheduled to the EXACT `resets_at` — no
  probe, no quota. Rate absent/stale → the existing probe path, unchanged.
  Armed re-checks read the file cheaply (`AR_RATE_CHECK_SECS`, 300) instead
  of probing. `doctor` shows the source, reset time, and used %.

**UNVERIFIED (like C6):** the exact `used_percentage` when Claude Code
actually blocks isn't measured, and whether the status line keeps refreshing
once blocked. `AR_LIMIT_PCT=100` is the conservative default; confirm on a
real limit. The armed-window bound (D28) still prevents an indefinite wait.

**Testing.** +14 suite tests (sensor capture, three-engine reader,
armed/limited/resume/fallback, setup-statusline chain+restore). Plus an
exhaustive corner pass that found and fixed three real bugs: the sensor
wrote to the wrong path (ignored the override); the text engine mangled an
ISO `resets_at` with a greedy sed; a bare-string `statusLine` was dropped on
registration. Cockpit shows the real reset ("resets 6:00 PM · 40% used";
"armed · resets" vs "resumes" by limit_seen). Plugin 0.5.0, extension 0.8.7.

## D30 — 2026-07-19 — Post-reset safety buffer + longer normal-tier window

Two resume-timing tweaks driven by go-live use:

**Reset safety buffer.** Resuming at the exact reset instant is fragile: a
call fired a second early — from clock skew, or the server rounding the
5-hour window up — bounces off a still-active limit and burns an attempt. So
the daemon now schedules the resume `AR_RESET_GRACE_SECS` (default 60s,
`AR_CFG_RESET_GRACE`) AFTER the detected/announced reset, on both the F4
sensor path and the F1 probe-parsed path. `0` opts back into on-the-dot.
The existing backoff+retry (bounded by `max_resumes`) still covers a bounce
if one happens anyway.

**Normal-tier window 60s → 300s.** The `normal` tier notifies, waits, then
resumes so you can cancel. 60s was too short to notice and react; the
confirmation window (`AR_NORMAL_GRACE_SECS`) now defaults to 5 minutes.

No schema change (resume_at semantics unchanged, still an ISO time). Plugin
0.5.1. +2 regression tests (grace applied; grace 0 = exact). Cockpit already
renders whatever `resume_at` holds, so it surfaces the buffered time with no
change.

## D31 — 2026-07-19 — Remove the Claude Code Stop-hook path entirely

The plugin's Stop/SessionEnd hook (`on-stop.sh`, `setup-hooks`,
`plugin/hooks/hooks.json`) was removed. Rationale: it never did anything
functional. `detect_limit()` was a hardcoded stub (C1 — the limit-payload
shape was never measured), so the hook only appended payloads to
`hook-payloads.log` for research that never completed. Meanwhile the working
auto-resume path needs none of it:
- The exact reset time comes from the status-line rate stream (F4) or a
  probe's limit message (F1) — measured (F4 confirmed the reset time is NOT
  in the hook payload anyway; 815 captured payloads, zero hits).
- The `--resume` session id comes from the session store (F2), pinned at
  schedule time.

So the hook was dead weight that still touched `~/.claude/settings.json` on
install and added a cockpit setup step. Removed: the three files, the
`setup-hooks`/`remove-hooks` CLI commands + doctor hook line, install-time
registration, ~29 hook tests, and the cockpit's hooks checklist/readiness
gating (ready now = CLI installed). `HOOK-FINDINGS.md` stays — F1/F2/F4 are
still the source of truth for the paths we DO use; only the hook mechanism
is gone.

**Zero-arming later, if we want it:** the better mechanism is an always-on
rate-file watcher (launchd/cron), not a hook — more reliable, and it doesn't
depend on the unproven assumption that hooks fire on a limit. Today you arm
with one `resume-at auto`. No schema change.

## D32 — 2026-07-19 — `resume-at reset`: confirmed-limit scheduling, no used_percentage

Auto mode confirms a limit before resuming — via `used_percentage >= AR_LIMIT_PCT`
(F4) or a failed probe (F1) — so it never resumes a healthy session (D27). But
the exact `used_percentage` at a real block is unverified (C6): if it under-reads,
a genuinely-limited user on the sensor path could sit "armed" instead of waiting
for the reset.

The insight (from a user): `resets_at` is *always* in the rate data (every 5-hour
window has a rollover time); `used_percentage` is only needed to answer "are you
blocked right now?" — which the human already knows the moment they hit the limit.
So we don't need the percentage for the common "I just hit a limit" case.

`resume-at reset`: you assert the limit yourself, and we schedule a **known-time**
resume (`resume_mode=at`) to the local `resets_at` + `AR_RESET_GRACE_SECS`, with
`limit_seen=1`, no probe and no `used_percentage`. It refuses (with guidance) when
no local reset snapshot exists. This makes the everyday path robust regardless of
the C6 threshold; `auto` still uses the percentage/probe for the arm-in-advance
case (Situation B), where the tool genuinely must detect the limit itself. No
schema change (reuses `resume_mode=at`).

## D33 — 2026-07-19 — Remove the Claude Code plugin packaging

With the hooks gone (D31), the plugin manifest (`plugin/.claude-plugin/plugin.json`)
and marketplace (`.claude-plugin/marketplace.json`) described a plugin with **no
hooks and no slash commands** — it did nothing. Worse, it was a footgun: a
directory-source install left `${CLAUDE_PLUGIN_ROOT}` pointing at the repo, so
after we deleted `on-stop.sh` the still-installed plugin fired a dead path on every
session Stop ("on-stop.sh: No such file or directory").

Removed both files. The CLI version moved from `plugin.json` to a top-level
`VERSION` file (`car_version()` + the version test read it). The `plugin/`
directory name is now legacy (just the engine scripts); renaming it was left out to
avoid churning every `${...}/plugin/scripts` path. Existing users with the old
plugin installed are told to `/plugin uninstall claude-auto-resume@auto-resume`
(printed by `uninstall` and the installer's `--uninstall`).

## D34 — 2026-07-19 — Go-live audit: F4 must not blind F1, plus rate-reader hardening

A parallel multi-reviewer audit before go-live surfaced one medium issue and a
handful of edges.

**F4 must not blind F1 (the medium one).** In auto mode, once any usable rate
snapshot existed, the F4 block always `continue`d, so the F1 probe never ran.
If the sensor's `used_percentage` under-reports at a real block (it's
UNVERIFIED, C6 — e.g. reads 96 while `LIMIT_PCT=100`), a genuinely-limited task
would sit "armed" and stand down after `AR_ARMED_MAX_SECS` without ever
resuming. Fix: the sensor is trusted only for the exact reset TIME and for a
positive "limited" reading; when it says "not limited" (below the threshold,
no limit seen yet), the daemon now falls through to the probe (F1) as the
detector. Detection latency doesn't matter (we resume at the reset, not at
detection), so probing on `AR_PROBE_INTERVAL` while armed is fine and correct.
`AR_RATE_CHECK_SECS` is removed (the cheap armed re-read it paced is gone).

**Edge fixes (low):** clamp `AR_RESET_GRACE_SECS` to a non-negative numeric
(a negative buffer would resume before the reset); guard a null/blank/non-
numeric `used_percentage` (JSON `null` → `"None"`) before the `-ge` compare;
the text JSON engine now prefers `used_percentage` over `rate_pct` (matching
jq/python) instead of first-in-file; `ar_iso_to_epoch` normalizes a trailing
`Z` (UTC) so third-party caches parse on BSD/old-python; the cockpit's
`readRate` now honors `CLAUDE_AUTO_RESUME_RATE_FILE` and `AR_CFG_RATE_SOURCE`
(mirroring `ar_rate_file`) so the "At reset" chip and the CLI never disagree.

Docs/badges reconciled (README version 0.6.0 / tests 236; removed a stale
"refresh the plugin" line; ARCHITECTURE schema + auto-detect wording). +1 test
proving the under-report backstop; the audit's clean items (dead-ref sweep,
CLI/install integrity) had no findings.
