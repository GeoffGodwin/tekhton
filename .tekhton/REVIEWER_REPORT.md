# Reviewer Report — m31.1 Build + Completion Gates

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `run_build_gate()` and `run_completion_gate()` in `tekhton-legacy.sh:902-918` return 0 when the tekhton binary is missing. The milestone Watch For explicitly specified exit 127 ("fail-safe — binary missing = gate fail"). Returning 0 silently passes the gate when the binary is absent. In all production deployments the binary exists, so the risk is low; but a developer who forgets `make build` will see broken code advance through a gate that never ran. Consider changing both `return 0` to `return 127`.
- `completionGateFromEnv()` in `cmd/tekhton/gate.go:181-200` leaves `Baseline` (BaselineComparator), `Dedup` (TestDedup), and `Substantive` (SubstantiveProbe) nil. Goal 3 explicitly named M92 baseline comparison, M63 test-dedup fast-path, and M86 substantive-work detection as in-scope for m31.1. The Go interfaces and logic are correct when wired (proven by `TestCompletionGate_PreExistingFailureAccepted`, `TestCompletionGate_DedupSkipsTestCmd`, `TestCompletionGate_SubstantiveNoStatusFallsToInProgress`), but the CLI assembler never wires them. Impact: (a) M92 — pre-existing failures aren't identified as pre-existing, so when `TEST_BASELINE_PASS_ON_PREEXISTING=true` the gate fails where the bash side passed; (b) M105 — TEST_CMD always runs even on identical working trees (performance, not correctness); (c) M86 — no-status always routes to ErrCompletionNoStatus rather than ErrCompletionSubstantiveNoStatus. Concrete `BaselineComparator`/`TestDedup`/`SubstantiveProbe` implementations should be wired in a follow-up.
- `FailingExitCoder` in `completion.go:299-319` is defined but unused — the CLI assembler uses `errExitCode` (from the existing cmd/tekhton package) instead. Remove it or document its intended consumer to avoid dead code confusion.
- The `gate_timeout` parity scenario in `test_gates_parity.sh:180-182` exercises a real wall-clock race: `ANALYZE_CMD="sleep 5"` with `BUILD_GATE_TIMEOUT=1` and `BUILD_GATE_ANALYZE_TIMEOUT=10`. On high-load CI hosts, process startup overhead can push the deadline check timing; a mock-clock approach (as used in `TestBuildGate_Run_TimeoutWritesSyntheticReport`) would make this deterministic.

## Coverage Gaps
- No parity test exercises M92 baseline comparison: the completion gate accepting pre-existing failures when `TEST_BASELINE_PASS_ON_PREEXISTING=true` (also covers the missing `Baseline` wiring noted above).
- No parity test exercises M105 test-dedup fast-path: the completion gate skipping TEST_CMD when the working-tree fingerprint matches.
- No parity test exercises M86: completion gate routing to ErrCompletionSubstantiveNoStatus for a summary file with no Status field but substantive git changes.

## ACP Verdicts
- ACP: `internal/gates/` as sibling package to `internal/pipeline/` — ACCEPT — The distinction is valid and correctly described. `internal/gates/` owns the full bash-equivalent gate with phase boundaries, M54 remediation re-runs, and raw-stream output files; `internal/pipeline/gates.go` owns the lightweight in-process scheduler gate. Two different concerns at two different seams. ARCHITECTURE.md is updated and clearly documents both.

## Drift Observations
- `completion.go:299-319` — `FailingExitCoder` and `errExitCode` (defined elsewhere in `cmd/tekhton/`) both implement an exit-code wrapper pattern. Two types for the same purpose in the same package tree is fragile; when `FailingExitCoder` is removed the duplication is gone, but if it's wired in the future it should replace (not supplement) `errExitCode` at the CLI seam.
- `gate_ui_shim.go:44` — `Run(ctx, stageLabel, _ map[string]string)` ignores the `env map[string]string` argument. `UIBashShim.ShellEnv` carries env overrides (`UI_TEST_CMD`, `UI_GATE_ENV_RETRY_ENABLED`, etc.) populated at construction time but the shim discards them and builds the subprocess env entirely from `os.Environ()`. Document the drop as intentional for m31.1 or thread `ShellEnv` through to `c.Env` to avoid silent override loss when the assembler later populates those fields.
- `remediation.go:68` — `envPlus` appends `TEKHTON_HOME`, `ERRORS_STREAM`, and `PHASE_LABEL` to `os.Environ()` without deduplication. On Linux, `getenv()` returns the first match, so if `TEKHTON_HOME` is already exported by the caller (the common case), the appended value is harmlessly redundant rather than an override. A comment clarifying this would prevent future confusion about intent.
