# Reviewer Report — M103: Output Bus Tests + Integration Validation

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `test_output_tui_sync.sh:126-129` (TC-TUI-03): `stage_order` assertion uses glob substring matching (`[[ "$json" == *'"intake"'* ]]`) instead of the JSON-parsed `assert_json_field` helper used in all other assertions. Works correctly, but inconsistent with the rest of the file and could produce a false pass if "intake" appeared in a different JSON field.
- `tools/tests/test_tui_action_items.py:44`: `monkeypatch.setattr("tui_hold.time.sleep", ...)` patches by string reference, requiring `tui_hold` to already be in `sys.modules`. Works as long as `tui.py` imports `tui_hold` at module level, but the implicit dependency is fragile if that import path ever changes to lazy-loading.

## Coverage Gaps
- None

## Drift Observations
- `lib/tui_helpers.sh:_tui_escape` and the `_out_json_escape` function in `lib/output_format.sh` (flagged in M102) implement the same JSON string escaping logic independently. Now that M103 adds tests that exercise both paths, this divergence is more visible — a future bug fix to one that misses the other will produce inconsistent escaping between CLI and TUI paths. Candidate for consolidation in a cleanup pass.
