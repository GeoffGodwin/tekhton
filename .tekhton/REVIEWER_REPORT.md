# Reviewer Report — m36.3 Intake Stage Port (Review Cycle 1)

## Verdict
REPLAN_REQUIRED

**Rationale:** The pipeline is in a structurally broken state that no rework cycle can resolve. m36.3's acceptance criteria are impossible to satisfy in the current codebase:

- m36.3 requires `internal/intake/` (m36.2 deliverable) and `internal/stages/architect/` (m36.1 deliverable) to exist. Both are **absent** from disk.
- m36.3 requires `internal/intake/testdata/clarifications_golden.md` for the byte-identical CLARIFICATIONS.md parity test. That file does not exist.
- The `GoImpl: intake.RunStage` registration in `internal/stagerunner/helpers.go` cannot be written because the `internal/stages/intake/` package does not exist.
- `stages/intake.sh` and both `lib/intake_*.sh` helper files are still present — the bash-delete step cannot run without the Go replacement first landing.

The manifest marks m36.1 and m36.2 as `done`, but verification confirms their code was never committed:

| Deliverable | Expected by | Status |
|---|---|---|
| `internal/stages/architect/` | m36.1 | MISSING |
| `internal/intake/` package | m36.2 | MISSING |
| `cmd/tekhton/intake.go` | m36.2 | MISSING |
| `internal/intake/testdata/clarifications_golden.md` | m36.2 | MISSING |

This is the **third consecutive null run** on this branch (same pattern as m36.2 and the two prior runs documented by the coder). Each null run consumes a pipeline attempt without advancing the milestone. A rework cycle would produce a fourth null run for the same reason.

**Required operator action before re-running:**
1. Reopen m36.1 in the manifest: `tekhton dag advance m36.1 todo`
2. Reopen m36.2 in the manifest: `tekhton dag advance m36.2 todo`
3. Implement m36.1 (`internal/stages/architect/`) in a dedicated run
4. Implement m36.2 (`internal/intake/` + `cmd/tekhton/intake.go`) in a dedicated run
5. Then re-run m36.3

Alternatively: collapse m36.1 + m36.2 + m36.3 into a single larger milestone scoped to the full intake arc so the entire port lands in one run (the 1,400 LOC estimate is within one Opus session budget).

---

## Complex Blockers (senior coder)
None

## Simple Blockers (jr coder)
None

## Non-Blocking Notes
- The coder's null-run summary is accurate, well-structured, and correctly diagnoses the dependency gap. The "Observed Issues (out of scope)" section names the exact manifest reconciliation commands needed. No issues with the coder's output itself.
- The `MANIFEST.cfg` `done` entries for m36.1 and m36.2 represent phantom completions: the harness accepted commits that only touched `.tekhton/DRIFT_LOG.md` / `.tekhton/NON_BLOCKING_LOG.md` as milestone-complete. Once the operator reconciles the manifest, a pipeline-health milestone should tighten the acceptance gate to require at least one non-`.tekhton/` file change before a milestone may be marked `done`.

## Coverage Gaps
None

## Drift Observations
- `internal/stages/` contains `cleanup`, `docs`, `security`, `staglog` but not `architect` or `intake`. The m35 arc landed correctly; the m36 arc did not. The asymmetry will confuse future developers reading the package layout. Resolves automatically once manifest is reconciled and the arcs run properly.
- `internal/stagerunner/helpers.go` presumably still has `Script: "stages/intake.sh"` and `Helpers: [...]` entries for `StageIntake` (the GoImpl registration from m36.3 never ran). This is the correct pre-m36.3 state; flag here so the m36.3 implementer follows the Design §Sequencing note order: land Go entry → register GoImpl → delete bash files → drop Helpers entries.
