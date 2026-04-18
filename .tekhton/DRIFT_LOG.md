# Drift Log

## Metadata
- Last audit: 2026-04-17
- Runs since audit: 3

## Unresolved Observations
- [2026-04-17 | "M97"] `tui_helpers.sh:_tui_json_build_status` — the `"stage"` field (line 122) duplicates `"stage_label"` (line 125), both set to `$stage_label`. The test fixture in `tools/tests/test_tui.py` uses distinct values (`stage="coder"`, `stage_label="Coder"`), implying the schema intended them to differ. Worth resolving when the JSON schema is next touched.

## Resolved
