<!-- milestone-meta
id: "20"
status: "in_progress"
-->

# m20 — Dogfooding Cutover

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 4 — third and final wedge of the m18→m20 dogfooding-cutover batch. m18 made `tekhton pipeline run-attempt` the per-attempt scheduler. m19 made `tekhton run` the run-level entry point and proved it works via a 10-scenario parity gate. m20 flips `tekhton.sh` from "the orchestrator" to "a dispatcher" — for run-flags, it execs the Go binary; for legacy flags it keeps the existing bash code paths until Phase 5. With the entry point flipped, the next V4 milestone (m21+) is run via `tekhton run` end-to-end. That's dogfooding. |
| **Gap** | After m19, `tekhton.sh` is still ~1000 lines of bash that argument-parses, sources config, runs pre-flight, picks the active milestone, and dispatches to either the Go runner (via `tekhton run`) for run-flags or to bash subsystems for legacy flags. The argument-parsing + dispatch tier still being bash means a typo in flag handling or env propagation can mask a Go-side bug. m20 inverts that: argument parsing + dispatch is one place (`tekhton.sh` shim, ≤80 lines), and Go owns the run lifecycle from there. |
| **m20 fills** | (1) `tekhton.sh` shrinks to a ≤80-line dispatcher: `--task`/`--complete`/`--resume`/`--human`/`--milestone`/`--auto-advance`/`--dry-run` exec `tekhton run "$@"`; everything else calls the existing bash subsystem entry points (themselves still in `tekhton.sh` until Phase 5 absorbs them). (2) `scripts/self-host-check.sh` expands from its current minimal smoke to a 15-scenario matrix. (3) `docs/go-migration.md` gets a Phase 4 retro section, and a Phase 5 design stub opens with a punch-list of bash subsystems still standing. (4) The first V4 milestone after m20 (m21) is authored to be implemented via `tekhton run` — that's the dogfooding signal. (5) Tag the cutover commit `v4.20.0-dogfood`. |
| **Depends on** | m18, m19 |
| **Files changed** | `tekhton.sh` (modify — shrink to dispatcher), `scripts/self-host-check.sh` (modify — expand to 15-scenario matrix), `docs/go-migration.md` (modify), `docs/v4-phase5-stub.md` (create), `Makefile` (modify — `make dogfood` target), `README.md` (modify — note dogfooding cutover), `VERSION` (modify — bump to `4.20.0` on close) |
| **Stability after this milestone** | **Cutover.** `tekhton.sh` is a thin dispatcher. The Go binary owns every pipeline run. Phase 4 batch 2 closes; Phase 5 (bash deprecation of finalize, preflight, dashboard, TUI writers, notes/drift/clarify, init, plan, draft-milestones, etc.) opens. |
| **Dogfooding stance** | **Cutover within the milestone.** No parallel paths. The first run after m20 closes is via `tekhton run`. That run authors and ships m21. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m18 | Per-attempt scheduler + gates moved to Go. |
| m19 | Outer retry loop + run-level CLI moved to Go; bridges for finalize/preflight/TUI. |
| **m20** | **Entry-point flip; `tekhton.sh` becomes a dispatcher; first dogfooded V4 milestone follows.** |

---

## Design

### Sequencing note

m20 is intentionally small in code volume but heavy in process. The risk is *not* that the Go runner regresses (m19's parity gate is the safety net) — it's that the dispatcher shim in `tekhton.sh` mishandles a flag combination or environment variable that the bash side relied on implicitly. The 15-scenario self-host matrix is the gate. If any scenario fails, m20 doesn't merge; the fix is *additive* (extend the shim or fix the runner), never *destructive* (keep the bash entry point and pretend).

### Goal 1 — `tekhton.sh` becomes a dispatcher

Target shape (≤80 lines):

```bash
#!/usr/bin/env bash
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEKHTON_BIN="${TEKHTON_BIN:-${TEKHTON_HOME}/bin/tekhton}"
export TEKHTON_HOME TEKHTON_BIN

# Build the binary if missing — first-run convenience.
if [[ ! -x "$TEKHTON_BIN" ]]; then
    (cd "$TEKHTON_HOME" && make build) >&2
fi

# Run-flags: dispatch to Go.
case "${1:-}" in
    --task|--complete|--resume|--human|--milestone|--auto-advance|--dry-run|--no-tui)
        exec "$TEKHTON_BIN" run "$@"
        ;;
esac

# Detect run-flags appearing later in the argv (e.g. `tekhton.sh --milestone m21 --complete`).
for arg in "$@"; do
    case "$arg" in
        --task|--complete|--resume|--human|--milestone|--auto-advance|--dry-run|--no-tui)
            exec "$TEKHTON_BIN" run "$@"
            ;;
    esac
done

# Legacy flags: keep the existing bash code paths until Phase 5 ports them.
case "${1:-}" in
    --init)             source "${TEKHTON_HOME}/lib/init.sh"; cmd_init "$@" ;;
    --rescan)           source "${TEKHTON_HOME}/lib/rescan.sh"; cmd_rescan "$@" ;;
    --draft-milestones) source "${TEKHTON_HOME}/lib/draft_milestones.sh"; cmd_draft_milestones "$@" ;;
    --report)           source "${TEKHTON_HOME}/lib/dashboard.sh"; cmd_report "$@" ;;
    --status)           source "${TEKHTON_HOME}/lib/dashboard.sh"; cmd_status "$@" ;;
    --metrics)          source "${TEKHTON_HOME}/lib/metrics.sh"; cmd_metrics "$@" ;;
    --migrate)          source "${TEKHTON_HOME}/lib/migrate_cli.sh"; cmd_migrate "$@" ;;
    --health)           source "${TEKHTON_HOME}/lib/health.sh"; cmd_health "$@" ;;
    --rollback)         source "${TEKHTON_HOME}/lib/safety_net.sh"; cmd_rollback "$@" ;;
    --notes)            source "${TEKHTON_HOME}/lib/notes_cli.sh"; cmd_notes "$@" ;;
    --version|-v)       cat "${TEKHTON_HOME}/VERSION" ;;
    --help|-h|"")       exec "$TEKHTON_BIN" run --help ;;
    *)                  echo "tekhton: unknown flag: $1" >&2; exit 64 ;;
esac
```

**What disappears from `tekhton.sh`:** all the prior pre-flight wiring, milestone selection, `run_complete_loop` dispatch, finalize wiring, error handling, signal handling. That's all in Go now.

**What stays bash:** the legacy-flag dispatch table. Each `cmd_<flag>` function exists in its respective `lib/<x>.sh` file already — `tekhton.sh` just routes to them. Phase 5 will collapse each `cmd_<flag>` into a Go subcommand.

### Goal 2 — Self-host parity matrix

`scripts/self-host-check.sh` expands from its current minimal smoke to 15 scenarios. The matrix is built incrementally over the milestone — each row is a separate fixture.

| # | Scenario | What it proves |
|---|----------|----------------|
| 1 | `--task "trivial"` | Happy path basic |
| 2 | `--task` with build-gate retry once | Build-fix loop works through Go runner |
| 3 | `--task` with review rework | Review cycle counter increments correctly |
| 4 | `--task` with security HIGH block | Security stage short-circuits run |
| 5 | `--task` with tester pre-existing-baseline pass | Baseline logic preserved |
| 6 | `--complete --task` succeeding on attempt 1 | Outer loop happy path |
| 7 | `--complete --task` succeeding on attempt 3 (transient retries) | Recovery dispatch works through Go |
| 8 | `--complete --task` hitting MAX_PIPELINE_ATTEMPTS | STUCK exit reason recorded |
| 9 | `--complete --task` hitting AUTONOMOUS_TIMEOUT | TIMEOUT exit reason recorded |
| 10 | `--milestone mNN` (non-complete) | Milestone-mode single-attempt |
| 11 | `--milestone mNN --complete --auto-advance` | Auto-advance prompt path |
| 12 | `--resume` after SIGINT | Resume routing |
| 13 | `--human --human-tag BUG` | Human-mode notes filtering |
| 14 | `--no-tui` | TUI off |
| 15 | `--dry-run --task` | Dry-run preview |

Each scenario:
- Records expected outputs (`RUN_SUMMARY.json`, `PIPELINE_STATE.json`, `CAUSAL_LOG.jsonl`, git log) from a *known-good* bash baseline run captured before m18 lands. Baselines live in `testdata/self-host/<NN>/expected/`.
- Runs the m20 implementation under `tekhton.sh`.
- Diffs outputs after timestamp/PID/commit-hash normalization.

CI matrix: `linux/amd64`, `darwin/amd64`, `windows/amd64` (the m09 reaper path needs the Windows row).

### Goal 3 — `make dogfood` Makefile target

```make
.PHONY: dogfood
dogfood: build
	@echo "Running self-host parity matrix..."
	@bash scripts/self-host-check.sh
	@echo
	@echo "Running first dogfooded V4 milestone (m21)..."
	@bin/tekhton run --milestone m21 --complete
```

`make dogfood` is the canonical "is the cutover live and working" command. It runs the parity matrix and then runs the next milestone via the Go binary. After m20 it should be `green` on every commit to `main`.

### Goal 4 — Documentation: Phase 4 retro and Phase 5 stub

`docs/go-migration.md` gets a Phase 4 retro section:

- What landed (m12–m20: orchestrate classifier → manifest parser → DAG → prompt → config → errors → pipeline runner → tekhton run → cutover).
- What we learned (envelope schemas held; finalize bridge was the right deferral; TUI status race needs the atomic-write pattern; Windows reaper is real and m09 was correct to land it before this).
- What didn't go as planned (capture honestly).
- Code volume diff: bash LOC at start of Phase 4 vs end (target: ~3000 fewer lines of bash).

`docs/v4-phase5-stub.md` (new) is a Phase 5 prep doc — *not* a full design, just an inventory:

- **Bash subsystems still standing after m20:** finalize (26 hooks), preflight, dashboard emitters, TUI status writers (mid-run), notes/drift/clarify, specialists, health, diagnose, indexer/MCP glue, init, plan (interview/browser/answers/generate), draft-milestones, migrate, notes-cli, rescan, rollback, status, report, metrics, detect, crawler, intake_helpers, milestone_acceptance, milestone_split, mcp, run_memory, timing, safety_net, pipeline_order, project_version, drift_artifacts, drift_cleanup, drift_prune, etc.
- **Phase 5 candidate ordering:** finalize first (highest dogfooding pain because every run touches it), then preflight + TUI writers, then dashboard, then notes/drift, then init/plan/draft-milestones (lowest priority — invoked rarely).
- **Open questions:** does the milestone-acceptance check stay bash for now, or port early because `RunCompleteLoop` calls it on every successful attempt? (Decision register entry.)

### Goal 5 — Version bump and tag

On milestone close: `VERSION` → `4.20.0`. Cutover commit gets tagged `v4.20.0-dogfood`. The tag is the marker — every `git log v4.20.0-dogfood..` from then on is a Go-driven run.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `tekhton.sh` | Modify | Shrink from ~1000 lines to ≤80 lines. Dispatch run-flags to `tekhton run`; route legacy flags to existing bash entry points. |
| `scripts/self-host-check.sh` | Modify | Expand from current smoke test to 15-scenario parity matrix. |
| `testdata/self-host/01-15/expected/` | Create | Baseline outputs for each parity scenario. |
| `docs/go-migration.md` | Modify | Phase 4 retro section: what landed, lessons, LOC diff. |
| `docs/v4-phase5-stub.md` | Create | Phase 5 inventory of remaining bash subsystems and candidate ordering. |
| `Makefile` | Modify | Add `make dogfood` target. |
| `README.md` | Modify | Note dogfooding cutover; update "How It Works" to point at `tekhton run`. |
| `VERSION` | Modify | Bump to `4.20.0` on close. |
| `tests/test_dispatcher.sh` | Create | Verify the dispatcher routes each flag correctly (no regression on legacy flags). |
| `scripts/wedge-audit.sh` | Modify | Add patterns banning re-introduction of `run_complete_loop` and direct `_run_pipeline_stages` references in `tekhton.sh` itself. |

---

## Acceptance Criteria

- [ ] `wc -l tekhton.sh` reports ≤80 lines.
- [ ] `tekhton.sh --task "x"`, `--complete`, `--resume`, `--human`, `--milestone`, `--auto-advance`, `--dry-run`, `--no-tui` all exec `tekhton run` (verified by `tests/test_dispatcher.sh`).
- [ ] `tekhton.sh --init`, `--rescan`, `--draft-milestones`, `--report`, `--status`, `--metrics`, `--migrate`, `--health`, `--rollback`, `--notes` route to their existing bash subsystem entry points (verified by `tests/test_dispatcher.sh`).
- [ ] `tekhton.sh --version` prints the contents of `VERSION`.
- [ ] `tekhton.sh --help` runs `tekhton run --help`.
- [ ] `tekhton.sh --task` with a flag later in argv (e.g. `tekhton.sh --milestone m21 --complete`) still dispatches to `tekhton run` (regression guard for argv-position routing).
- [ ] `scripts/self-host-check.sh` exits 0 on all 15 scenarios on `linux/amd64`, `darwin/amd64`, and `windows/amd64`.
- [ ] `make dogfood` exits 0.
- [ ] `bash scripts/wedge-audit.sh` exits 0.
- [ ] `bash tests/run_tests.sh` passes; `go test ./...` passes.
- [ ] `docs/go-migration.md` has a "Phase 4 retro" section with: shipped milestones, lessons, LOC diff (bash before/after).
- [ ] `docs/v4-phase5-stub.md` exists and lists each remaining bash subsystem with a one-line disposition (port / shim / leave).
- [ ] `VERSION` reads `4.20.0`.
- [ ] The cutover commit is tagged `v4.20.0-dogfood`.
- [ ] m21 (the next V4 milestone) is authored *after* m20 closes and is implemented end-to-end via `tekhton run` — the first dogfooded run.

## Watch For

- **The dispatcher is the new failure mode.** Until m20, a flag bug shows up in bash where you can `bash -x` it. After m20, a flag bug might surface as `tekhton run` exiting with a confusing error. Add a `--debug-dispatcher` env var (`TEKHTON_DEBUG_DISPATCHER=1`) that traces the routing decision and prints the exec line. Worth ~5 LOC.
- **Don't try to port legacy flags in m20.** The temptation is "while I'm here, let me move `--init` to Go too." Don't. m20 is the cutover; legacy flags are Phase 5. Mixing scope here means m20 doesn't ship cleanly.
- **First dogfooded run will surface unknowns.** The 15-scenario matrix is good but synthetic. The first real run on a real V4 milestone (m21) will hit something neither the parity gate nor the unit tests covered. Plan for ~2 days of follow-up fixes after m20 closes; track them as patch-level bumps (`4.20.1`, `4.20.2`).
- **Windows scenarios are the highest-risk row.** WSL path quirks, Windows newline handling in the dispatcher case-statements, the m09 reaper interactions. Run the Windows row of self-host-check first, not last.
- **Don't change `tekhton.sh`'s argv handling for legacy flags.** Each `cmd_<flag>` function expects `"$@"` to look like it always has. If you find yourself writing flag-translation code in the dispatcher for a legacy flag, you're in scope creep — stop.
- **Tag the cutover.** `v4.20.0-dogfood` is not just a version bump; it's the boundary for "first dogfood-era commit" reporting. Don't skip the tag.

## Seeds Forward

- **m21 — first dogfooded milestone:** Authored after m20 closes, implemented via `tekhton run`. The milestone topic is open (likely the Phase 5 finalize port, given that's the highest dogfooding pain point), but the *fact* that m21 is dogfooded is what matters.
- **Phase 5 — bash deprecation:** `docs/v4-phase5-stub.md` becomes the seed for `DESIGN_v5_phase5.md`. Each remaining bash subsystem gets a milestone (or merges with a peer); finalize first, then preflight + TUI writers, then dashboard, then the long tail.
- **`make dogfood` as CI gate:** Once stable, wire `make dogfood` into the CI pipeline as a release-blocker. Catches regressions in either the dispatcher shim or the runner.
- **V5 multi-provider entry point:** The `tekhton run` Cobra surface introduced in m19 and made canonical in m20 is the binding point V5 extends. Provider flags (`--provider anthropic|openai|...`) and parallel-stage flags (`--parallel coder,security`) plug into this surface.
- **Bash LOC budget tracking:** Establish the Phase 4 end-of-batch LOC count as a baseline. Phase 5 milestones that *don't* reduce the bash LOC count are suspect — the whole point of V4 is to drive it toward zero. `docs/go-migration.md` records the running total.
