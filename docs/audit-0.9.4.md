# Pre-publish audit — v0.9.4 (D44 "auto-resume visibility" changeset)

Date: 2026-07-24. Method: an 8-dimension multi-agent finder pass (daemon/stream,
lib+CLI, installer/sensor, cockpit dashboard.js, cockpit extension.js,
portability/constraints, version/docs, test-suite) produced **19 findings**. The
multi-agent verification+synthesis pass hit the session limit mid-run, so each
finding was then **verified by direct code inspection** and resolved. All raw
findings are preserved in the workflow journal
(`subagents/workflows/wf_12a1f296-362/journal.jsonl`).

**Publish verdict: fix-then-ship → ready.** All must-fix items are resolved;
three low/info items are accepted with rationale. 286 tests green.

## Notable behavior change (please note)

The top finding: **stream-json was the resume default**, so the daemon's limit
**detection** (the bounce guard + reset parser — a C5 safety rail) ran against
an **unmeasured** output format (C1), untestable without real quota (C6). Fix:
**`AR_CFG_RESUME_STREAM` now defaults OFF (plain output)** so detection stays on
the measured F1 format. The live panel still works on plain output; stream-json
(granular per-step live view) is now **strict opt-in** (`AR_CFG_RESUME_STREAM=1`).
To make it safe-by-default later, measure real claude's stream-json limit output
and record it in `docs/HOOK-FINDINGS.md`.

## Fixed (16)

| # | Sev | File | Issue | Fix |
|---|-----|------|-------|-----|
| 2/13 | high | daemon.sh | stream-json default made detection run on an unmeasured format (C1/C5/C6) | default `AR_CFG_RESUME_STREAM` OFF; stream-json opt-in; dropped the false "matches in JSON too" claim |
| 3 | high | dashboard.js | `renderLive` threw on a bare `null` JSON line (`null.type`) → whole webview render broke | guard `!o || typeof o !== 'object'` before property access |
| 1 | high | install.sh | non-interactive install: a failed/EOF read set reply="" → hit the `*)` default → enabled the sensor + edited settings.json **without consent** | only honor the Y-default when `read` actually succeeds; EOF/no-tty → skip |
| 4 | med | dashboard.js | `stateSig` keyed live output on `.length`; `readLiveOutput` caps at 8000 bytes → length pins → **live panel freezes** past 8000 bytes | key on the tail (`slice(-180)`) so new output changes the signature |
| 7 | med | bin/claude-standby | `output --workspace` didn't canonicalize → a trailing slash (tab-completion) derived the wrong key → "No resume output" | `cd … && pwd` canonicalization like `resume-at` |
| 8 | low | bin/claude-standby | `output` ignored the `--workspace=`/`-w` forms → silently showed cwd's output | parse all three forms |
| 10 | low | extension.js | `openSession` interpolated an unvalidated `session_id` into a terminal command | reject anything not UUID-shaped |
| 11 | low | dashboard.js | `_editing` not reset on panel dispose → reopened dashboard could freeze (refresh suppressed) | reset `_editing=false` on dispose |
| 12 | low | extension.js | `readLiveOutput` comment implied a capped read; it read the whole file then sliced | corrected the comment (file is truncated per attempt; tail-only kept) |
| 14 | low | daemon.sh | `--output-format` prepended unconditionally → duplicated if a user set it in EXTRA_ARGS | only add when EXTRA_ARGS has no `--output-format` |
| 6 | low | README.md | commands table omitted the new `output` command | added |
| 16 | low | run-tests.sh | "stream off is plain text" assertion couldn't tell plain from JSON (both contain the result text) | assert JSON markers present/absent for stream-on/off |
| 5 | med | (tests) | `renderLive` had zero coverage; fake-claude stream-json vs real claude divergence unguarded | added `test/cockpit-smoke.js` (null-line + both content shapes) |
| 19 | info | run-tests.sh | suite never syntax-checked the shipped extension JS | `node --check` both files + smoke, guarded by node availability |
| 17 | low | run-tests.sh | `output` tail-fallback branch untested | added a tail-fallback + glued-form test |

## Accepted / documented (3)

- **#9 (low)** — `ar_resume_live_file` (`sed`) vs the cockpit's JS `replace` can
  diverge for **non-ASCII workspace paths** (byte-wise sed under a C locale vs
  JS code units). Effect is graceful: the cockpit live panel is simply blank for
  those workspaces (`readLiveOutput` swallows ENOENT); the CLI `output` command
  is unaffected (same `sed`). Robust fix (cockpit reads via `claude-standby
  output`) deferred; documented here.
- **#15 (low)** — a single global `_editing` shared by both composers, cleared
  on `focusout`. Moving focus between the two composers can briefly flip it; a
  refresh in that window could still clobber. Mitigated by the dispose reset and
  focus gating; per-composer tracking deferred.
- **#18 (info)** — live output files under `~/.claude/auto-resume/live/` are
  truncated per attempt but never unlinked (one tiny file per distinct
  workspace). Intentionally retained so the cockpit can show a just-finished
  resume's output for `done`/`failed`; removed with the data dir on uninstall.

## Refuted / non-issues

The workflow's interrupted run reported "12 refuted," but that count is
unreliable — many were verifier agents that failed on the session limit, not
genuine refutations. Direct inspection found no false finder findings worth
recording; every finding above was real.
