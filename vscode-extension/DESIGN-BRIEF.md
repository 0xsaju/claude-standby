# Design Brief — Claude Auto-Resume Dashboard (VS Code webview)

Paste this whole document into your design tool. The deliverable it should
produce is described at the end.

## 1. Product context

**claude-auto-resume** rescues developers whose long AI-coding tasks
(Claude Code) die when they hit a usage limit. The tool detects when the
limit lifts and resumes the task automatically. The dashboard is its
control room inside VS Code: at a glance — *what is my task doing, when
will it resume, is the system healthy* — plus one-click schedule/cancel.

Personality: **calm, dependable night-shift operator.** The user is often
frustrated (their work just got interrupted); the dashboard should feel
like "handled — go do something else." Not playful, not enterprise-cold.
Think Linear / Raycast / Vercel dashboard quality.

## 2. Where it renders (hard constraints)

- A **VS Code webview**, two containers with the SAME content, responsive:
  - **Sidebar view**: 260–420 px wide, full height.
  - **Editor-tab panel**: 700–1400 px wide.
- **Must inherit the user's VS Code theme.** All neutral colors MUST be
  CSS variables (list in §7); the design must work in light AND dark.
- **CSP: no external anything.** No web fonts, no images/CDNs, no
  frameworks. System/editor font stack (`var(--vscode-font-family)`),
  inline SVG only, plain CSS (+ small vanilla JS for behavior).
- Single scrollable column. No horizontal scroll ever.

## 3. Data available (all live-updating)

Per task (one per workspace directory):

| Field | Values / example |
|---|---|
| `status` | waiting · resuming · running · limit-hit · done · failed · cancelled |
| `session_id` | which Claude Code conversation the resume continues (`claude --resume <id>`); empty = a NEW chat will start — that's a warning state |
| `importance` | critical (auto-resume) · normal (60 s grace) · low (notify only) |
| `resume_at` | ISO timestamp — the moment of the next action |
| `resume_mode` | `at` (exact time) or `auto` (probing until limit lifts) |
| `resume_count` / `max_resumes` | e.g. 1 / 3 attempts used |
| `original_prompt` | free text, may be long or empty |
| `journal[]` | events: scheduled, limit-hit, limit-lifted, reset-detected, resumed, resume-failed, done, failed, cancelled, task-started — each with timestamp + detail text |

Global: current workspace path · other workspaces' tasks · health
(CLI installed? hooks registered [via settings or plugin]? N daemons
running?) · tool version · **recent sessions** of the current workspace
(up to 6): id, first-prompt summary, relative age, size — the pool the
user picks from when scheduling.

## 4. Information architecture (keep this hierarchy)

1. **Header** — identity + system health + refresh. Small. Never competes
   with the hero.
2. **Hero: the current workspace's task.** The single most important
   element on the page is the **live countdown** to the next action
   ("resumes in 2h 14m 09s"). Second: status. Third: schedule/cancel
   actions. Also shows: tier, auto-detect badge, attempts-used meter,
   task description.
3. **Schedule composer** — TWO decisions, in this order:
   a. **Which conversation to continue** — "session plates": selectable
      cards for the workspace's recent Claude sessions (first-prompt
      summary, short id, relative age, size) plus a "New chat" plate.
      Newest is preselected. This is the product's core promise — the
      user's interrupted conversation survives — so it deserves visual
      weight.
   b. **When** — presets (Auto-detect · 30m · 1h · 2h30m · Now), custom
      time input (`20:00`, `45m`, ISO), tier select, confirm.
   Should feel like one gesture, not a form. May be inline-expanding, a
   sheet, or always-visible in the empty state — designer's choice.
   The hero also shows which session is currently pinned ("continues
   '<summary>'"); a task with NO pinned session shows a gentle warning
   ("resume would start a new chat").
4. **Other workspaces** — compact cards/rows; status dot, name, next
   event, schedule/cancel. Secondary citizens.
5. **Activity timeline** — the journal, newest first, icons per event
   type. Should read like a story of what the tool did overnight.
6. **Footer** — Log · Config · GitHub · (sidebar only: "Open full view").

## 5. States to design (all of them matter)

- **Waiting (scheduled time)** — the hero moment: big countdown.
- **Waiting (auto-detect)** — countdown to *next probe* + "auto-detect"
  badge; copy must convey "it's hunting for the reset by itself".
- **Resuming** — session actively running; animated/pulsing indicator.
- **Done / Failed / Cancelled** — terminal states; Failed needs a clear
  "what now" (reschedule CTA); Done should feel like a win.
- **Limit-hit (low tier)** — reset arrived, waiting for the human.
- **Empty (no task in this workspace)** — the onboarding moment. Explain
  the product in one line, offer the composer immediately.
- **No folder open.**
- **CLI missing** — install call-to-action card (button runs installer in
  a terminal).
- Health chip degraded states: hooks not set up · no daemon running.

## 6. Interactions

- Countdown ticks every second (tabular numerals — no layout shift).
- Page data refreshes automatically (~5 s); a manual refresh affordance
  exists but should be quiet.
- Schedule: preset chip = one click done. Custom = type + confirm + tier.
- Cancel: destructive — needs visual weight/confirmation affordance, it
  kills a running resume.
- Hover states on cards/buttons; focus-visible for keyboard users.
- Timeline rows are read-only.

## 7. Visual tokens

Brand accent (fixed, not themed): **amber `#F59E0B`** — the logo is a
circular resume-arrow in this amber on dark navy `#0B1220`. Use amber
sparingly: brand mark, primary emphasis, meter fill. It must survive both
light and dark themes.

Status color mapping (use these VS Code chart variables so themes adapt):
waiting `--vscode-charts-yellow` · resuming/running `--vscode-charts-blue`
· done `--vscode-charts-green` · failed `--vscode-charts-red` · limit-hit
`--vscode-charts-orange` · cancelled `--vscode-descriptionForeground`.

Neutrals (backgrounds, text, borders, inputs, buttons) — use these vars:
`--vscode-editor-background`, `--vscode-foreground`,
`--vscode-descriptionForeground`, `--vscode-editorWidget-background`,
`--vscode-widget-border`, `--vscode-input-background`,
`--vscode-input-foreground`, `--vscode-input-border`,
`--vscode-button-background`, `--vscode-button-foreground`,
`--vscode-button-secondaryBackground`,
`--vscode-button-secondaryForeground`, `--vscode-textLink-foreground`,
`--vscode-badge-background`, `--vscode-badge-foreground`,
`--vscode-font-family`.

## 8. Deliverable

A single self-contained **HTML file** (inline CSS + minimal vanilla JS for
the countdown and composer toggling), using the variables from §7 for all
neutrals, with:

1. The full-width (editor tab) layout, and the same DOM collapsing
   gracefully at ≤420 px (sidebar) via media queries.
2. Every state from §5 represented (multiple hero variants can be stacked
   in the mock, or toggled with a small state switcher).
3. Realistic sample data (workspace `~/projects/my-app`, countdown
   `2h 14m 09s`, journal of 6–8 events).

No React, no Tailwind, no external assets — it will be dropped into a VS
Code webview nearly verbatim.
