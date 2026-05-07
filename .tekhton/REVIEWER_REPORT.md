# Reviewer Report — M14 Milestone DAG State Machine Wedge

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `cmd/tekhton/...` package reports 78.5% test coverage (Go quality checklist target is ≥80%). `cmd/tekhton` is an existing package, not a new one introduced by m14, so the deficit is largely inherited. The new `dag.go` code is well-exercised by `dag_test.go` (412 lines). Acceptable as-is but the gap should close incrementally.
- The `frontier` / `active` subcommands output bare newline-separated IDs to stdout, which is consistent with m13's `tekhton manifest list` precedent but diverges from the `internal/proto/` envelope principle in the reviewer checklist. Since m13 established this pattern and the parity tests lock down the contract, flagging as a drift observation rather than requiring rework (see Drift Observations).
- `scripts/dag-parity-check.sh` invokes `make build` at the top, which means it fails on a machine without the Go toolchain or without `make`. The test suite already accounts for this, but the script could document the requirement more prominently (or skip gracefully when `go` is absent, analogous to how `check_indexer_available` degrades without Python).
- `parse_milestones_auto` in `milestone_query.sh` returns non-zero when the manifest is loaded but contains zero entries (`[[ "$found" -eq 1 ]]` is false). An empty-but-valid manifest is unlikely in practice, but callers expecting 0 entries to be a success case would get a spurious failure. No current caller exercises this path, but it's worth documenting.

## Coverage Gaps
- The parity check script (`scripts/dag-parity-check.sh`) verifies `frontier`, `active`, `validate`, and `migrate` but does NOT parity-test `advance`. The Go unit test `TestAdvancePersistsViaSave` covers the atomicity of the write, but there is no fixture that runs `tekhton dag advance` from bash and then reads the result back with the bash `_DAG_*` array queries to confirm end-to-end correctness of the cross-process state mutation.
- `cmd/tekhton/dag_test.go` at 78.5% combined package coverage: edge paths not covered include `loadDagState` when `$MILESTONE_MANIFEST_FILE` is set (env fallback path), and `defaultManifestName` when called with a non-empty override.

## ACP Verdicts
No Architecture Change Proposals in CODER_SUMMARY.md — section omitted.

## Drift Observations
- `internal/dag` package: the cross-language contract for `frontier` and `active` is bare newline-separated IDs (matches m13's `tekhton manifest list` pattern). Both patterns diverge from the `internal/proto/` stamped-envelope principle stated in the reviewer checklist. The pattern is internally consistent, but the codebase now has two divergent cross-language seam styles (JSON for state/causal, plain text for manifest/dag). A future milestone that documents the seam taxonomy and picks one style would reduce this tension.
- `lib/milestone_dag.sh` line 33: `<<< "${deps//,/$'\n'}"` is a bashism (here-string with parameter expansion). This is valid Bash 4.3+ and consistent with the project's shell policy; noting it for future portability awareness.
