---
description: Schedule an auto-resume for this workspace (use after a limit hit; no args = auto-detect the reset)
argument-hint: "[when: auto | 20:00 | 2h30m | ISO-8601 | now] [critical|normal|low]"
allowed-tools: Bash
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-resume-at.sh" $ARGUMENTS`

## Your task

Relay the result above to the user. If a resume was scheduled, confirm the
resume time and importance tier, and remind them that /task-cancel stops it
and /task-status shows progress. If the time could not be parsed, show the
accepted formats. Do not modify any files.
