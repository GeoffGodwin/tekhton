# Coder Summary — M14 Milestone DAG State Machine Wedge

## Status: COMPLETE

## What Was Implemented

Ported the milestone-DAG state machine from four bash files (~600 LOC) into a
Go package, exposing it to bash via the new `tekhton dag …` subcommand. The
on-disk MANIFEST.cfg format is unchanged (m13 owns it). Bash callers continue
to iterate the cached `_DAG_*` arrays for in-memory queries; cross-process
operations (validate / migrate / pointer-rewrite) exec the Go binary.

### Goal 1 — `internal/dag.State`

```go
type State struct { /* wraps *manifest.Manifest */ }

func New(m *manifest.Manifest) *State
func (s *State) Frontier() []*manifest.Entry
func (s *State) Active() []*manifest.Entry
func (s *State) DepsSatisfied(id string) bool
func (s *State) Advance(id, newStatus string) error
func (s *State) Validate(milestoneDir string) []*ValidationError
```

Status transitions encoded explicitly in `validTransition`:

```
pending|todo → pending | todo | in_progress | skipped
in_progress  → done | skipped | split | todo | pending
done | skipped | split → terminal (only same-status idempotent updates)
```

`Advance` returns `ErrInvalidTransition` for disallowed transitions (e.g.
`done → in_progress`) and `ErrUnknownStatus` for status strings outside the
canonical set. `ErrNotFound` is returned when the id is not in the manifest.

`Validate` runs five structural checks: duplicate IDs, missing dependency
targets, unknown statuses, missing milestone files (when `milestoneDir` is
non-empty), and circular dependencies (DFS-based, mirroring bash
`_dfs_cycle_check`). Each finding wraps a sentinel (`ErrCycle`,
`ErrMissingDep`, etc.) so callers match with `errors.Is`.

### Goal 2 — Migration as a one-shot subcommand

`internal/dag.Migrate(MigrateOptions)` walks `CLAUDE.md`, extracts inline
milestones via a streaming line scanner (`parseInlineMilestones`), and
writes one milestone file per entry plus a fresh `MANIFEST.cfg`.
**Idempotent**: returns `ErrMigrateAlreadyDone` when `MANIFEST.cfg` already
exists. Replaces `lib/milestone_dag_migrate.sh::migrate_inline_milestones`.

`internal/dag.RewritePointer(claudeMD)` replaces inline milestone blocks
with a two-line pointer comment, matching the pre-m14 bash
`_insert_milestone_pointer` output byte-for-byte.

Helpers (`numberToID`, `slugify`, `inferDependencies`) port the bash
equivalents and are unit-tested directly.

### Goal 3 — Sliding-window consumption

`lib/milestone_window.sh::build_milestone_window` continues to read the
in-memory `_DAG_*` arrays — they're now the Go-backed cache (populated by
m13's `load_manifest` shim, which itself execs `tekhton manifest list`).
The window helper itself stays bash; the comment block at the top of the
file documents that the same status / dep semantics live in
`internal/dag.State.Frontier` / `Active` for future Phase-5 ports.

### CLI subcommands (`cmd/tekhton/dag.go`)

```
tekhton dag frontier  --path PATH            # IDs ready to run
tekhton dag active    --path PATH            # IDs with status=in_progress
tekhton dag advance   --path PATH ID STATUS  # validated transition + atomic save
tekhton dag validate  --path PATH [--milestone-dir DIR]
tekhton dag migrate   --inline-claude-md PATH --milestone-dir DIR [--rewrite-pointer]
tekhton dag rewrite-pointer --inline-claude-md PATH
```

Exit codes follow existing conventions:
- 0 success
- 1 (`exitNotFound`) — file missing or unknown ID
- 2 (`exitCorrupt`) — manifest validation failures
- 64 (`exitUsage`) — invalid status string or disallowed transition

### Bash shim rewrite (`lib/milestone_dag.sh`)

Reduced from ~600 LOC across four files to **92 lines** in a single shim
file. The shim provides the public API the rest of the bash tree imports
(`dag_get_count`, `dag_get_id_at_index`, `dag_get_status`, `dag_set_status`,
`dag_get_file`, `dag_get_title`, `dag_get_active`, `dag_get_frontier`,
`dag_deps_satisfied`, `dag_find_next`, `dag_id_to_number`, `dag_number_to_id`)
operating on the cached `_DAG_*` arrays — these are pure-bash by design
(in-process, called per-iteration, not worth fork-overhead). Cross-process
shims (`validate_manifest`, `migrate_inline_milestones`,
`_insert_milestone_pointer`) exec `tekhton dag <subcommand>`.

The deleted files (`lib/milestone_dag_helpers.sh`, `_validate.sh`,
`_migrate.sh`) move their public surface to either the shim, the Go
package, or `lib/milestone_query.sh` (parse_milestones_auto et al.).

### `lib/milestone_query.sh` (NEW)

Holds the four DAG-aware milestone wrappers extracted from the deleted
`milestone_dag_helpers.sh`: `parse_milestones_auto`, `get_milestone_count`,
`get_milestone_title`, `is_milestone_done`. Each prefers the manifest
path when DAG mode is enabled and falls back to inline `parse_milestones`
otherwise. Sourced by `tekhton.sh` after `milestone_dag.sh`.

## Root Cause (bugs only)
N/A — milestone implementation, not a bug fix.

## Files Modified

### NEW
- `internal/dag/dag.go` (NEW, 162 lines) — State, transition table, sentinels
- `internal/dag/validate.go` (NEW, 176 lines) — 5-check structural validator
- `internal/dag/migrate.go` (NEW, 336 lines) — Inline→file migrator + pointer rewriter
- `internal/dag/dag_test.go` (NEW, 206 lines) — State machine tests
- `internal/dag/validate_test.go` (NEW, 152 lines) — validator tests
- `internal/dag/migrate_test.go` (NEW, 254 lines) — migration tests
- `internal/dag/testhelpers_test.go` (NEW, 7 lines)
- `cmd/tekhton/dag.go` (NEW, 245 lines) — Cobra subcommands + error mapping
- `cmd/tekhton/dag_test.go` (NEW, 412 lines) — CLI behavior tests
- `lib/milestone_query.sh` (NEW, 142 lines) — DAG-aware milestone wrappers
- `scripts/dag-parity-check.sh` (NEW, 262 lines) — 5-fixture parity matrix
- `tests/test_milestone_query.sh` (NEW) — exercises `milestone_query.sh`

### MODIFIED
- `lib/milestone_dag.sh` — collapsed to 92 lines (≤100 ceiling); now a wedge shim
- `lib/milestone_window.sh` — comment-only update flagging the in-memory `_DAG_*` arrays as the Go-backed cache; behavior unchanged (still bash; Phase-5 candidate)
- `cmd/tekhton/main.go` — wired `newDagCmd()` into the root command
- `ARCHITECTURE.md` — added entries for `internal/dag`, `cmd/tekhton/dag.go`, `lib/milestone_query.sh`; updated `lib/milestone_dag.sh` to reflect shim status
- `CLAUDE.md` — repository layout updated for the m14 wedge
- (Multiple test files) — adapted to the new shim + Go binary expectation; rebuild required (`make build`) before running DAG-related shell tests

### DELETED
- `lib/milestone_dag_helpers.sh` — logic moved to Go (queries) and `milestone_query.sh` (wrappers)
- `lib/milestone_dag_validate.sh` — logic moved to `internal/dag.Validate`
- `lib/milestone_dag_migrate.sh` — logic moved to `internal/dag.Migrate`

## Test Results

| Suite | Result |
|---|---|
| `tests/test_milestone_dag.sh` | 40 passed, 0 failed |
| `tests/test_milestone_dag_migrate.sh` | 15 passed, 0 failed |
| `tests/test_milestone_dag_coverage.sh` | 17 passed, 0 failed |
| `tests/test_milestone_dag_archival_metadata.sh` | 15 passed, 0 failed |
| `tests/test_dag_get_id_at_index.sh` | 13 passed, 0 failed |
| `tests/test_find_next_milestone_dag.sh` | 9 passed, 0 failed |
| `tests/test_m111_dag_split_bugs.sh` | 22 passed, 0 failed |
| `tests/test_m111_downstream_dep_unblock.sh` | 11 passed, 0 failed |
| `tests/test_milestone_query.sh` | 21 passed, 0 failed |
| `tests/test_milestone_window.sh` | 29 passed, 0 failed |
| `scripts/dag-parity-check.sh` | 5 fixtures × frontier/active + 4 validate gates + migrate idempotency — all PASS |
| `go test ./internal/dag/...` | ok, **89.3%** coverage (target ≥ 80%) |
| `go test ./cmd/tekhton/...` | ok, 78.5% coverage |
| `go test ./...` | all packages ok |
| `shellcheck tekhton.sh lib/*.sh stages/*.sh scripts/dag-parity-check.sh` | clean |

Full `bash tests/run_tests.sh` run: **494 of 496 shell tests pass**, all 250
Python tests pass, all Go packages pass.

The 2 failing shell tests (`test_diagnose.sh`, `test_state_error_classification.sh`)
are **pre-existing m03 wedge failures unrelated to m14** — verified by
`git stash && PATH="${PWD}/bin:${PATH}" bash tests/test_state_error_classification.sh`
against the m13 baseline (commit `0f337ff`), which produces identical
failures. Both stem from a JSON formatting difference between the Go state
writer (`encoding/json.MarshalIndent` emits `"key": "value"` with a space)
and the bash fallback writer (`"key":"value"` no space) — the test's
`grep -F` looks for the no-space form. The m13 CODER_SUMMARY also
documented these as pre-existing.

## Acceptance-criterion check

| AC | Requirement | Status |
|---|---|---|
| 1 | `tekhton dag frontier` matches bash `dag_get_frontier` for every fixture | ✓ (parity script: 5 fixtures, frontier + active) |
| 2 | `tekhton dag advance ID in_progress` transitions atomically | ✓ (writes via manifest's tmpfile + os.Rename) |
| 3 | `tekhton dag validate` detects cycles, missing deps, unknown statuses, duplicate IDs | ✓ (parity gates + Go unit tests) |
| 4 | `tekhton dag migrate` matches bash `migrate_inline_milestones` | ✓ (parity migrate_idempotent gate + Go tests + bash test_milestone_dag_migrate.sh) |
| 5 | `lib/milestone_dag.sh` ≤ 100 lines | ✓ (92 lines) |
| 6 | `git ls-files lib/milestone_dag_helpers.sh _validate.sh _migrate.sh` returns no files | ✓ (verified) |
| 7 | `internal/dag` coverage ≥ 80% | ✓ (89.3%) |
| 8 | `bash tests/run_tests.sh` passes; DAG-related tests adapted | ✓ for DAG tests; 2 pre-existing m03 failures unrelated to m14 |

## Architecture Change Proposals

None — the wedge follows the m03/m13 pattern: Go owns the new logic,
bash shim execs the Go binary for cross-process operations, in-memory
bash queries continue to operate on cached `_DAG_*` arrays (zero
fork-overhead for hot paths like frontier iteration during auto-advance).

## Docs Updated

- `ARCHITECTURE.md` — added entries for `internal/dag`, `cmd/tekhton/dag.go`,
  `lib/milestone_query.sh`; updated `lib/milestone_dag.sh` description to
  reflect shim status and current public-function surface
- `CLAUDE.md` — repository layout (lib/) updated for m14: removed deleted
  helper/validate/migrate file lines; added `milestone_query.sh`; updated
  `milestone_dag.sh` annotation
- `.tekhton/DOCS_AGENT_REPORT.md` — updated for m14 (already present in
  working tree at session start)

No user-facing CLI flags, config keys, or schema changes; no other docs need
updating.

## Human Notes Status

No human notes provided in this run.
