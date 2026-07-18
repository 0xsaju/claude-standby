# PROGRESS

Living checklist for claude-auto-resume. Update before ending any session.

## Done

- [x] **Phase 0 — Scaffold + harness** (2026-07-18)
  - [x] Repo structure: `plugin/` (manifest, hooks, commands, scripts),
        `test/`, `docs/`, `vscode-extension/.gitkeep`, CLAUDE.md,
        .gitignore, MIT LICENSE
  - [x] Governance docs: ARCHITECTURE.md, DECISIONS.md (D1–D9),
        HOOK-FINDINGS.md template (STATUS: UNVERIFIED)
  - [x] `plugin/scripts/lib.sh` — state.json helpers with atomic writes and
        a jq → python3 → awk/sed text-tier fallback chain (D2), logging,
        notify (osascript → notify-send → log-only), timestamp helpers
        (BSD/GNU dual path)
  - [x] `/task-start`, `/task-status`, `/task-cancel` commands + backends
  - [x] `plugin/scripts/on-stop.sh` — hook entry, detection **stubbed**
        per C1 with TODO(C1) markers citing docs/HOOK-FINDINGS.md
  - [x] `test/fake-claude.sh` — claude CLI stub (clean/limit modes, resume,
        stream-json, JSONL transcripts; format explicitly GUESSED, D5)
  - [x] `test/run-tests.sh` — 90 tests, all green on macOS (BSD userland):
        per-engine state suites (jq / python3 / text), cross-engine
        interop, timestamps, fake-claude, on-stop smoke
  - [x] Cleanup pass: user-facing README.md added, junk files removed,
        JSON/syntax/test verification re-run, repo initialized (D8)
- [x] **Phase 2 — Daemon + manual scheduling** (2026-07-18, reordered
      before Phase 1 per D10)
  - [x] `/task-resume-at <when> [tier]` — post-limit manual scheduling;
        parses ISO / HH:MM / relative (2h30m) / now; spawns daemon
  - [x] `plugin/scripts/daemon.sh` — 60 s wake loop (suspend-safe),
        importance tiers (critical/normal/low), resume execution,
        max_resumes cap, failed-attempt backoff, pidfile dedup (D11),
        stands down on cancel within one tick
  - [x] Config file `~/.claude/auto-resume/config` (AR_CFG_*, D12);
        claude binary swappable for tests (C6)
  - [x] Test suite extended to 119 (parse, schedule, daemon lifecycle:
        clean / limit-bounce / cancel / caps / tiers) — all green
  - [x] Docs overhaul: professional README (features, status matrix,
        mermaid lifecycle), full docs/USER-GUIDE.md manual,
        .claude-plugin/marketplace.json for installability
- [x] **Auto reset detection (probe-based)** (2026-07-18, D13)
  - [x] Bare `/task-resume-at` (or `auto`, or tier-only) → daemon probes
        with a minimal haiku call every 30 min; first success = limit
        provably lifted → resume. Exit-code-only, C1-safe
  - [x] Probe failures don't consume max_resumes; 6 h give-up window
        catches weekly caps with an honest notification
  - [x] state.json schema v2: optional `resume_mode: at|auto` (v1 files
        still readable); fake-claude gained FAKE_CLAUDE_MODE_FILE for
        mid-run limit-lift simulation; tests 119 → 129, all green
- [x] **First measured detection surface (F1)** (2026-07-18, D14)
  - [x] Real headless limit output captured by user: "You've hit your
        session limit · resets 4:10pm (Asia/Dhaka)" → HOOK-FINDINGS F1
  - [x] `ar_parse_reset_time()` + `AR_LIMIT_PATTERN` in lib.sh; auto mode
        now reads the announced reset time from the first failed probe
        and waits for exactly that moment (interval polling = fallback)
  - [x] Exit codes never trusted alone (limited calls may exit 0 — exit
        code still unmeasured): probe success = exit 0 AND no limit
        pattern; resumes that bounce with exit 0 are treated as failed
  - [x] fake-claude stdout re-pointed to measured format (D5);
        FAKE_CLAUDE_LIMIT_EXIT + FAKE_CLAUDE_RESET_DISPLAY test knobs;
        tests 129 → 138, all green

## In progress

- (nothing)

## Next

- [ ] **Human action required:** run the probe (`claude-limit-hook-probe/`)
      through a real limit hit and paste hooks.log excerpts into
      `docs/HOOK-FINDINGS.md` — Phase 1 is blocked on this
- [ ] **Real-world smoke test:** on the already-limited test subscription,
      install the plugin, `/task-resume-at <reset time>`, verify the daemon
      resumes when the limit lifts (first real-quota milestone, C6)
- [ ] **Phase 1 — Detection:** real `detect_limit()` in on-stop.sh, limit
      message → `resume_at` parser, task-done vs limit-hit branching,
      session_id capture (D6); update fake-claude fixture text (D5)
- [ ] **Phase 3 — Loop closure + polish:** stuck detection (PROGRESS.md
      unchanged across two resumes), resume-verification fallback prompt,
      `/warmup` scheduler installer, reboot-surviving schedules
- [ ] **Phase 4:** VS Code cockpit reading state.json

## Handoff note (Phase 0+2 → real-world test / Phase 1)

The tool is now functionally useful without detection: `/task-resume-at`
covers the post-limit case with the human as the detector (D10), and
`daemon.sh` executes the full wait→resume→done/backoff/failed lifecycle —
119/119 tests green against fake-claude, plus a manual end-to-end run with
a detached daemon. Next milestone is the first real-quota test on the
already-limited subscription: install the plugin there, schedule a resume
for the reset time, and confirm the daemon fires; while at it, run the
probe hooks so `docs/HOOK-FINDINGS.md` finally gets real payload data —
that unblocks Phase 1 detection, which just needs to write the same state
fields the manual command writes. All state manipulation goes through
lib.sh's public API (`ar_task_get/upsert/set`, `ar_journal_append`); don't
reach into state.json directly. Keep docs/USER-GUIDE.md in sync with any
behavior change.
