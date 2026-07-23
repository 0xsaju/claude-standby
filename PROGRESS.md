# PROGRESS

Living checklist for claude-auto-resume. Update before ending any working
session. Detailed rationale for every decision: `docs/DECISIONS.md`
(D1–D24). All dates 2026-07-18 unless noted.

## Done

- [x] **Phase 0 — Scaffold + harness.** Repo structure, governance docs,
      `lib.sh` state library (atomic writes; jq → python3 → awk/sed
      engines), `fake-claude.sh` stub + shell test suite. (D1–D9)
- [x] **Phase 2 — Daemon + manual scheduling** (built before Phase 1 by
      design, D10). Suspend-safe 60 s wait loop, importance tiers,
      max_resumes + backoff, `resume-at` time parsing, pidfile dedup.
      (D10–D12)
- [x] **Auto reset detection.** Probe-based (`resume-at` with no args) +
      reset-time parsing from the measured limit message (HOOK-FINDINGS
      F1); exit codes never trusted alone; schema v2 `resume_mode`.
      (D13–D14)
- [x] **CLI-first consolidation.** Zero-token terminal CLI as the primary
      interface (slash commands removed — they cost tokens and can't run
      while limited); full tool surface: version / update / uninstall /
      doctor / list; cancel kills in-flight resumes. (D15, D17–D19)
- [x] **Distribution.** Open-sourced; one-command installer that delivers
      the complete environment — CLI + hooks registered directly in
      `~/.claude/settings.json` via `setup-hooks` (surgical merge,
      backups, reversible); plugin demoted to alternative packaging;
      standalone probe removed (capture lives in on-stop.sh). v0.2.0.
      (D16, D20, D22)
- [x] **VS Code cockpit MVP.** Plain-JS extension: status bar over
      state.json, quick-pick actions through the CLI, install onboarding.
      Runs from source; unpublished. (D21)
- [x] **True session resume (the primary goal).** Resumes now continue
      the interrupted conversation via `claude --resume <session-id>`,
      not a new chat. Session store + resume flags measured
      (HOOK-FINDINGS F2/F3); `sessions` command lists a workspace's
      sessions; `resume-at` pins the newest by default with
      `--session <n|id|latest|new>` override; cockpit shows one-click
      session plates in the composer. Plugin 0.3.0, extension 0.5.0.
      (D23)
- [x] **Full schedule composer** on both surfaces: project select (any
      workspace, not just the open one), session plates that follow the
      selected project, custom resume prompt, when/tier — CLI flags
      `--prompt` / `--workspace` + one-composer cockpit 0.6.0. (D24)
- [x] **Cockpit redesign — onboarding + professional dashboard** (0.8.0,
      D26). Screen A: setup checklist (CLI / hooks / Claude Code / state)
      with inline Install + Register actions, shown until ready. Screen B:
      small-header dashboard, current-workspace composer with an AM/PM
      time picker + prompt prefilled to the default, Scheduled-resumes
      list, Other-workspaces composer, activity, collapsible CLI
      reference, About row (author links from settings). Screen C: status
      item + rich MarkdownString tool-status tooltip. View state persisted
      across auto-refresh.
- [x] **Test suite: 243 green** — three JSON engines, daemon lifecycle,
      auto mode (incl. the armed/limit_seen gate), session
      discovery/pinning (incl. bad-value refusal), prompt/workspace flags,
      hooks setup/removal, installer cycle, CLI surface. Cockpit client JS
      additionally exercised out-of-tree via jsdom (21 assertions: AM/PM
      conversion, escaping, chip precedence, message wiring) — kept out of
      the suite to preserve the no-tooling convention.
- [x] **Armed-window bound + interrupted-resume detection — 2026-07-19
      (D28).** Two code-review follow-ups to D27. (1) An armed auto-detect
      task (scheduled while healthy, no limit yet) no longer probes
      forever: it stands down after `AR_ARMED_MAX_SECS` (default 24h;
      `0` = unbounded), protecting quota (C6). (2) A resume interrupted by
      a dead daemon (status stuck at `resuming`) is now detectable — the
      daemon records `daemon_pid`, and the cockpit flags `resuming` with no
      live daemon as "resume interrupted" (status bar + tooltip + red
      dashboard rows with a Reschedule/Cancel prompt). Two additive
      per-task fields (`armed_since`, `daemon_pid`) across all three JSON
      engines; +5 regression tests + out-of-tree `isDaemonStuck` checks.
      Plugin 0.4.0, extension 0.8.5.
- [x] **Auto-detect false-resume bug — fixed 2026-07-19 (D27).** Scheduling
      auto-detect while NOT rate-limited made the first probe succeed (no
      limit present), which the daemon mistook for "limit lifted" and
      resumed — injecting the resume prompt into the *live* session as a
      parallel headless agent (which even committed to this repo). Root
      cause: resume fired on any successful probe, with no evidence a limit
      ever existed. Fix: resume is gated on `limit_seen`; in auto mode it
      fires only after a limit was observed (a probe failed) and then
      lifted. With no limit ever seen, the task stays `armed`. 7 regression
      tests + a live check against the installed daemon.

- [x] **Default resume prompt simplified — 2026-07-20.** Now just "Limit
      reset. Continue from where you stopped." The "Check PROGRESS.md
      first." tail was our own repo convention leaking into every user's
      workspace (surfaced while reviewing the cockpit before the
      company-wide beta); `--resume` already restores full conversation
      context, so the file pointer added noise for projects without one.
      Changed in lib.sh, task-resume-at.sh help, cockpit
      (dashboard.js/extension.js, ext 0.8.9 + changelog), docs
      (USER-GUIDE, ARCHITECTURE, DESIGN-BRIEF); `task-start.sh` now gives
      a soft tip instead of decreeing PROGRESS.md. 237 tests green.

## Next

- [x] **Go-live audit (5 parallel reviewers) — 2026-07-19 (D34).** Fixed the one
      medium finding: F4 blinded F1 — a usable rate snapshot suppressed the probe
      entirely, so an under-reporting sensor (C6) could strand a genuinely-limited
      auto task "armed" until stand-down. Now the sensor is trusted only for the
      exact reset TIME / a positive "limited" reading; a "not limited" reading
      falls through to a probe (F1 detector). Removed dead `AR_RATE_CHECK_SECS`.
      Edge fixes: clamp negative reset grace; guard null `used_percentage`; text
      engine prefers `used_percentage`; `Z`/UTC timestamp parsing; cockpit
      `readRate` honors the rate-source overrides. Docs/badges reconciled
      (README 0.6.0 / 236 tests). +1 backstop test → 237 green, flake-checked.
- [x] **Cockpit "At reset" composer option — 2026-07-19.** The dashboard When
      picker now offers **At reset** (selected by default when a local reset time
      is known) alongside **Auto-detect** / 30m / 1h / 2h — mapping to the CLI's
      `resume-at reset` / `auto`. Each mode shows its own hint; the `normal`-tier
      label now says 5 min. Extension 0.8.8 (vsix rebuilt).
- [x] **`resume-at reset` + removed the plugin packaging — 2026-07-19 (D32, D33).**
      D32: a `reset` when-keyword for the everyday "I just hit a limit" case —
      schedules a known-time resume to the local `resets_at` + grace (mode=at,
      `limit_seen=1`), with **no probe and no `used_percentage`**, so it's robust
      regardless of the unverified C6 threshold; refuses with guidance if no local
      reset snapshot exists. `auto` still watches via percentage/probe for the
      arm-in-advance case. +5 tests. D33: deleted the plugin manifest +
      marketplace (a do-nothing plugin after D31, and the source of the stale
      `on-stop.sh` Stop-hook crash for anyone who'd installed it); CLI version
      moved to a top-level `VERSION` file. VERSION 0.6.0.
- [x] **Removed the Claude Code Stop-hook path — 2026-07-19 (D31).** It never
      did anything functional (`detect_limit()` was a stub; F4 measured the
      reset time is not in the hook payload anyway), while the working path
      needs none of it — reset from the rate stream (F4) / probe message (F1),
      session id from the store (F2). Deleted `on-stop.sh`, `setup-hooks.sh`,
      `plugin/hooks/hooks.json`, the `setup-hooks`/`remove-hooks` CLI commands
      + doctor hook line, install-time registration, ~29 hook tests, and the
      cockpit's hooks checklist/readiness gating (ready = CLI installed). Docs
      swept (README incl. a proper system diagram, USER-GUIDE, ARCHITECTURE,
      CLAUDE.md, CONTRIBUTING, HOOK-FINDINGS note). Zero-arming later, if
      wanted, is a rate-file watcher (launchd/cron), not a hook.
- [ ] **Zero-arming detection (optional, replaces the old hook idea):** an
      always-on rate-file watcher (launchd/cron) that arms a resume when
      `used_percentage` crosses the limit — no pre-typed `resume-at auto`.
- [ ] **Multiple schedules per workspace** (cockpit renders the list
      already): schema v3 (tasks get ids), per-schedule daemon + cancel.
- [x] **Resume-timing safety + doc refresh — 2026-07-19 (D30).** Resumes now
      fire `AR_RESET_GRACE_SECS` (default 60s) AFTER the reset, not on the exact
      instant, so they don't bounce off a still-active limit (clock skew /
      server rounding); the `normal`-tier confirmation window went 60s → 5 min
      so it's actually cancellable. Applied on both the F4 sensor and F1 probe
      paths; +2 regression tests (grace applied; grace 0 = exact). Plugin 0.5.1.
      Docs brought current with F4/D29 + D30: README (badges, exact-reset story,
      new commands), USER-GUIDE (exact-reset concept, setup-statusline,
      rate/limit/grace config), ARCHITECTURE (status-line sensor component,
      auto-mode detection), and the VS Code extension README + new CHANGELOG.
- [x] **Killed a time-of-day test flake — 2026-07-19.** The go-live corner
      pass found `run-tests.sh` failing ~1h each afternoon: the auto-parse test
      hardcoded a reset display of `4:10pm`, but the daemon only accepts an
      announced reset in `(now+60s, now+23h)` and the parser rolls a past
      wall-clock time forward 24h — so once local time passed 4:10pm the target
      landed at ~tomorrow-4:10pm (>23h) and `reset-detected` never journaled.
      Root-caused with fake-claude properly wired (`CLAUDE_AUTO_RESUME_CLAUDE_BIN`)
      — an early repro accidentally hit the real CLI (burned quota; do not omit
      that override). Fix: compute the reset display ~2h ahead of NOW at run
      time (portable BSD/GNU `date`, TZ-pinned to the zone named in the
      message). Also hardened four background-daemon assertions that raced a
      fixed `sleep` (WS7 limit-observed gate, WS10 journal poll, WS12 in-flight
      cancel, WS13 daemon-registered gate) with a `wait_until` poll helper.
      Verified with a 10× suite loop at the exact failing time-of-day. 257 green.
- [x] **Exact reset time from local data — 2026-07-19 (D29, F4).** Claude
      Code streams `.rate_limits.five_hour.{used_percentage,resets_at}` to
      the status line (measured; NOT in the hook payload). The daemon now
      reads that snapshot — from an existing status-line cache with zero
      setup, or from our opt-in `setup-statusline` sensor — and in auto mode
      schedules to the EXACT `resets_at` with no probe/quota (falls back to
      probing when absent). Cockpit shows "resets 6:00 PM · 40% used".
      **Still UNVERIFIED at a real limit:** the `used_percentage` value when
      blocked (default `AR_LIMIT_PCT=100`), per D29.
- [ ] **C6 — real-limit verification of `--resume`** (still open): on a
      genuine limit, with auto-detect armed and `limit_seen` set, confirm
      the daemon resumes the pinned session and the conversation continues.
- [ ] **Phase 3 — Polish:** stuck detection (PROGRESS.md unchanged across
      two resumes), resume-verification fallback prompt, `/warmup`
      scheduler, reboot-surviving schedules (launchd/cron one-shots)
- [ ] **Cockpit:** marketplace publishing — package is publish-ready
      (0.8.5, `vsce package` clean, icon 256², keywords + `AI` category,
      `.vscodeignore`). Steps in `docs/PUBLISHING.md`. Blocked only on the
      user's registry accounts + tokens: **both** MS Marketplace (VS Code)
      and **Open VSX** (Cursor/Windsurf), publisher id `0xsaju`.
- [ ] **Native Windows:** Task Scheduler one-shot instead of the
      sleep-loop daemon
- [ ] Capture on next limit hit: un-piped exit code of a limited call
      (`claude -p "ok" --model haiku >/dev/null 2>&1; echo $?`)

## Handoff note

The primary goal now actually works: a scheduled resume continues the
user's interrupted conversation (`claude --resume <pinned session id>`),
with the id pinned at schedule time — never resolved later, because the
daemon's own probes create session files that would poison any
"most recent" lookup (D23; this is also why `--continue` is never used).
Session discovery reads the measured store layout (HOOK-FINDINGS F2)
read-only; picks flow through `resume-at --session` in both CLI and
cockpit. 231 tests green (was 257 before the hook removal, D31, dropped ~29
hook tests; stable across a 10× repeat loop — a time-of-day flake in the
auto-parse test was found and killed during the go-live corner pass; see
the dated entries above). **C6 (real-limit `--resume`) is still UNVERIFIED**
— an earlier PROGRESS note claiming it was proven was written by a rogue
resume: auto-detect had been scheduled on a *non-limited* session, the
first probe succeeded, and the daemon resumed a healthy session (D27, now
fixed). That was the bug, not a verification. Genuine real-limit proof
still needs an actual limit while auto-detect is armed with `limit_seen`
set. A subtle install gotcha also surfaced: the cockpit drives the CLI at
`~/.claude-auto-resume` (a git clone), which can lag the repo — if
`--session` seems ignored, `git -C ~/.claude-auto-resume pull` to refresh
it. The Stop-hook path was removed (D31) — detection reads local data
(F4 rate stream / F1 probe), session id from the store (F2); there is no
hook, no `settings.json` hook registration, no `on-stop.sh`. All state
manipulation goes through lib.sh's public API; detection code may only
match formats measured in docs/HOOK-FINDINGS.md (C1). Keep
docs/USER-GUIDE.md in sync with any behavior change, and keep the VS Code
extension a thin shell.

**2026-07-20 — field-report fixes (D35).** Three user-reported issues in the
maintenance commands, all fixed with regression tests (246 green): uninstall
no longer refuses the installer-managed dir when its clone is dirty (that
guard is for dev checkouts only now); `update` prints a one-line version
summary instead of raw `git pull` output; `setup-statusline` recognizes a
registration pointing at an old install path and refreshes it instead of
claiming "already registered" (and `status` warns about stale paths).
USER-GUIDE updated to match. Handoff: nothing in flight; next session can
pick up any new field reports or the still-unverified C6 real-limit proof.

**2026-07-20 (later) — git-free updates (D36).** `update` no longer runs
`git pull`: `install.sh` gained a shared download→validate→swap path
(staged next to the install, sanity-checked before the old tree is
replaced), the CLI's `update` delegates to it via `install.sh --update`,
and installs are now plain trees — git is only a download fallback and its
`.git` dir is stripped. Legacy clone-based installs migrate on their first
update; a dev checkout (git dir outside `~/.claude-auto-resume`) is refused
by both `update` and `uninstall`. README/USER-GUIDE synced; 252 tests green
(new coverage: plain-tree invariant, corrupt-download rollback, dev-checkout
refusals, version-transition message). Handoff: consider cutting a release
tag and pointing the tarball at tags once a release flow exists (deferred
in D36).

**2026-07-20 (later still) — legacy-plugin hint made conditional.** Field
confusion: uninstall's `/plugin uninstall claude-auto-resume@auto-resume`
hint (for pre-D33 plugin users) printed unconditionally, reading as "we
still ship a plugin." Both uninstall paths now print it only when a trace
of the old plugin actually exists (Claude Code plugin store config/dirs or
`enabledPlugins` in settings.json); 254 tests green.

**2026-07-20 — go-live re-audit after D35/D36.** Live end-to-end pass
against production GitHub: curl install → plain tree (no .git) → `update`
("Already up to date") → `doctor` all-ok (reads the real rate cache) →
`uninstall` clean, no legacy-plugin hint. Docs swept for staleness: fixed
ARCHITECTURE's "MVP, run from source" cockpit line (it's published) and
USER-GUIDE's "installs the repo" wording; README badge (0.6.0) matches
VERSION; no remaining git-pull/hook/plugin claims outside historical
entries. 254 tests green.

**2026-07-20 — renamed to Claude Standby (D37).** Resolved the name
collision with terryso/claude-auto-resume. Command is now `claude-standby`
(alias `cs`); install dir `~/.claude-standby`; env vars `CLAUDE_STANDBY_*`;
extension id `claude-standby-cockpit`. Kept as legacy: the `~/.claude/auto-
resume/` data dir, `plugin/` scripts dir, and internal ar_/car_ prefixes.
Done on branch `rename-claude-standby`, 254 tests green, live install/
uninstall smoke-tested. **Owner still needs to:** rename the GitHub repo to
claude-standby, republish the extension under the new marketplace id, and
(recommended) bump VERSION + cut a release tag. Until the repo rename, the
curl install URL and marketplace badges 404.

**2026-07-20 — pre-publish audit (D38).** Four-agent parallel review before
extension publish. Fixed two real bugs: uninstall now refuses a *clean* dev
checkout (not just dirty), and the installer rejects a truncated-but-parseable
download instead of swapping it in (pipefail + full-file sanity check).
Corrected living docs that described planned features (PROGRESS.md-anchored
prompt, stuck detection, resume verification, /warmup) as current. Cosmetic
rebrand of the status-bar idle label; removed a stale old-named vsix. 259
tests green. Repo About (description/homepage/topics) set on GitHub. Ready
for extension republish.

---

## 2026-07-20 — Countable CLI downloads + cockpit auto-update (D39)

Made CLI installs countable and gave the cockpit a way to keep the CLI current.
`install.sh` now pulls the stable `releases/latest/download/claude-standby.tar.gz`
asset instead of the uncounted `main` branch archive — GitHub reports
`download_count` only for uploaded release assets. Public one-liner and the
`update` path are unchanged; existing users self-heal on their next update
(first update still goes through their old branch-tarball installer, then every
update after is counted). Cut the v0.9.0 GitHub Release with the tarball asset;
`latest/download` resolves 200; counter reads via
`gh api repos/0xsaju/claude-standby/releases/latest --jq '.assets[0].download_count'`.

Cockpit 0.9.1: a best-effort once-a-day check compares the installed CLI against
the latest release and offers a one-click **Update** (runs the CLI's own
download-validate-swap `update`); plus a manual "Check for CLI update" menu item
/ command. Network reads are dependency-free (node https) and silent on failure.
Packaged `claude-standby-cockpit-0.9.1.vsix` (38.68 KB) — needs republish to both
marketplaces. 259 tests green.

Handoff: to publish the cockpit update, run `ovsx publish` (Open VSX) and upload
the 0.9.1 vsix to VS Marketplace. Operational rule going forward: cut a fresh
GitHub Release on every user-facing engine change, else `latest/download` lags
`main` and the cockpit won't see the new version.

## 2026-07-22 — Field report: resume burned its attempts against the next window's limit (D40)

Root-caused the user's failed DeenMate resume from the cockpit journal: attempt
1 *worked* — it continued the pinned session for ~8 minutes — then hit the NEXT
5-hour window's limit ("resets 12:40am"). The failure path ignored that
announced time and retried on the blind backoff (5 min × attempt), so attempts
2 and 3 fired into the still-active limit and burned `max_resumes`. Fix (D40):
the resume-failure path now parses the announced reset from the attempt's
output (F1, same sanity window as the probe path) and reschedules to reset +
grace, journaling `reset-detected`; blind backoff remains the fallback for
unparseable output. VERSION 0.9.1 — **needs a fresh GitHub Release cut** (D39
rule) so `latest/download` and the cockpit update check see it.

Second field report: users without the status-line sensor never see the
**At reset** chip (it was rendered only when a local reset snapshot exists), so
the feature was undiscoverable. Cockpit 0.9.2: the chip always renders —
disabled with a tooltip pointing at Setup when no snapshot — and the
Auto-detect hint explains how to unlock it. Backfilled the missing 0.9.1
CHANGELOG entry. USER-GUIDE retry sections updated; 263 tests green (4 new:
bounce reschedules to the announced reset, waits, consumes one attempt,
journals; existing backoff test pinned to an unparseable display).

Handoff: engine fix + cockpit change are code-complete and tested. Still to
do by the owner: cut the v0.9.1 release tag + tarball asset, package/republish
the 0.9.2 vsix (Open VSX + VS Marketplace). C6 real-limit `--resume` proof
remains open — though this field report is strong live evidence: attempt 1 DID
continue session d52201ca headlessly after a real limit (worked 8 min before
hitting the next window).

## 2026-07-22 (later) — Sensor offered at install time (D41)

Follow-up to the "At reset" discoverability fix: the user asked why the
status-line sensor isn't part of install if the core experience leans on it.
Answer preserved in D41 — it edits Claude Code's own settings.json, so it must
stay consent-based — but it's now *offered* everywhere instead of hidden:
`install.sh` prompts "Enable it? [Y/n]" on a tty (`CAR_SETUP_STATUSLINE=
yes|no|ask` for scripts; silent already-registered path refresh; hint line
when skipped; `--update` never prompts), and the cockpit Setup checklist has a
neutral "Status-line sensor" row with one-click Enable (read-only settings
grep for status, write via CLI, D21). setup-statusline.sh itself is unchanged
except its header comment. 268 tests green (5 new installer-offer tests;
installer test section pinned to CAR_SETUP_STATUSLINE=no so suite runs can
never prompt or touch the real settings.json). USER-GUIDE §2 + extension
CHANGELOG updated. Still pending from earlier today: cut the v0.9.1 release,
package/republish the 0.9.2 vsix.

## 2026-07-23 — Published v0.9.1 (engine) + ext-v0.9.2 tag

Committed both slices (4586ee1) and published: GitHub Release v0.9.1 cut with
the `claude-standby.tar.gz` asset — `latest/download` verified serving 0.9.1,
so installs/updates (and the cockpit's update check) now get the D40 daemon
fix. Pushed `ext-v0.9.2`; the publish workflow ran green but BOTH marketplace
steps were SKIPPED — the repo has no `VSCE_PAT`/`OVSX_TOKEN` secrets. Handoff:
extension 0.9.2 is packaged at `vscode-extension/claude-standby-cockpit-
0.9.2.vsix`; to ship it either add those two secrets and re-run the workflow
(Actions → Publish extension → Run workflow), or publish manually (`npx ovsx
publish <vsix> -p <token>` / `npx @vscode/vsce publish --packagePath <vsix>
-p <PAT>`). D40's fix gets its first real-world verification on the next
actual limit hit.

## 2026-07-23 (later) — `update` offers the sensor too (D42), v0.9.2 released

Field question: old users never saw the D41 sensor offer — it lived only in
the fresh-install path, and `--update` exited before any prompting. Now the
offer is a shared function called from both paths: registered → silent
path-refresh; unregistered → the [Y/n] question, but on update only ONCE
ever (marker `$AR_HOME/statusline-offered`, written whenever the question is
asked or CAR_SETUP_STATUSLINE=yes is used, so a decline is never re-nagged).
Note the one-release lag: `update` runs the currently-installed installer, so
existing users see the offer from their second update onward. VERSION 0.9.2,
release cut; 272 tests green (4 new update-offer tests; sensor tests now pin
CLAUDE_STANDBY_STATE so markers never touch the real data dir). USER-GUIDE
§2/§5 + D42. Extension still 0.9.2 (unchanged) — marketplace publish still
blocked on the VSCE_PAT/OVSX_TOKEN repo secrets.
