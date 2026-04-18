# Drift Log

## Metadata
- Last audit: 2026-04-18
- Runs since audit: 1

## Unresolved Observations
- [2026-04-18 | "architect audit"] **OBS-1: `lib/common.sh:110` — "No blank line between `error()` close and `mode_info()` comment block"** Verified stale. Current `lib/common.sh` line 110 is a blank line separating `error()` (closes at line 109) from `mode_info()` (opens at line 111). The `mode_info()` function also has no comment block — it begins directly with `mode_info() {`. The stated condition does not exist in the codebase. No action required. **OBS-2: `lib/tui_helpers.sh:_tui_json_build_status` — `"stage"` field duplicates `"stage_label"`** Verified stale. Current `_tui_json_build_status` (lines 115–139) emits `"stage_num"`, `"stage_total"`, and `"stage_label"` but no `"stage"` field. The test fixture `_sample_status()` in `tools/tests/test_tui.py` (lines 27–56) likewise has no `"stage"` key. The duplication referenced in the observation does not exist. No action required.

## Resolved
- [RESOLVED 2026-04-18] `lib/common.sh:110` — No blank line between the closing `}` of `error()` and the start of `mode_info()`'s comment block; all other function transitions in this file have a blank line separator. Minor inconsistency.
- [RESOLVED 2026-04-18] `tui_helpers.sh:_tui_json_build_status` — the `"stage"` field (line 122) duplicates `"stage_label"` (line 125), both set to `$stage_label`. The test fixture in `tools/tests/test_tui.py` uses distinct values (`stage="coder"`, `stage_label="Coder"`), implying the schema intended them to differ. Worth resolving when the JSON schema is next touched.
