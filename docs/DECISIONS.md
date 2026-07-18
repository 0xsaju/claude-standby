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
