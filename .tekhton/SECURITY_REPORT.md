## Summary
This change adds `# shellcheck disable=SC1091` comment directives to two test/script files (`tests/test_detect_parity.sh` and `scripts/capture-detect-baselines.sh`) and adds a milestone structure validation test (`tests/test_m33_milestone_structure.sh`). All changes are either pure comments or test scaffolding that operates entirely on fixture and binary output data with no user-controlled input. No authentication, cryptography, network communication, or credential handling is involved. Security posture is unchanged; the changes introduce no new attack surface.

## Findings
- [LOW] [category:A06] [tests/test_detect_parity.sh:67-83] fixable:yes — Temp file `$actual` created by `mktemp` in `_scenario()` is cleaned up on the error path (line 73) but not on the success path after `parity_assert_equal` returns. `$expected_extracted` is correctly cleaned up (line 83), but `$actual` is leaked. Pre-existing issue not introduced by this change; data is non-sensitive (detect report output). Fix: add `rm -f -- "$actual"` before the function returns on the success path.

## Verdict
FINDINGS_PRESENT
