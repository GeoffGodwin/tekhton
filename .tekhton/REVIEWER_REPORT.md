# Reviewer Report — m05 Supervisor Scaffold + Agent JSON Contract

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `cmd/tekhton/supervise.go:51-53` + `internal/supervisor/supervisor.go:62`: validation runs twice — `req.Validate()` is called explicitly in `RunE` before passing to `sup.Run`, and `Run` calls `req.Validate()` again internally. The redundancy is harmless and intentionally defensive (any future in-process caller that bypasses the CLI layer still gets enforcement), but lines 51-53 in supervise.go can never observe a different result from `Run`'s internal check given the current flow. Worth noting for m06 when `Run` grows more validation.
- `cmd/tekhton/readSuperviseRequest`: I/O failures (file-not-found, unreadable stdin) are wrapped as `proto.ErrInvalidRequest`, causing `exitUsage` (64). Semantically, an OS I/O error is not a usage error — consider `exitSoftware` (70) for the `os.ReadFile` and `io.ReadAll` error paths, reserving `exitUsage` for parse and validation failures. Low-priority polish for m06 when the distinction matters to callers.

## Coverage Gaps
- None

## Drift Observations
- `cmd/tekhton/state.go:149` defines `errExitCode`; exit-code constants (`exitUsage`, `exitSoftware`) live in `supervise.go`. As the package accumulates subcommands these shared CLI primitives will scatter across files. Consider extracting them to `cmd/tekhton/errors.go` before the list grows further.
- `internal/supervisor/supervisor.go:47`: `ErrNotImplemented` is declared but no code path currently returns it. It is a valid forward-planning placeholder for m06 stub sites, but if m06 doesn't use it the variable should be removed then to avoid confusion.
