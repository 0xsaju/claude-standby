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
- [x] **Test suite: 236 green** — three JSON engines, daemon lifecycle,
      auto mode (incl. the armed/limit_seen gate), session
      discovery/pinning (incl. bad-value refusal), prompt/workspace flags,
      hooks setup/removal, installer cycle, CLI surface. Cockpit client JS
      additionally exercised out-of-tree via jsdom (21 assertions: AM/PM
      conversion, escaping, chip precedence, message wiring) — kept out of
      the suite to preserve the no-tooling convention.
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

- [ ] **Waiting on a real limit hit** for the HOOK path (hooks capture to
      `logs/hook-payloads.log`): paste findings into
      `docs/HOOK-FINDINGS.md` → unblocks Phase 1. (Note: auto-detect probe
      mode is already proven; this is only for zero-typing hook detection.)
- [ ] **Phase 1 — Hook detection:** real `detect_limit()` in on-stop.sh,
      hook-payload session_id capture (D6) → zero-typing scheduling
      (session resume itself already works via F2 store discovery)
- [ ] **Multiple schedules per workspace** (cockpit renders the list
      already): schema v3 (tasks get ids), per-schedule daemon + cancel.
- [ ] **Quota-free reset inference in the engine:** the 5-hour window is
      derivable from local transcript timestamps (verified on the F2
      store) — move it into the daemon so auto-detect sleeps to the
      inferred reset instead of probing, and populate a concrete time into
      the cockpit's "When" caption. Document as HOOK-FINDINGS F4.
- [ ] **C6 — real-limit verification of `--resume`** (still open): on a
      genuine limit, with auto-detect armed and `limit_seen` set, confirm
      the daemon resumes the pinned session and the conversation continues.
- [ ] **Phase 3 — Polish:** stuck detection (PROGRESS.md unchanged across
      two resumes), resume-verification fallback prompt, `/warmup`
      scheduler, reboot-surviving schedules (launchd/cron one-shots)
- [ ] **Cockpit:** manual F5 verification pass, then marketplace
      publishing (needs a publisher account)
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
cockpit. 236 tests green. **C6 (real-limit `--resume`) is still UNVERIFIED**
— an earlier PROGRESS note claiming it was proven was written by a rogue
resume: auto-detect had been scheduled on a *non-limited* session, the
first probe succeeded, and the daemon resumed a healthy session (D27, now
fixed). That was the bug, not a verification. Genuine real-limit proof
still needs an actual limit while auto-detect is armed with `limit_seen`
set. A subtle install gotcha also surfaced: the cockpit drives the CLI at
`~/.claude-auto-resume` (a git clone), which can lag the repo — if
`--session` seems ignored, `git -C ~/.claude-auto-resume pull` to refresh
it. Still pending: everything blocked on hook-payload data (Phase 1).
All state manipulation goes through lib.sh's public API; detection code
may only match formats documented in docs/HOOK-FINDINGS.md (C1). Keep
docs/USER-GUIDE.md in sync with any behavior change, and keep the VS Code
extension a thin shell.
