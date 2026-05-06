<!-- milestone-meta
id: "14"
status: "todo"
-->

# m14 — Milestone DAG State Machine Wedge

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 4 — third wedge. The milestone DAG state machine (`lib/milestone_dag.sh` + `lib/milestone_dag_helpers.sh` + `lib/milestone_dag_validate.sh` + `lib/milestone_dag_migrate.sh`, ~600 LOC total) drives `--auto-advance`, the frontier query, dependency satisfaction checks, and inline→file migration. After m13 the manifest parser is in Go; m14 makes the state machine that operates on parsed manifests Go too. |
| **Gap** | DAG state lives across four bash files with shared globals (`_DAG_FRONTIER`, `_DAG_ACTIVE`). Frontier computation re-parses the manifest on every call. Status updates aren't transactional with milestone-file edits. The migration step (`migrate_inline_milestones`) is a one-shot path that's hard to retest. |
| **m14 fills** | (1) `internal/dag` package owning the state machine: frontier computation, dependency satisfaction, status transitions, active-set tracking, archival hand-off. (2) `tekhton dag frontier` / `tekhton dag advance <id>` / `tekhton dag validate` subcommands. (3) Parity gate verifying frontier output matches bash for every milestone configuration in `tests/`. (4) Inline→file migration moves to `tekhton dag migrate` (one-shot, idempotent). |
| **Depends on** | m13 |
| **Files changed** | `internal/dag/` (new), `cmd/tekhton/dag.go` (new), `lib/milestone_dag.sh` / `_helpers.sh` / `_validate.sh` / `_migrate.sh` (delete or shrink), `lib/milestone_window.sh` (consume Go DAG output via shim), `scripts/dag-parity-check.sh` (new) |
| **Stability after this milestone** | Stable. `--auto-advance` and milestone progression continue to work. m12's orchestrate loop now consults `tekhton dag` for advancement decisions instead of bash globals. |
| **Dogfooding stance** | Cutover within milestone. |

---

## Design

### Goal 1 — `internal/dag.State`

```go
package dag

type State struct {
    manifest *manifest.Manifest
}

func New(m *manifest.Manifest) *State
func (s *State) Frontier() []*manifest.Entry  // ready-to-run milestones
func (s *State) Active() []*manifest.Entry    // status=in_progress
func (s *State) DepsSatisfied(id string) bool
func (s *State) Advance(id, newStatus string) error  // validates transition
func (s *State) Validate() []ValidationError       // cycle detection, missing deps
```

Status transition rules encoded explicitly:

```
todo → in_progress → done
todo → in_progress → skipped
todo → in_progress → split
in_progress → done | skipped | split | todo (resume after failure)
done → done (idempotent)
```

### Goal 2 — Migration as a one-shot subcommand

`tekhton dag migrate --inline-claude-md path/to/CLAUDE.md` extracts inline
milestones into `.claude/milestones/m<NN>-*.md` files and seeds
MANIFEST.cfg. Idempotent: running twice produces no changes after the
first run. Replaces `lib/milestone_dag_migrate.sh::migrate_inline_milestones`.

### Goal 3 — Sliding-window consumption

`lib/milestone_window.sh::build_milestone_window` selects active +
frontier + on-deck milestones within a character budget. After m14 it
consumes `tekhton dag frontier` output rather than re-parsing
MANIFEST.cfg. The window helper itself stays bash for now (small,
budget-tuning logic) — it's a Phase 5 candidate, not Phase 4.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/dag/` | Create | State machine, frontier, validate, migrate. ~400-500 LOC. |
| `cmd/tekhton/dag.go` | Create | `dag frontier / active / advance / validate / migrate` subcommands. ~200 LOC. |
| `lib/milestone_dag.sh` | Modify | Shrink to ~80-line shim. |
| `lib/milestone_dag_helpers.sh` | Delete | Logic moves to Go. |
| `lib/milestone_dag_validate.sh` | Delete | Logic moves to Go. |
| `lib/milestone_dag_migrate.sh` | Delete | Logic moves to Go. |
| `lib/milestone_window.sh` | Modify | Consume `tekhton dag frontier` output. |
| `scripts/dag-parity-check.sh` | Create | Frontier/active/validate parity. ~150 LOC. |

---

## Acceptance Criteria

- [ ] `tekhton dag frontier` output matches the bash `dag_get_frontier` output for every fixture in `tests/fixtures/dag/`.
- [ ] `tekhton dag advance 12 in_progress` transitions a manifest entry atomically; concurrent reads see either pre- or post-state.
- [ ] `tekhton dag validate` detects: cycles, missing dependency targets, unknown statuses, duplicate IDs.
- [ ] `tekhton dag migrate --inline-claude-md fixture.md` produces the same milestone file set as `lib/milestone_dag_migrate.sh::migrate_inline_milestones`.
- [ ] `lib/milestone_dag.sh` is ≤ 100 lines.
- [ ] `git ls-files lib/milestone_dag_helpers.sh lib/milestone_dag_validate.sh lib/milestone_dag_migrate.sh` returns no files.
- [ ] `internal/dag` coverage ≥ 80%.
- [ ] `bash tests/run_tests.sh` passes; DAG-related tests (`test_milestone_dag*.sh`, `test_validate_config*.sh`) adapted.

## Watch For

- **The status enum is shared with m13's manifest writer.** Keep the constants in `internal/manifest` (m13's package) and import them in `internal/dag`. Don't duplicate.
- **Migration is one-shot.** A future tekhton install could do this on first run, but for V4 it's a manual `tekhton dag migrate` invocation. Document in the new subcommand's `--help`.
- **Auto-advance gating stays in bash for now.** The `AUTO_ADVANCE_*` config keys live in `pipeline.conf` and route through `lib/orchestrate.sh`; orchestrate calls `tekhton dag advance` when a milestone passes acceptance. No new config in m14.
- **Don't roll the milestone window in here.** That's a Phase 5 candidate.

## Seeds Forward

- **m17 — error taxonomy:** `dag.ValidationError` joins the typed error set, so `errors.Is(err, dag.ErrCycle)` works across packages.
- **`--auto-advance` in Go (Phase 4 final):** the orchestrate loop's auto-advance branch eventually consumes `internal/dag` directly without the CLI hop. m14 sets up the package; the in-process call lands when the auto-advance bash branch ports.
- **V5 multi-project DAGs:** `internal/dag.State` is sized for a single-manifest workspace. V5's multi-project scope might wrap multiple `State` instances; the package boundary is set up for that.
