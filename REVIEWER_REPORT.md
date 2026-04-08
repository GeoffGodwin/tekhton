## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/plan_answers.sh` is 515 lines, well over the 300-line soft ceiling. Pre-existing condition worsened by +26 lines for the new helpers. Consider splitting `_yaml_escape_dq`/`_yaml_unescape_dq` and related helpers into a `plan_answers_helpers.sh` in a future cleanup pass.
- In `export_question_template`, `s_guide` is written as a YAML comment (`# Guidance: ${s_guide}`) without HTML or YAML escaping. If guidance text contains a newline it would break the comment line, though this hasn't occurred in practice. Informational only.

## Coverage Gaps
- None

## Drift Observations
- None

---

## Review Notes

The change is correct and complete for the stated bug. Trace through the fix:

1. **Write path fixed** — `init_answer_file()` now calls `_yaml_escape_dq` on both `s_name` and `s_guide` before embedding them in YAML double-quoted scalars. `save_answer()` escapes `answer_text` in the inline path (the block-scalar branch is unchanged and correct since block scalars don't require quote escaping). `export_question_template()` escapes `s_name` for the title field.

2. **Read path fixed** — `load_all_answers()` now unescapes `current_title` and `current_answer` via `_yaml_unescape_dq`. `_parse_answer_field()` unescapes inline quoted answers. The round-trip is symmetric.

3. **Helper implementation** — `_yaml_escape_dq` escapes backslash first, then double-quote (correct order). `_yaml_unescape_dq` unescapes `\"` first, then `\\` (correct order — avoids double-processing).

4. **Web mode covered** — `plan_browser.sh` delegates to `init_answer_file()` and `save_answer()` from `plan_answers.sh` (confirmed by reading its header). The fix applies to web mode without any additional changes needed.
