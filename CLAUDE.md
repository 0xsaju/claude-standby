# claude-standby — guardrails

Tool that lets Claude Code tasks survive rate-limit hits: detect the limit,
wait until reset, auto-resume the session. Engine = portable scripts
(`plugin/scripts/`), cockpit = VS Code extension (`vscode-extension/`),
contract = `~/.claude/auto-resume/state.json`. The Claude Code Stop-hook
path was removed 2026-07-19 (D31): detection reads local data, not hooks.

## Hard constraints — do not violate

- **C1 — No invented data shapes.** Detection logic may only match formats
  MEASURED and documented in `docs/HOOK-FINDINGS.md`: F1 (the limit
  MESSAGE the probe reads), F2 (the session store for `--resume` ids), F4
  (the status-line rate stream: `used_percentage` + `resets_at`). No
  guessed payloads. Auto-detect = read a rate snapshot (F4) if present,
  else one `haiku` probe that trusts the F1 message — never the exit code.
- **C2 — Portable bash.** POSIX-compatible bash, no hard `jq` dependency
  (fallback chain: jq → python3 → awk/sed on canonical layout), no GNU-only
  flags without a BSD alternative. Target Linux + macOS; Windows best-effort.
- **C3 — Engine layout.** The engine is plain scripts under `plugin/scripts/`
  (the `plugin/` name is legacy — there is no Claude Code plugin anymore; the
  plugin manifest + marketplace were removed with the hooks, D33). The CLI
  (`bin/claude-standby`) is the only interface (D17); version lives in the
  top-level `VERSION` file. No slash commands (they cost tokens and can't run
  while limited).
- **C4 — Sensors never break the host.** The status-line sensor
  (`statusline.sh`) always `exit 0`, finishes fast, chains (never clobbers)
  any existing status line, never stderr noise. It must be invisible when it
  fails.
- **C5 — Safety rails.** `max_resumes` enforced; stuck detection; permission
  allowlist by default (`--dangerously-skip-permissions` only behind
  explicit opt-in); optional quiet hours.
- **C6 — Real quota is precious.** All iterative testing uses
  `test/fake-claude.sh`. Real limit burns only for milestone verification.

## File map

- `plugin/scripts/lib.sh` — state.json helpers, logging, notify, timestamps,
  rate-snapshot readers (`ar_rate_*`)
- `plugin/scripts/daemon.sh` — detached wait-and-resume daemon (tiers,
  backoff, max_resumes, pidfile per workspace; auto-detect via rate snapshot
  F4 or `haiku` probe F1; reset safety grace D30)
- `plugin/scripts/statusline.sh` — status-line rate SENSOR: captures
  `used_percentage`/`resets_at` into `rate.json` (F4); chains any existing
  status line; always exit 0 (C4)
- `plugin/scripts/setup-statusline.sh` — (de)register the sensor in
  ~/.claude/settings.json (opt-in; python3 JSON edit, backup, reversible)
- `plugin/scripts/task-*.sh` — command backends
  (task-resume-at.sh = scheduling + spawns the daemon, D10)
- `bin/claude-standby` — the CLI, the only interface (D15/D17)
- `VERSION` — the tool version (read by the CLI's `version`; bump on release)
- `install.sh` — curl-pipe-bash installer; links the CLI (no hooks, no plugin)
- `vscode-extension/` — cockpit MVP: plain JS, reads state.json, writes
  via CLI (D21); keep it thin, no build tooling
- `test/fake-claude.sh` — claude CLI stub; `test/run-tests.sh` — test suite
- `docs/USER-GUIDE.md` — user manual (keep in sync with behavior changes)
- `docs/ARCHITECTURE.md` — full design; `docs/DECISIONS.md` — append-only
  decision log; `docs/HOOK-FINDINGS.md` — MEASURED formats we rely on
  (F1 limit message, F2 session store, F4 rate stream)
- (the Stop/SessionEnd hook path was removed 2026-07-19, D31 — detection
  reads local data, not hooks)

## Working conventions

- **Commits carry no AI attribution.** No `Co-Authored-By: Claude …` or
  any generated-with trailer/byline — ever.
- Run `bash test/run-tests.sh` before ending a session; keep it green.
- **Update `PROGRESS.md` before ending any session** (we dogfood our own
  convention) and leave a one-paragraph handoff note.
- Schema changes to state.json: bump `version`, log in `docs/DECISIONS.md`.
- Vertical slices, one per session.
