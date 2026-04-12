## Planned Tests
- [x] `tests/test_install_bash_version_check.sh` — Verify bash version guard exits cleanly with correct messages

## Test Run Results
Passed: 12  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_install_bash_version_check.sh`

## Test Summary

Comprehensive test coverage for the bash version check fix in install.sh (lines 122-141). The test verifies:

1. **Function structure**: `check_bash_version()` exists and uses `BASH_VERSINFO[0]` to extract major version
2. **Guard logic**: Version check correctly identifies bash < 4 as requiring upgrade
3. **Platform branching**: Separate code paths for macOS (Homebrew instructions) vs other platforms
4. **Error messaging**: 
   - Version requirement states "bash 4.3+" (not generic "4+")
   - macOS path includes Homebrew install instructions (`brew install bash`)
   - Non-macOS path shows generic upgrade message
5. **Function calls**: Replaced undefined `error()` with defined `fail()` function
6. **Output correctness**: Error messages sent to stderr via `fail()` function
7. **Code quality**: No dead/unreachable code (removed unreachable `exit 1`)

All 12 tests pass, confirming the implementation correctly promotes the version warning to a hard exit with helpful instructions.
