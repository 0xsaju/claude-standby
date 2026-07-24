# Changelog

All notable changes to the Claude Standby Cockpit extension. The
extension is a thin UI over the `claude-standby` terminal tool, so some
entries describe tool behavior the cockpit now surfaces.

## Unreleased

- **Audit remediation (2026-07-24, D46).** A 36-finding independent audit
  landed a batch of engine/cockpit hardening fixes — see `docs/DECISIONS.md`
  D46 for the full list (session-resolution fail-closed, reschedule
  preemption, numeric safety-rail validation, statusline sensor no-clobber,
  webview escaping, terminal-argument quoting, and more). `package.json`
  stays at `0.9.4` pending a release version bump; **the checked-in
  `claude-standby-cockpit-0.9.4.vsix` predates this batch and must be
  rebuilt from the current source tree before the next publish** (F31) —
  do not ship the stale artifact.

## 0.9.4

- **See the resume run.** A running resume now shows a **live output panel**
  in the dashboard (streamed from the headless run) plus a **▶ Open in Claude
  Code** button that continues the very same conversation in a terminal — so a
  long background resume is no longer invisible. (Requires CLI 0.9.4.) Output is
  plain by default; set `AR_CFG_RESUME_STREAM=1` for a richer per-step
  (stream-json) live view.
- **Header alert marker.** A prominent red/amber pill in the top corner when
  something needs attention: CLI missing, state file broken, a resume
  interrupted, a CLI update available, or exact-reset detection not set up.
- **Grace countdown is honest.** During the normal-tier grace window the
  dashboard shows the actual "resumes at HH:MM," not a time that already passed.
- **Fixed: composer reset while typing.** Entering a custom prompt / session /
  time no longer gets wiped when the 5-second auto-refresh fires — refreshes
  pause while you're editing.
- **Pre-publish hardening (audit).** Fixed a live-panel crash on odd output, a
  live panel that froze past ~8 KB, and an installer path that could enable the
  status-line sensor without consent; the resume's live output is now **plain by
  default** (stream-json is opt-in) so limit detection stays on a verified
  format. See `docs/audit-0.9.4.md`.
- The extension version now tracks the CLI version (both `0.9.4`); they move
  together from here on. (0.9.3 was skipped to realign.)

## 0.9.2

- **Setup can enable the status-line sensor.** The Setup checklist gains a
  "Status-line sensor — exact reset times" row with a one-click **Enable**
  (runs `claude-standby setup-statusline`); shown as a neutral optional
  step, never a red failure. The CLI installer now offers the same thing
  at install time.
- **"At reset" is now always visible.** Without the status-line sensor the
  chip used to be hidden entirely, so most users never learned it existed.
  It now shows disabled with a tooltip explaining that Setup's status-line
  sensor unlocks it (the sensor is what captures your exact reset time
  locally); the Auto-detect hint says the same.
- (tool side) **Resumes that run into the next limit window now wait for
  it.** When a resumed session hits a limit again and the message announces
  the reset time, the daemon reschedules to exactly that time instead of
  retrying on a short backoff — previously the remaining attempts fired
  into the still-active limit and burned the max-resumes cap for nothing.

## 0.9.1

- **One-click CLI update.** The cockpit notices when a newer `claude-standby`
  release is out and offers to run the update for you.

## 0.9.0

- **Renamed to Claude Standby.** The project was `claude-auto-resume`, which
  collided with an unrelated same-named shell tool. New extension id
  `claude-standby-cockpit`; the terminal tool is now `claude-standby`
  (alias `cs`). If you had the old `claude-auto-resume-cockpit` extension,
  uninstall it and install this one. No change to how the cockpit works.
- **Git-free self-updates** (tool side): `claude-standby update` downloads
  and swaps a validated copy instead of `git pull`, so a bad download never
  leaves a broken install.

## 0.8.9

- **Simpler default resume prompt.** Now "Limit reset. Continue from where
  you stopped." — the PROGRESS.md mention was our own project convention,
  not something most workspaces have; resumed sessions already carry their
  full conversation context via `--resume`. (Matches the CLI default.)
- Marketplace listing now shows dashboard screenshots.

## 0.8.8

- **"At reset" scheduling in the composer.** When your reset time is known
  locally, the When picker offers **At reset** (selected by default) — "you hit
  a limit → resume at your exact 5-hour reset," with no probing and no usage
  guess. **Auto-detect** remains for arming in advance (watch and resume
  whenever a limit hits). Each mode shows its own one-line hint. Matches the
  CLI's `resume-at reset`. The tier picker now says the `normal` grace is 5 min.
- The reset-time reader now honors `CLAUDE_STANDBY_RATE_FILE` and
  `AR_CFG_RATE_SOURCE` (matching the CLI), so "At reset" and the CLI never
  disagree about whether a reset time exists.

## 0.8.7

- **Exact reset time.** When your live usage data is available locally
  (streamed to Claude Code's status line, or an existing cache), the
  dashboard and status bar show the real reset moment and usage
  (`resets 6:00 PM · 54% used`) and auto-detect schedules to it — no polling,
  no quota. Zero setup when a cache exists; otherwise
  `claude-standby setup-statusline` adds a small sensor.
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
