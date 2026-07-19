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
