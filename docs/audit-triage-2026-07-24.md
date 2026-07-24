# Audit Triage — independent verification of the 2026-07-24 GPT audit

Verified all 36 findings against the live code (8 Sonnet verifiers + Opus synthesis). **32 confirmed, 4 partial, 0 refuted, 0 unverifiable. 10 must-fix before publish.** Companion to `independent-audit-2026-07-24.md`.

## Verdict table

| id | verdict | severity | disposition | must-fix |
|----|---------|----------|-------------|----------|
| F03 | CONFIRMED | blocker | real-bug | **YES** |
| F04 | CONFIRMED | blocker | real-bug | **YES** |
| F02 | CONFIRMED | high | real-bug | **YES** |
| F05 | CONFIRMED | high | real-bug | **YES** |
| F10 | CONFIRMED | high | real-bug | **YES** |
| F11 | CONFIRMED | high | real-bug | **YES** |
| F15 | CONFIRMED | high | real-bug | **YES** |
| F20 | CONFIRMED | high | real-bug | **YES** |
| F23 | CONFIRMED | high | real-bug | **YES** |
| F28 | CONFIRMED | high | real-bug | **YES** |
| F16 | CONFIRMED | high | real-bug | — |
| F18 | CONFIRMED | high | real-bug | — |
| F24 | CONFIRMED | high | real-bug | — |
| F33 | CONFIRMED | high | out-of-scope | — |
| F01 | CONFIRMED | medium | real-bug | — |
| F06 | CONFIRMED | medium | real-bug | — |
| F08 | CONFIRMED | medium | real-bug | — |
| F09 | CONFIRMED | medium | real-bug | — |
| F12 | CONFIRMED | medium | real-bug | — |
| F13 | CONFIRMED | medium | real-bug | — |
| F14 | CONFIRMED | medium | real-bug | — |
| F17 | CONFIRMED | medium | real-bug | — |
| F19 | CONFIRMED | medium | real-bug | — |
| F21 | CONFIRMED | medium | real-bug | — |
| F22 | PARTIAL | medium | real-bug | — |
| F25 | CONFIRMED | medium | real-bug | — |
| F26 | CONFIRMED | medium | real-bug | — |
| F27 | PARTIAL | medium | by-design | — |
| F29 | PARTIAL | medium | by-design | — |
| F32 | CONFIRMED | medium | real-bug | — |
| F34 | CONFIRMED | medium | real-bug | — |
| F35 | CONFIRMED | medium | real-bug | — |
| F07 | CONFIRMED | low | by-design | — |
| F30 | PARTIAL | low | by-design | — |
| F31 | CONFIRMED | low | real-bug | — |
| F36 | CONFIRMED | info | by-design | — |

---

# Independent Triage — `claude-standby` audit (2026-07-24)

## 1. Revised publish verdict: **FIX-THEN-SHIP**

Do not ship the current tree as-is, but this is not a fundamental redesign — it's a bounded set of fixes. The audit is substantively correct on the points that matter: this tool spends real quota and picks which conversation to resume unattended, and several of its core identity/safety properties are currently unreliable. Specifically, `resume-at` and `start` can pin and later resume the **wrong session** (F03/F04), an 8:30am schedule silently fires at **00:30** (F02), the **max_resumes cap is defeated** by a single non-numeric value (F20), and any transient probe failure is **misread as a rate limit** and drives a real resume (F23). Those are correctness/safety-rail failures, not cosmetic alpha roughness, and they directly contradict the tool's own promise ("resume the *same* session", C5 "max_resumes enforced", C1 "never the exit code"). The webview XSS and terminal-injection paths (F10/F11) are reachable just by opening a hostile repo. None of these require a rewrite — each has a cheap, local fix — so the right call is a focused hardening pass, then ship as alpha. The remaining ~19 findings are real but tolerable in an alpha with honest docs.

## 2. Must-fix before publish (priority-ordered)

1. **F03 — session resolution isn't fail-closed.** Path-encoding collisions, regex (not fixed-string) prefix match, and an all-hyphen-accepting UUID regex let `resume-at` pin a session from an unrelated workspace. *Blocks:* wrong-session resume is the tool's core safety promise. *Fix:* fixed-string exact match, cross-check the transcript `cwd`, strict UUID regex, and error (not silently pick newest) on ambiguity.
2. **F04 — `start` inherits stale session_id/cycle state.** `ar_task_upsert` merges instead of resetting, so a new task keeps a prior task's pinned session, `limit_seen`, prompt template. *Blocks:* new task resumes an old unrelated conversation. *Fix:* `start` must reset the record (clear session_id/cycle fields), not merge.
3. **F20 — non-numeric `max_resumes` bypasses the cap.** `[ "$COUNT" -ge "not-a-number" ]` errors → treated as false → resume proceeds; direct C5 violation. *Blocks:* safety-rail bypass. *Fix:* validate/coerce numeric fields before the comparison; fail closed on garbage.
4. **F02 — leading-zero clock times parsed as octal.** `08:30`/`09:30` silently reschedule to `00:30`; unattended resume fires ~8h early. *Blocks:* wrong-time quota burn with no error shown. *Fix:* `printf '%02d' "$((10#$hour))"` (force base-10) and reject out-of-range.
5. **F23 — any nonzero probe exit is treated as "limited."** Network/auth/transient failure → `limit_seen=1` → later clean probe → real `--resume`; contradicts C1. *Blocks:* spends quota on a false limit signal. *Fix:* only treat as limited when the F1 message matches; distinguish "error" from "limited."
6. **F15 — unlocked read-modify-write loses concurrent updates.** Documented multi-workspace use; 40 parallel writes → 1 survivor. Can silently drop a `status=cancelled` or a `resume_count` increment (C5 bookkeeping). *Blocks:* data loss + safety-rail integrity in a supported flow. *Fix:* add a lock (mkdir/flock) around the RMW cycle.
7. **F28 — statusline sensor sources executable user config + clobbers unrelated status lines.** `exit 23`/`sleep 2` in config break C4; substring registration check overwrites then deletes a user's real status line; `backup_settings` always returns 0. *Blocks:* C4 ("always exit 0") violation + silent user-config data loss. *Fix:* don't source config in the sensor path (or sandbox it), match the exact registered command, check backup success.
8. **F11 — terminal command injection via unquoted `claudeStandby.cliPath`/`CLAUDE_STANDBY_CLAUDE_BIN`.** A hostile repo's `.vscode/settings.json` sets `cliPath`; `term.sendText` types it into a real shell on the "Update" click. *Blocks:* code execution from opening a repo. *Fix:* mark settings `restricted`/scoped, declare untrusted-workspace handling, validate the path; avoid `sendText` for update.
9. **F10 — webview XSS: unescaped state fields + `unsafe-inline` CSP + unvalidated About URLs.** `javascript:` in `author.github` (workspace-settable) renders without prior compromise. *Blocks:* reachable XSS by opening an untrusted repo. *Fix:* `esc()` all interpolated state, validate URL scheme (http/https only), drop `unsafe-inline` / use nonces, restrict the settings.
10. **F05 — reschedule during grace/in-flight doesn't preempt the old action.** Grace check is just `status=waiting`, which a reschedule also sets; original daemon runs to completion and burns a resume. *Blocks:* contradicts the UI's "reschedule to change it" contract, spends unintended quota. *Fix:* tie grace/in-flight to the serviced generation/resume_at; signal the old daemon on reschedule.

## 3. Should-fix soon (not blocking)

- **F24** — daemon proceeds to `--resume` even when the `status=resuming` write failed; cockpit `cancel` ignores CLI exit code. Fail-closed on write errors.
- **F16** — pidfile TOCTOU allows two daemons per workspace; EXIT trap deletes any owner's pidfile. Atomic O_EXCL/mkdir lock + ownership token.
- **F18** — `uninstall` leaves live daemons/resumes running and swallows sensor-remove exit code. Enumerate + kill `daemons/*.pid` before `rm -rf`.
- **F14** — immediate cancel depends on `pgrep`; without it an in-flight resume keeps burning quota. Fall back to process-group kill.
- **F01** — advertised zero-probe reset path is mathematically unreachable; always fires one extra probe. Fix the `RESET_TARGET` comparison so the no-probe branch can trigger.
- **F13** — runtime files world-readable (0644); predictable `/tmp/claude_rate_cache_$USER.json` trusted without owner/mode check. `umask`/chmod hardening + validate cache ownership.
- **F09** — `cancel` trusts pidfile PID with no positive-int/identity check (`-1`/`0` broadcast). Validate PID.
- **F25** — daemon timing env values reach `sleep`/arithmetic unvalidated; fractional value kills the daemon under `set -u`, negative interval re-probes every tick (C6). Clamp all numeric env like `RESET_GRACE` already is.
- **F17** — distinct workspaces can collapse to the same live-output file, corrupting the bounce-guard. Use a collision-resistant digest.
- **F21** — text JSON engine mishandles C0 control chars and `\n` ordering; jq vs python journal-default divergence. Fix escape/unescape; align engines.
- **F32** — divergent UUID regexes (`{32,40}` vs `{8,64}`) and triplicated sensor checks; root cause behind F03. Consolidate validators.
- **F08** — `watch` on a fresh runtime dir fails (`tail` no such file). `mkdir -p` before touch.
- **F19** — live output/log/journal unbounded; journal grows the shared state.json forever. Cap/rotate.
- **F12** — `rm -rf $CAR_INSTALL_DIR` with no sentinel/canonicalization (test-only var today). Require an install sentinel before delete.
- **F26** — installer rm-before-mv is non-atomic, no trap/rollback. Move-into-place or add cleanup trap.
- **F34** — installer tests run against `git archive HEAD`, missing the real uncommitted diffs; no CI runs the suite on any OS; missing regressions for the bugs above. Add CI + regression tests.
- **F35** — multiple doc claims are stale/false (grace "within a minute", `8:30pm` broken example, `status` vs `list`, "nothing polls a server", uninstall leaves live daemon). Correct docs.
- **F31** — dead `commands` channel; stale checked-in VSIX changelog. Remove dead field / regenerate.
- **F06** — cockpit composer silently switches to newest session when pinned one is outside the 6-item window, and falls back to `auto` on invalid time. Inject pinned session; surface time errors.

## 4. Accepted / by-design / out-of-scope

- **F07** — DST 1h skew is explicitly documented in-code as an accepted rare-window tradeoff; self-corrects via bounce-guard. Fine for alpha.
- **F27** — C1 "unmeasured shapes": each sub-claim is documented/opt-in (D29/D45) and bounded by the F1 bounce-guard re-check. Framing overstated; acceptable, but tighten the session regex (overlaps F03).
- **F29** — C5 gaps: allowlist and quiet-hours absence are openly disclosed in README/CLAUDE.md; "progress-stall/outcome verification" are the audit's extrapolation, not required text. Safe-by-default honored. Fine for alpha.
- **F30** — cockpit `claude --resume` is intentional feature D44 (interactive, id-validated), not a hidden bypass; the stale header comment is the only real (cosmetic) defect. Fix the comment.
- **F33** — publish workflow unpinned `npx` + job-wide secrets is a genuine supply-chain risk to the maintainer's marketplace creds, but it's the release pipeline, not the shipped alpha runtime, and the extension isn't published yet. Harden before first real run; doesn't block CLI alpha.
- **F36** — no raw provenance artifacts for HOOK-FINDINGS; not publishing real session/path/usage data is a reasonable solo-alpha privacy tradeoff. Info-only. Fine.

## 5. Refuted / overstated

No finding was fully refuted — the audit's factual observations largely hold. Overstated ones:
- **F22 (PARTIAL)** — corrupt/future state reported "healthy" is real (no schema-version or type validation in `doctor`), but the "additive fields without version bump" sub-claim is wrong: D27/D28 explicitly document keeping `version` at 2 for additive default-'' per-task fields. That half is intentional, logged policy, not schema drift.
- **F27 / F29 / F30 (PARTIAL)** — real underlying facts, but the audit's "systematic" / "absent" framing overstates risk given documented, bounded, or opt-in status (see §4).
- **F35** — mostly confirmed, but two bundled sub-claims are weak: the `start` "detection not shipped" line is accurate (not drift), and the static post-reset "no probe" claim is arguably by-design.

## 6. Needs real-limit verification (C6 open item)

None of the 36 required a REFUTED-for-lack-of-hardware verdict — all were reproducible in-env with `test/fake-claude.sh` and env overrides. However, three depend on Claude Code's *real* runtime formats that C6/HOOK-FINDINGS already flag as unverified, and should be confirmed against a real account before relying on them:
- **F23 / F01** — the actual probe exit-code vs F1-message behavior on a genuine rate limit (F1 wording, F4 `resets_at` presence).
- **F27(2)/(3)** — the real limit-message reset-time phrasing and whether a status-line actually caches `rate_pct` to the predictable `/tmp` path.
- **F36** — the underlying F1/F2/F4 formats themselves remain the standing C6 "real limit burns only for milestone verification" open item.

These fold into the existing C6 milestone check rather than blocking the alpha.
