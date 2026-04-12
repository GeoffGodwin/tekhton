# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-12 | "M72"] `lib/prompts.sh:86-87`: The M72 path update replaced `${INTAKE_REPORT_FILE:-INTAKE_REPORT.md}` with `${INTAKE_REPORT_FILE:-${INTAKE_REPORT_FILE}}`. The self-referential fallback is logically broken — if `INTAKE_REPORT_FILE` is unset, the expression expands to empty string instead of any path. Zero practical impact (config_defaults.sh always sets this variable before prompts.sh is invoked), but the original defensive fallback was silently removed. Correct to `"${INTAKE_REPORT_FILE}"` (no fallback needed) or `"${INTAKE_REPORT_FILE:-${TEKHTON_DIR}/INTAKE_REPORT.md}"`.
- [ ] [2026-04-12 | "M72"] `tekhton.sh:35,22,25` (header block): The script docstring comments use `.tekhton/${DESIGN_FILE}` and `.tekhton/${HUMAN_NOTES_FILE}` patterns. At runtime these expand to `.tekhton/.tekhton/DESIGN.md` and `.tekhton/.tekhton/HUMAN_NOTES.md` (double-prefix). The actual code uses `${DESIGN_FILE}` and `${HUMAN_NOTES_FILE}` correctly — only the comments are wrong.
- [ ] [2026-04-12 | "M72"] `tekhton.sh:1163`: Dead code in the `--init-notes` handler — `: "${HUMAN_NOTES_FILE:=${TEKHTON_DIR}/${HUMAN_NOTES_FILE}}"`. Since `--init-notes` is processed in the main arg loop after `load_config` (line 854), `HUMAN_NOTES_FILE` is already set to `.tekhton/HUMAN_NOTES.md`. The `:=` is always a no-op. Remove the line.
- [ ] [2026-04-12 | "M72"] `.claude/milestones/MANIFEST.cfg`: M72 row has `status=in_progress` rather than the `status=done` required by the M72 acceptance criteria. The acceptance criteria explicitly specifies the row should be added with `status=done` when implementation is complete.
- [ ] [2026-04-12 | "M72"] `lib/prompts.sh:87-88` — `${INTAKE_REPORT_FILE:-${INTAKE_REPORT_FILE}}` is a self-referential fallback; harmless in practice since INTAKE_REPORT_FILE is always set before `load_intake_template_vars()` is called, but the logic is wrong. Should be `${INTAKE_REPORT_FILE:-${TEKHTON_DIR}/INTAKE_REPORT.md}`.
- [ ] [2026-04-12 | "M72"] `tekhton.sh:1163` — `--init-notes` handler contains `: "${HUMAN_NOTES_FILE:=${TEKHTON_DIR}/${HUMAN_NOTES_FILE}}"` which is a dead no-op (HUMAN_NOTES_FILE is already set by config_defaults.sh by this point) with wrong logic in the fallback. Should be `: "${HUMAN_NOTES_FILE:=${TEKHTON_DIR}/HUMAN_NOTES.md}"` but it is never evaluated in practice.
- [ ] [2026-04-12 | "M72"] `migrations/003_to_031.sh` — `migration_check()` uses TEKHTON_DIR presence in pipeline.conf + .tekhton/ dir existence as the idempotency signal rather than the TEKHTON_CONFIG_VERSION watermark specified in the milestone design. The `[[ -e "$dst" ]] && continue` guard makes repeated application safe, but the migration does not write a `TEKHTON_CONFIG_VERSION=3.1` watermark after applying (specified as the prevention mechanism).
- [ ] [2026-04-12 | "M72"] `lib/config_defaults.sh` — 520 lines, well above the 300-line ceiling. Pre-existing violation flagged in M72 spec as out-of-scope; noting for the cleanup queue.
- [ ] [2026-04-09 | "Resolve all 3 unresolved architectural drift observations in DRIFT_LOG.md."] `lib/health.sh` is 442 lines, exceeding the 300-line soft ceiling (pre-existing, not introduced by this change). Flag for a future extraction pass.

## Resolved
