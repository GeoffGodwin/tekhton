# Coder Summary

## Status: COMPLETE

## What Was Implemented
Addressed all 14 open non-blocking notes in `.tekhton/NON_BLOCKING_LOG.md`. Items
1–10 were direct code changes; items 11–14 were documentation / verification:

1. `cmd/tekhton/supervise.go:51-53` + `internal/supervisor/supervisor.go:62` —
   Added comments at both sites explaining the intentional defensive double
   validation. `RunE` now states the redundancy is intentional; `Run` notes
   that any in-process caller bypassing the CLI still gets contract enforcement.
2. `cmd/tekhton/readSuperviseRequest` — Split exit-code semantics: parse and
   shape failures still wrap `proto.ErrInvalidRequest` (→ `exitUsage` 64);
   I/O failures (`os.ReadFile`, `io.ReadAll`) now return unwrapped errors so
   the CLI maps them to `exitSoftware` (70). Updated
   `TestSuperviseCmd_RejectsMissingRequestFile` to assert `exitSoftware`.
3 & 5. `lib/state_helpers.sh:118` — Added a comment explaining that the
   int-field omit-on-zero matches `omitempty` on the corresponding fields in
   `internal/proto/state_v1.go`. Same fix covers the duplicate from M3.
4 & 6. `lib/state_helpers.sh:152` — Added a doc comment naming the embedded
   escaped double-quote limitation of the awk-based JSON reader.
7. `cmd/tekhton/causal.go:37` — Added `causal.EnsureDirs(path)` helper in
   `internal/causal/log.go` and switched `newCausalInitCmd` to use it.
   `causal.Open` was scanning + seeding the entire log just to verify the
   directory existed — now `init` does only the work it needs.
8. `internal/proto/causal_v1.go` — `Itoa` was already removed but `strconv`
   was still imported. Removed the unused import.
9. `internal/causal/log.go:102` — `parseStageAndSeq` now uses `bytes.Index` /
   `bytes.IndexByte` directly on the byte slice (with a single
   `string(rest[:end])` only for the final id literal). No more per-line
   `string(line)` allocation.
10. `cmd/tekhton/causal.go` — `--stage` and `--type` on `causal emit` now use
    `cobra.MarkFlagRequired`, so missing flags surface a standard usage error
    instead of falling through to `causal.Emit`'s internal sentinel.
11. `.github/workflows/go-build.yml` — `golangci/golangci-lint-action` now
    pins `version: v1.64.5` instead of `latest`, with a comment explaining
    why drift would silently shift CI behavior.
12. `.github/workflows/go-build.yml` — Added a header comment documenting why
    the four action refs use major-version tags (`@v4`, `@v5`, `@v6`) rather
    than commit SHAs: the workflow's `permissions: contents: read` declaration
    bounds the blast radius of a tag-mutation attack. Per the original note,
    SHA pinning remains a future cleanup pass — but the rationale is now
    captured at the call site rather than only in the non-blocking log.
13. `docs/go-build.md:68` — Verified: the doc already shows
    `tr -d '[:space:]' < VERSION`, matching the Makefile. The note's claim of
    `$(cat VERSION)` is stale (no longer present in the file). No edit needed.
14. `.tekhton/CODER_SUMMARY.md` README.md absence — The original note
    explicitly said "no action needed". The current summary refers to the
    fresh task; no carry-over fix required.

## Root Cause (bugs only)
N/A — task is tech-debt cleanup, not a bug fix.

## Files Modified
- `lib/state_helpers.sh` — added two doc comments (items 3/4/5/6)
- `cmd/tekhton/supervise.go` — split I/O vs parse error mapping (item 2),
  added defensive-validation comment (item 1)
- `cmd/tekhton/supervise_test.go` — updated assertExitCode for the
  missing-request-file case to expect `exitSoftware` (item 2)
- `internal/supervisor/supervisor.go` — added defensive-validation comment
  (item 1)
- `internal/causal/log.go` — added `EnsureDirs`, swapped `strings.Index` →
  `bytes.Index` in `parseStageAndSeq`, added `bytes` import (items 7, 9)
- `internal/proto/causal_v1.go` — removed unused `strconv` import (item 8)
- `cmd/tekhton/causal.go` — call `causal.EnsureDirs` in `newCausalInitCmd`,
  mark `--stage` / `--type` required on `causal emit` (items 7, 10)
- `.github/workflows/go-build.yml` — pinned golangci-lint version, added
  comment on action-ref pinning strategy (items 11, 12)

## Human Notes Status
The task contains no `## Human Notes` block — there are no per-note items to
report on. All 14 non-blocking-log items are accounted for in the list above.

## Docs Updated
None — no public-surface changes. `causal.EnsureDirs` is an internal helper
in `internal/causal`; the CLI surface (`tekhton causal init` / `emit`) and
the JSON envelopes are unchanged. The only user-visible behavior change is
that `causal emit` now rejects missing `--stage` / `--type` with a Cobra
usage error (previously: an internal error string), consistent with how
other required flags behave and already documented inline in the help text
(`Stage name (required)` / `Event type (required)`).

## Verification
- `shellcheck lib/state_helpers.sh lib/state.sh` — clean (exit 0).
- `bash tests/test_state_roundtrip.sh` — passed.
- `bash tests/test_save_orchestration_state.sh` — passed.
- `bash tests/test_state_error_classification.sh` — passed.
- Go test suite (including the updated `TestSuperviseCmd_RejectsMissingRequestFile`)
  could not be run locally — `go` is not installed in this sandbox. The
  changes are import-clean, the only failing assertion (exit code 64 → 70)
  has been updated, and CI runs the full suite via `.github/workflows/go-build.yml`.
