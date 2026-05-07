# Reviewer Report

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `cmd/tekhton/state_cmd_test.go:140-156` — `os.Stdout = w` redirect in `TestStateReadCmd_FullJSONOutput` is not parallel-safe. If `t.Parallel()` is ever added to this package, the shared `os.Stdout` swap will race. Prefer passing an `io.Writer` through a command option or a `captureOutput` helper so the test is self-contained.
- `internal/supervisor/retry_test.go:207-215` — Second assertion in `TestRetryPolicy_Delay_BaseDelayZeroReturnsZero` calls `p.Delay(5, "api_rate_limit")` but the policy has no `Floors` map, so the assertion does not actually verify that the `BaseDelay <= 0` early-return overrides a configured floor. The test passes for a different reason than its comment implies ("and floor" is misleading). Not incorrect, but worth a follow-up assertion that includes a floor.
- Security [LOW] finding flagged by the security agent for log injection via unsanitized `label` in `emitSupervisorEvent` (`internal/supervisor/run.go:237`, marked fixable:yes) was not addressed in this task. Defer is acceptable — noting for tracking.

## Coverage Gaps
- None

## Drift Observations
- None

---

### Review notes

**`internal/supervisor/retry.go`** — `MaxAttempts <= 0` guard (line 160) is correct: typed error, runner not invoked, consistent with the nil-request / nil-runner guards already present. The defensive trailing `return` at line 240 with its "unreachable" comment is the right pattern for exhausted loops and will protect against future refactors. The `BaseDelay <= 0 → return 0` early-exit (line 59) with the production-caller warning comment is appropriate.

**`internal/supervisor/retry_test.go`** — Four new tests are well-targeted. `TestRetry_MaxAttemptsZero_Errors` correctly asserts (a) typed error returned, (b) nil result, (c) zero runner calls. `TestRetryPolicy_Delay_BaseDelayNegativeReturnsZero` mirrors the zero case cleanly.

**`lib/milestone_query.sh`** — Empty-manifest early-return fix (line 44) is the correct fix. The previous `found` guard was a correctness bug; returning 0 for a valid-but-empty manifest is the right contract since callers distinguish success/failure by exit code, not output length.

**`lib/orchestrate_main.sh`** — Removing `set -euo pipefail` from a sourced file is the correct fix per CLAUDE.md Rule 2 and the reviewer role spec ("sourced files in `lib/` and `stages/` do not [have set -euo pipefail] — they inherit"). The file's shebang line is informational-only and does not change behaviour when sourced.

**`scripts/dag-parity-check.sh`** — `_require_or_skip` graceful-skip pattern mirrors the `check_indexer_available` Python-absent degradation correctly. `DAG_PARITY_REQUIRE=1` fail-fast escape hatch is well-documented in the header. `set -euo pipefail` is present because this file is a standalone entry point, not sourced — correct.

**`cmd/tekhton/state_cmd_test.go`** — Seven tests cover the three Cobra `Execute()` paths that were below the 80 % threshold. `TestStateUpdateCmd_FirstClassFields` correctly does a read-modify-write round-trip to verify first-class fields and extra-map keys. `TestStateClearCmd_AbsentFileIsNotAnError` correctly asserts idempotency. All tests use `t.TempDir()` for isolation.

**`go.mod`** — `go mod tidy` promoting `fsnotify v1.9.0` and `golang.org/x/sys v0.13.0` to direct dependencies is correct; both are used directly by supervisor package code.
