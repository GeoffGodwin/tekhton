# Drift Log

## Metadata
- Last audit: 2026-05-04
- Runs since audit: 4

## Unresolved Observations
- [2026-05-05 | "Address all 14 open non-blocking notes in .tekhton/NON_BLOCKING_LOG.md. Fix each item and note what you changed."] `.tekhton/NON_BLOCKING_LOG.md item 2` — the current open note claims "I/O failures (file-not-found, unreadable stdin) are wrapped as `proto.ErrInvalidRequest`, causing `exitUsage`." This is factually incorrect against the current code: `os.ReadFile` and `io.ReadAll` failures are returned unwrapped and correctly map to `exitSoftware`. The test `TestSuperviseCmd_RejectsMissingRequestFile` already asserts `exitSoftware`. This note should be resolved/removed rather than carried forward, as it will mislead future coders into "fixing" code that is already correct.
- [2026-05-05 | "Implement Milestone 5: Supervisor Scaffold + Agent JSON Contract"] `cmd/tekhton/state.go:149` defines `errExitCode`; exit-code constants (`exitUsage`, `exitSoftware`) live in `supervise.go`. As the package accumulates subcommands these shared CLI primitives will scatter across files. Consider extracting them to `cmd/tekhton/errors.go` before the list grows further.
- [2026-05-05 | "Implement Milestone 5: Supervisor Scaffold + Agent JSON Contract"] `internal/supervisor/supervisor.go:47`: `ErrNotImplemented` is declared but no code path currently returns it. It is a valid forward-planning placeholder for m06 stub sites, but if m06 doesn't use it the variable should be removed then to avoid confusion.
- [2026-05-05 | "Implement Milestone 4: Phase 1 Hardening"] `lib/state_helpers.sh:190-220` — No `# REMOVE IN m05` annotation on the legacy markdown branch in `_state_bash_read_field`. When `legacy_reader.go` is deleted in m05 this dead branch is likely to survive the cleanup pass. Adding the annotation now keeps the two removal targets in sync.
- [2026-05-04 | "Implement Milestone 3: Pipeline State Wedge"] `lib/state_helpers.sh:190-220` — No `# REMOVE IN m05` annotation on the legacy markdown branch in `_state_bash_read_field`. When `legacy_reader.go` is deleted in m05 this dead branch is likely to survive the cleanup pass. Adding the annotation now keeps the two removal targets in sync.

## Resolved
