# Security Notes

Generated: 2026-05-30 10:16:02

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A06] [tests/test_detect_parity.sh:67-83] fixable:yes — Temp file `$actual` created by `mktemp` in `_scenario()` is cleaned up on the error path (line 73) but not on the success path after `parity_assert_equal` returns. `$expected_extracted` is correctly cleaned up (line 83), but `$actual` is leaked. Pre-existing issue not introduced by this change; data is non-sensitive (detect report output). Fix: add `rm -f -- "$actual"` before the function returns on the success path.
