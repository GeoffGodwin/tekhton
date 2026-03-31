# Reviewer Report — M42: Tag-Specialized Execution (Cycle 1)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/notes_acceptance.sh:259-264` — `local _code` and `local _msg` declared inside `while` loop body. `local` is function-scoped in bash so this is valid, but placing declarations inside a loop is unconventional. Move declarations before the loop.
- `lib/dashboard_emitters.sh:625-637` — `reviewer_skipped` per-note metadata is extracted from note HTML comments, but `_store_acceptance_result` only writes the `acceptance` key. Nothing in M42 writes `reviewer_skipped` to note metadata, so this dashboard field will always be empty string. The run-level `REVIEWER_SKIPPED` env var is correctly captured in metrics.jsonl; only the per-note dashboard display is missing this signal.
- `lib/notes_acceptance.sh:95-111` — `check_feat_acceptance()` uses `grep -qF "$_dir"` to check directory presence. `-F` matches as a substring, so `_dir="cli"` would match a line `"src/cli"` in `_common_dirs` (false negative). Rare edge case.
- `lib/notes_acceptance.sh:60-65` — `_new_files` concatenation from `git ls-files --others` and `git diff --cached --name-only --diff-filter=A` can produce duplicates. A `sort -u` before the while loop would prevent duplicate warnings.

## Coverage Gaps
- `tests/test_notes_acceptance.sh` has no tests for tag-specific scout decision logic (SCOUT_ON_BUG/FEAT/POLISH config paths) or turn budget multiplier calculations — both are `stages/coder.sh` changes.
- `tests/test_notes_acceptance.sh` has no test for NOTE_TEMPLATE_NAME fallback when the tag-specific template file is absent.

## Drift Observations
- `stages/coder.sh:115` and `stages/coder.sh:527` — both independently use `grep -oP 'est_turns:\K[0-9]+'` to read triage metadata from HUMAN_NOTES.md. M41 introduced this pattern; M42 duplicates it. A `_read_note_metadata_field()` helper in `lib/notes_core.sh` would centralize this.
