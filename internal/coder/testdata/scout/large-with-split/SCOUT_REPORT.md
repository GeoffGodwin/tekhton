# Scout Report

## Files Located
- 12 files touched across the supervisor, the orchestrator, the build gate, the
  prerun sub-stage, and the test_audit runner. Each file requires a coordinated
  change to the proto envelope plus a parity test update.

## Affected Test Files
- internal/orchestrate/orchestrate_test.go
- internal/supervisor/supervisor_test.go
- internal/gates/build_test.go
- tests/test_*.sh (many)

## Complexity Estimate

- **Files to modify:** 12
- **Estimated lines of change:** 800
- **Interconnected systems:** high
- **Recommended coder turns:** 100
- **Recommended reviewer turns:** 18
- **Recommended tester turns:** 70
