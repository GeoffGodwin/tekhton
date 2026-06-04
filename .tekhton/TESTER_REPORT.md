## Planned Tests
- [x] `tests/test_version_bump_coverage.sh` — catch-all JSON bump + HUMAN_ACTION fallback paths (two reviewer coverage gaps)

## Test Run Results
Passed: 8  Failed: 1

## Bugs Found
- BUG: [lib/project_version.sh:82] `_accessor_for_file` returns `"plaintext"` for any filename not in its explicit list, including `.json`-suffixed files (e.g. `widget-manifest.json`). `verify_version_files_synced` uses this accessor to read the version back, so `_detect_version_from_file` with the `plaintext` path does `tr -d '[:space:]'` on the whole JSON file and compares the resulting blob to the target version — they never match, causing a false `version_files_desynced_*` commit-gate trip for any manually declared non-conventional JSON version file. The `_bump_single_file` catch-all correctly bumps such files (PASS); only the round-trip verify is broken (FAIL). Fix: change the `*` case in `_accessor_for_file` to return `json` for `.json`-suffixed filenames.

## Files Modified
- [x] `tests/test_version_bump_coverage.sh`
