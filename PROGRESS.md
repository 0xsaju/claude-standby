# PROGRESS

Living checklist for claude-auto-resume. Update before ending any working
session. Detailed rationale for every decision: `docs/DECISIONS.md`
(D1–D23). All dates 2026-07-18 unless noted.

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
- [x] **Test suite: 219 green** — three JSON engines, daemon lifecycle,
      auto mode, session discovery/pinning, hooks setup/removal,
      installer cycle, CLI surface.

## Next

- [ ] **Waiting on a real limit hit** (hooks now capture automatically to
      `logs/hook-payloads.log`): paste findings into
      `docs/HOOK-FINDINGS.md` → unblocks Phase 1
- [ ] **Phase 1 — Hook detection:** real `detect_limit()` in on-stop.sh,
      hook-payload session_id capture (D6) → zero-typing scheduling
      (session resume itself already works via F2 store discovery)
- [ ] **Real-limit verification of `--resume`:** on the next limit hit,
      schedule with a pinned session and confirm the conversation
      actually continues (C6 milestone burn)
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
cockpit. 219 tests green. Still pending: verify `--resume` against a real
limit once one hits (C6), plus everything blocked on hook-payload data.
All state manipulation goes through lib.sh's public API; detection code
may only match formats documented in docs/HOOK-FINDINGS.md (C1). Keep
docs/USER-GUIDE.md in sync with any behavior change, and keep the VS Code
extension a thin shell.
