# Drift Log

## Metadata
- Last audit: 2026-04-08
- Runs since audit: 1

## Unresolved Observations
(none)

## Resolved
- [RESOLVED 2026-04-08] **Observation 1** — `lib/plan_answers_helpers.sh:126` `_generate_question_yaml()` is defined as a nested function inside `export_question_template()`. In bash, nested function definitions are not scoped: once `export_question_template()` is called for the first time, `_generate_question_yaml` becomes a global name. Prefer defining it at module level (prefixed `_`) to avoid accidental shadowing or later collision. **Fix:** Refactored to define `_generate_question_yaml()` at module level with comment documenting extraction from `export_question_template()`.
- [RESOLVED 2026-04-08] **Observation 2** — `stages/plan_interview_helpers.sh:123-138` `_read_section_answer_editor` joins multi-line editor content into a single space-separated line (lines loop → `answer+="${line} "`), while the CLI fallback in `_read_section_answer` preserves lines array then joins with `IFS=" "` `echo "${lines[*]}"`. Both flatten to a single line, but the editor path does so character-by-character with a trailing space. If multi-line YAML block scalar support in `save_answer` is ever exercised by editor input, the flattening will lose intentional line breaks. Low risk today but worth aligning with explicit documentation. **Fix:** Aligned both paths to use consistent multi-line preservation via `local IFS=$'\n'` and `echo "${lines[*]}"` pattern.
