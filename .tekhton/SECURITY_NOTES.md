# Security Notes

Generated: 2026-04-14 01:58:59

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A03] [lib/milestone_progress.sh:159-165] fixable:yes — `_diagnose_recovery_command` embeds `$milestone` and `$task` read verbatim from `PIPELINE_STATE.md` into a quoted command string (`"${milestone}"`, `"${task}"`). If either field contains a double-quote character the displayed suggestion is syntactically broken. Since the output is only echoed (never `eval`'d) there is no injection risk, but the suggested command will be unusable. Fix: strip or escape embedded double-quotes before interpolation: `milestone="${milestone//\"/\\\"}"` and `task="${task//\"/\\\"}"`.
