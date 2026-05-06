# Reviewer Report — m07 Retry Envelope: Typed Errors + Exponential Backoff

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `retry.go:195` — `return lastResult, nil` at the bottom of `retryLoop` is dead for any positive `MaxAttempts` (every loop iteration returns). The only reachable path is `MaxAttempts <= 0`, where the loop body never executes and the function returns `(nil, nil)`. A caller receiving `(nil, nil)` has no clean way to distinguish "succeeded with nil result" from "policy was degenerate". Consider an early guard: `if p.MaxAttempts <= 0 { return nil, fmt.Errorf("supervisor: MaxAttempts must be > 0") }`.
- `retry.go:57-58` — `if p.BaseDelay <= 0 { return 0 }` silently converts a degenerate policy into a zero-delay retry loop. This is undocumented; a comment or the same guard pattern as MaxAttempts would make intent explicit to future readers.

## Coverage Gaps
- `classifyResult` — the `proto.OutcomeTransientError` fallback branch (`errors.go:127`) has no dedicated test. The tests exercise the ErrorCategory/ErrorSubcategory populated path and the `OutcomeActivityTimeout` / `OutcomeFatalError` fallbacks but not this specific outcome. Low risk (same structure as the activity_timeout path), but the branch could be dropped or mutated without a test catching it.

## Drift Observations
- None

---

### Review notes (not parsed by pipeline)

All four files are clean on the architecture checklist. Highlights:

**errors.go** — `Is()` correctly uses `errors.As` (not pointer equality) so sentinel matches work even when `target` is a newly allocated `*AgentError` with a different `Wrapped`. The `//nolint:gochecknoglobals` directive is appropriate and correctly scoped to the sentinel block. Wire format `CATEGORY|SUBCATEGORY|TRANSIENT|MESSAGE` matches V3 exactly; the test `TestAgentError_Error_FormatMatchesV3WireShape` validates field positions. `classifyResult` copies sentinels by value before adding `Wrapped` — correct approach since pointer identity is not used by `Is()`.

**retry.go** — `Delay()` formula matches the coder's documented spec: exponential growth with cap, floor applied after cap, jitter added, then final re-cap unless floor exceeds MaxDelay. The floor-wins edge case (`floor > MaxDelay`) is correctly implemented at line 87 and covered by `TestRetryPolicy_Delay_FloorAboveMaxDelayWins`. The `after` / `rng` clock-and-jitter seams are the right pattern — no `time.Sleep` anywhere, so cancellation and time-mocking are uniform across tests. `turn_exhausted` non-trigger is correct (orchestrate owns continuation, per design).

**V4 migration discipline** — intentional deferral of `lib/agent_retry.sh` shim flip to m10 is documented and consistent with CLAUDE.md Rule 9 phased approach. No bash dual-implementation concern here.

**Docs** — `## Docs Updated` section is present and correct; all new API surface is `internal/supervisor`, not callable outside the module.

**Test suite** — 92.2% statement coverage (AC: ≥75%). Race detector clean over 3 runs. The `test_run_op_lifecycle.sh` flake is pre-existing and unrelated to m07 changes; coder correctly documented and did not touch `lib/tui_ops.sh`.
