## Planned Tests
- [x] `internal/config/config_test.go` — AllKeys edge cases: duplicate keys, env-seeded keys, LoadDefaultsOnly with non-empty KeysSet
- [x] `internal/config/config_test.go` — findInlineComment apostrophe-before-comment edge cases
- [x] `internal/config/config_test.go` — Load value with apostrophe + inline comment, EmitShell escapes apostrophe
- [x] `internal/config/config_test.go` — EmitShell + bash eval round-trip for value with single quote and newline

## Test Run Results
Passed: 4  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/config/config_test.go`
