# Changelog

All notable changes to the Claude Auto-Resume Cockpit extension. The
extension is a thin UI over the `claude-auto-resume` terminal tool, so some
entries describe tool behavior the cockpit now surfaces.

## 0.8.8

- **"At reset" scheduling in the composer.** When your reset time is known
  locally, the When picker offers **At reset** (selected by default) — "you hit
  a limit → resume at your exact 5-hour reset," with no probing and no usage
  guess. **Auto-detect** remains for arming in advance (watch and resume
  whenever a limit hits). Each mode shows its own one-line hint. Matches the
  CLI's `resume-at reset`. The tier picker now says the `normal` grace is 5 min.
- The reset-time reader now honors `CLAUDE_AUTO_RESUME_RATE_FILE` and
  `AR_CFG_RATE_SOURCE` (matching the CLI), so "At reset" and the CLI never
  disagree about whether a reset time exists.

## 0.8.7

- **Exact reset time.** When your live usage data is available locally
  (streamed to Claude Code's status line, or an existing cache), the
  dashboard and status bar show the real reset moment and usage
  (`resets 6:00 PM · 54% used`) and auto-detect schedules to it — no polling,
  no quota. Zero setup when a cache exists; otherwise
  `claude-auto-resume setup-statusline` adds a small sensor.
- **Honest auto-detect countdown.** Armed auto-detect tasks now show
  `armed · resets 6:00 PM` (or the real next-check), replacing a misleading
  fixed countdown and the false "no quota" copy.
- **Post-reset safety buffer.** The resume fires a short beat after the
  reset instead of on the exact instant, so it doesn't bounce off a
  still-active limit. The `normal` tier's confirmation window is now 5
  minutes, giving you time to cancel after the notification.
- Three-state setup row (healthy / absent / corrupt) fixes a spurious red X
  on a fresh install.

## 0.8.5

- **Interrupted-resume detection.** A resume left stuck by a dead daemon is
  flagged as "resume interrupted" in the status bar, tooltip, and dashboard,
  with a Reschedule/Cancel prompt.
- Armed auto-detect tasks stand down after a bounded window instead of
  probing indefinitely.

## 0.8.0

- **Onboarding + dashboard redesign.** First run opens a setup checklist
  (CLI · Claude Code · state) with an inline Install action;
  once green it hands off to a full-page dashboard — current-workspace
  composer with an AM/PM time picker, scheduled-resumes list with live
  countdowns, other-workspaces composer, activity timeline, collapsible CLI
  reference, and About row. Rich status-card tooltip on the status bar.

## 0.6.0

- **Full schedule composer.** Pick any project (not just the open one), the
  session to continue, a custom resume prompt, and the time/tier from one
  composer. The activity-bar icon opens the full-page dashboard.

## 0.5.0

- **True session resume.** Resumes continue the interrupted conversation
  (`claude --resume <session-id>`), not a fresh chat. The newest session is
  pinned automatically; one-click session plates let you pick another.
