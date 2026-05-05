# Drift Log

## Metadata
- Last audit: 2026-05-05
- Runs since audit: 0

## Unresolved Observations

## Resolved
- [RESOLVED 2026-05-05] `.tekhton/NON_BLOCKING_LOG.md item 2` — the current open note claims "I/O failures (file-not-found, unreadable stdin) are wrapped as `proto.ErrInvalidRequest`, causing `exitUsage`." This is factually incorrect against the current code: `os.ReadFile` and `io.ReadAll` failures are returned unwrapped and correctly map to `exitSoftware`. The test `TestSuperviseCmd_RejectsMissingRequestFile` already asserts `exitSoftware`. This note should be resolved/removed rather than carried forward, as it will mislead future coders into "fixing" code that is already correct.
- [RESOLVED 2026-05-05] `cmd/tekhton/state.go:149` defines `errExitCode`; exit-code constants (`exitUsage`, `exitSoftware`) live in `supervise.go`. As the package accumulates subcommands these shared CLI primitives will scatter across files. Consider extracting them to `cmd/tekhton/errors.go` before the list grows further.
- [RESOLVED 2026-05-05] `internal/supervisor/supervisor.go:47`: `ErrNotImplemented` is declared but no code path currently returns it. It is a valid forward-planning placeholder for m06 stub sites, but if m06 doesn't use it the variable should be removed then to avoid confusion.
- [RESOLVED 2026-05-05] `lib/state_helpers.sh:190-220` — No `# REMOVE IN m05` annotation on the legacy markdown branch in `_state_bash_read_field`. When `legacy_reader.go` is deleted in m05 this dead branch is likely to survive the cleanup pass. Adding the annotation now keeps the two removal targets in sync.
- [RESOLVED 2026-05-05] `lib/state_helpers.sh:190-220` — No `# REMOVE IN m05` annotation on the legacy markdown branch in `_state_bash_read_field`. When `legacy_reader.go` is deleted in m05 this dead branch is likely to survive the cleanup pass. Adding the annotation now keeps the two removal targets in sync.
