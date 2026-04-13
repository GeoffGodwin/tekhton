# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in ${REVIEWER_REPORT_FILE}.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [x] [2026-04-12 | "M75"] `stages/docs.sh:94` — Fallback path expression `${TEKHTON_DIR:-}.tekhton/DOCS_AGENT_REPORT.md` is malformed: when `TEKHTON_DIR=.tekhton` (the config default), this evaluates to `.tekhton.tekhton/DOCS_AGENT_REPORT.md`. Correct form is `${TEKHTON_DIR:-.tekhton}/DOCS_AGENT_REPORT.md`. Functionally harmless — `config_defaults.sh` always pre-sets `DOCS_AGENT_REPORT_FILE` before the stage runs, making this fallback dead code in practice.
- [ ] [2026-04-12 | "M75"] `lib/docs_agent.sh:76-79` / `stages/docs.sh:86-89` — The `sed` range expression extracting the Documentation Responsibilities section is duplicated verbatim in both files. Minor duplication; consider extracting to a shared helper when a third caller appears.
- [x] [2026-04-12 | "M75"] CLAUDE.md Template Variables table is missing three prompt variables injected by `_docs_prepare_template_vars()`: `CODER_SUMMARY_CONTENT`, `DOCS_GIT_DIFF_STAT`, and `DOCS_SURFACE_SECTION`. All three appear in `prompts/docs_agent.prompt.md` with `{{VAR}}` substitution. Precedent in this project (e.g. `UI_CODER_GUIDANCE`, `INTAKE_HISTORY_BLOCK`) is to document computed/injected template vars in the table.
<!-- Items added here by the pipeline. Mark [x] when addressed. -->

## Resolved
