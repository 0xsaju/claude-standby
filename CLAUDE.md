# claude-auto-resume — guardrails

Tool that lets Claude Code tasks survive rate-limit hits: detect the limit,
wait until reset, auto-resume the session. Engine = Claude Code plugin
(`plugin/`), cockpit = future VS Code extension (`vscode-extension/`),
contract = `~/.claude/auto-resume/state.json`.

## Hard constraints — do not violate

- **C1 — No invented payload shapes.** Detection logic may only match
  payloads/transcript formats documented in `docs/HOOK-FINDINGS.md`. Until
  that file has real probe data, detection stays a stub with TODO(C1)
  markers. `plugin/scripts/on-stop.sh` is designed so only its trigger
  changes if hooks turn out not to fire (supervisor-wrapper fallback).
- **C2 — Portable bash.** POSIX-compatible bash, no hard `jq` dependency
  (fallback chain: jq → python3 → awk/sed on canonical layout), no GNU-only
  flags without a BSD alternative. Target Linux + macOS; Windows best-effort.
- **C3 — Plugin layout.** Manifest only in `plugin/.claude-plugin/`;
  `hooks/`, `commands/`, `scripts/` at plugin root; hook command paths use
  `${CLAUDE_PLUGIN_ROOT}`.
- **C4 — Hooks never break the host.** Every hook script always `exit 0`,
  finishes fast (< 2s typical), logs to its own log, never stderr noise.
- **C5 — Safety rails.** `max_resumes` enforced; stuck detection; permission
  allowlist by default (`--dangerously-skip-permissions` only behind
  explicit opt-in); optional quiet hours.
- **C6 — Real quota is precious.** All iterative testing uses
  `test/fake-claude.sh`. Real limit burns only for milestone verification.

## File map

- `plugin/scripts/lib.sh` — state.json helpers, logging, notify, timestamps
- `plugin/scripts/daemon.sh` — detached wait-and-resume daemon (tiers,
  backoff, max_resumes, pidfile per workspace)
- `plugin/scripts/on-stop.sh` — Stop/SessionEnd hook entry (detection stub)
- `plugin/scripts/task-*.sh` — backends for the /task-* slash commands
  (task-resume-at.sh = manual post-limit scheduling, D10)
- `plugin/hooks/hooks.json`, `plugin/commands/*.md` — plugin wiring
- `.claude-plugin/marketplace.json` — local/GitHub install manifest
- `test/fake-claude.sh` — claude CLI stub; `test/run-tests.sh` — test suite
- `docs/USER-GUIDE.md` — user manual (keep in sync with behavior changes)
- `docs/ARCHITECTURE.md` — full design; `docs/DECISIONS.md` — append-only
  decision log; `docs/HOOK-FINDINGS.md` — probe results (source of truth
  for detection)
- `claude-limit-hook-probe/` — throwaway instrumentation plugin that
  produces HOOK-FINDINGS data; leave as-is

## Working conventions

- Run `bash test/run-tests.sh` before ending a session; keep it green.
- **Update `PROGRESS.md` before ending any session** (we dogfood our own
  convention) and leave a one-paragraph handoff note.
- Schema changes to state.json: bump `version`, log in `docs/DECISIONS.md`.
- Vertical slices, one per session.
