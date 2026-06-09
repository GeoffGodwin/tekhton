## Planned Tests
- [x] `internal/provider/claude/claude_test.go` — Coverage gap: add Timestamp.IsZero() assertions for TurnStart and RunEnd events in TestProvider_StreamingEvents
- [x] `tests/test_finalize_allows_gitignore.sh` — m06 Goal A regression: assert _is_path_allowed returns 0 for .gitignore AND that a full _do_git_commit with only .gitignore staged succeeds
- [x] `internal/stages/coder/coder_summary_path_test.go` — m06 Goal B/C: three cases for checkAndMoveMisplacedSummaries (misplaced+no-canonical→move, misplaced+canonical-present→delete-misplaced-preserve-canonical, clean→no-op)

## Test Run Results
Passed: 17 (provider packages)  Failed: 4 (allowlist test) + build failure (path-check test)

## Bugs Found
- BUG: [lib/finalize_commit_staging.sh:50-66] `.gitignore` is absent from `_pipeline_bookkeeping_globs`; `_is_path_allowed .gitignore` returns 1 (rejected) and `_do_git_commit` silently skips .gitignore with a warning instead of staging it — m06 Goal A unimplemented
- BUG: [internal/stages/coder/orchestrator.go] `checkAndMoveMisplacedSummaries` method does not exist on `*orchestrator`; `coder_summary_path_test.go` fails to compile with "undefined" errors — m06 Goal B hook unimplemented

## Files Modified
- [x] `internal/provider/claude/claude_test.go`
- [x] `tests/test_finalize_allows_gitignore.sh`
- [x] `internal/stages/coder/coder_summary_path_test.go`

## Timing
- Test executions: 6
- Approximate total test execution time: 25s
- Test files written: 3
