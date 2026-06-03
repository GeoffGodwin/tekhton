## Planned Tests
- [x] `internal/stages/staglog/staglog_test.go` — New() constructor: env-based pos/count, req.EnvOverrides priority, nil req defaults, nil writer
- [x] `internal/stages/docs/stage_test.go` — resolveProjectDir/resolvePromptsDir env fallbacks; envBool unknown-value branch; envInt zero branch
- [x] `internal/stages/docs/skip_test.go` — changedFiles git-error path; extractPublicSurface empty-rulesFile default; filesMatchSurface globToRegexp compile-error defensive continue

## Test Run Results
Passed: 501 shell + all 29 Go packages  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/stages/staglog/staglog_test.go`
- [x] `internal/stages/docs/stage_test.go`
- [x] `internal/stages/docs/skip_test.go`
