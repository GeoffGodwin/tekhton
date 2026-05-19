<!-- milestone-meta
id: "24"
status: "todo"
-->

# m24 — Notes Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — fourth dogfooded V4 milestone. The notes subsystem is the largest single bash surface left after m22-m23 (14 files, 2188 LOC) and is touched by every pipeline run: prompts render `HUMAN_NOTES_BLOCK` from it, finalize hooks resolve and archive it, the milestone acceptance gate reads it, and the `tekhton note ...` CLI is the user-facing surface for adding work. Until notes ports, four finalize-shim case arms (`_hook_baseline_cleanup`, `_hook_express_persist`, `_hook_note_acceptance`, `_hook_failure_context_reset`, plus `_hook_cleanup_resolved` and `_hook_resolve_notes`) source bash, the human-notes block is rendered by bash even though every consumer is now Go, and the three-state state machine (`[ ]` not started / `[~]` in-scope / `[x]` done) lives in `lib/notes_core.sh` where the Go runner can't see transitions. |
| **Gap** | 14 bash files in the `lib/notes*.sh` family total 2188 lines and own the entire note lifecycle: `notes.sh` (parser + filter), `notes_core.sh` (state machine + tag registry + claim/resolve), `notes_acceptance.sh` + helpers (milestone acceptance heuristics), `notes_cleanup.sh` (post-success sweep), `notes_cli.sh` + write helpers (`tekhton note add/list/done`), `notes_migrate.sh` (V2→V3 format migrator), `notes_rollback.sh`, `notes_single.sh` (`--human` mode), `notes_triage.sh` + flow + report (heuristic scoring + agent escalation). The `HUMAN_NOTES_BLOCK` template variable is rendered by `lib/prompts.sh` calling into `extract_unchecked_notes` — every prompt render forks bash for this. Six finalize-shim case arms source notes bash. The `tekhton note` CLI is bash-only; Cobra has no `note` subcommand. m21 closeout's drift entry "non-blocking router misclassified a CI-failing test as non-blocking" lives in this subsystem's neighbour (`lib/drift_artifacts.sh`) but the misclassification flows through notes — m25 inherits the drift fix and m24 must not paper over it. |
| **m24 fills** | (1) `internal/notes/` becomes the Go-side notes subsystem with seven files: `state.go` (the three-state state machine + tag registry), `parser.go` (HUMAN_NOTES.md round-trip), `extract.go` (filter + `HUMAN_NOTES_BLOCK` builder), `acceptance.go` (milestone acceptance heuristics — ports `notes_acceptance.sh`), `cleanup.go` (post-success sweep), `triage.go` (heuristic scoring), `migrate.go` (V2→V3 format detection + upgrade). (2) `internal/notes/cli.go` plus `cmd/tekhton/note.go` add `tekhton note {add,list,done,triage,migrate,rollback,resolve}` as a top-level subcommand (visible, not Hidden — this is the user-facing surface, not a debug seam). (3) Six pure-Go finalize hooks land in `internal/finalize/hooks/`: `baseline_cleanup`, `express_persist`, `note_acceptance`, `failure_context_reset`, `cleanup_resolved`, `resolve_notes`. The two corresponding case arms in `lib/finalize_shim.sh:70-110` remove. (4) The Go prompt engine (m15 — `internal/prompt/`) wires `HUMAN_NOTES_BLOCK` directly to `notes.Extract` — no more bash subprocess per render. The shim path through `lib/prompts.sh` deletes for this variable. (5) The 14 `lib/notes*.sh` files delete. The bash callers in `tekhton-legacy.sh` (the `--human` mode CLI dispatch at ~line 1800, `add_human_note` callsites, `extract_unchecked_notes` call in legacy intake) route through `tekhton note ...` directly. (6) A parity gate diffs `HUMAN_NOTES.md` round-trips (add → list → done → cleanup) and `HUMAN_NOTES_BLOCK` template output between a captured bash baseline and the m24 Go subsystem across four scenarios: greenfield (empty notes), populated-three-tags, post-completion-sweep, V2-format-migration. (7) `VERSION` bumps to `4.24.0` on close. |
| **Depends on** | m23 |
| **Files changed** | `internal/notes/`, `internal/finalize/hooks/`, `internal/prompt/render.go`, `cmd/tekhton/note.go`, `lib/finalize_shim.sh`, `lib/prompts.sh`, `tekhton-legacy.sh`, `tests/test_notes_parity.sh`, `docs/v4-phase5-stub.md`, fourteen deletions under `lib/notes*.sh`. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m21 | Finalize orchestrator in Go; six note-touching hooks routed through bash-shim dispatcher. |
| m22 | Preflight ported in full; "one subsystem, one milestone" pattern proven. |
| m23 | TUI writers ported; `internal/atomicfile/` candidate (or its in-place equivalent) seeded for m24's `HUMAN_NOTES.md` writes. |
| **m24** | **Notes subsystem ported in full; six finalize-shim arms remove; `tekhton note` joins the visible Cobra surface; prompt engine wires `HUMAN_NOTES_BLOCK` natively.** |

---

## Design

### Sequencing note

m24 is the first milestone with a multi-thousand-LOC port surface. m22 was 1501 LOC and produced 17 patch bumps in dogfooding. The m22 author explicitly avoided combining preflight + TUI because the combined ~2600 LOC was "too thrashy." m24 at 2188 LOC sits below that ceiling but only because m24 was *split* from the m22 Seeds Forward proposal of "notes + drift + clarify" (3799 LOC across 19 files). The split shows up in the m25 milestone, which inherits drift + clarify. Authoring m24 without that split would have violated the lesson m22 paid for; honor it.

m24 must land before m26 (dashboard emitters). Reason: the dashboard reads `HUMAN_NOTES.md` directly (`lib/dashboard_emitters.sh:523:emit_dashboard_notes`); if dashboard ports before notes, the dashboard Go code has to talk to bash for note parsing.

### Goal 1 — Three-state state machine in Go

Notes have three states encoded in markdown checkboxes:

| Checkbox | State | Meaning |
|----------|-------|---------|
| `[ ]` | `Pending` | Not started. |
| `[~]` | `Active` | In-scope for the current run (transient — set by `claim` API, cleared at run end). |
| `[x]` | `Done` | Completed. |

`lib/notes_core.sh:1-50` documents this. The Go port:

```go
// internal/notes/state.go
package notes

type State int

const (
    Pending State = iota
    Active            // [~] — transient, cleared on run finalize
    Done              // [x]
)

func (s State) Checkbox() string {
    switch s {
    case Active:
        return "[~]"
    case Done:
        return "[x]"
    default:
        return "[ ]"
    }
}

func ParseCheckbox(box string) (State, error) {
    switch box {
    case "[ ]":
        return Pending, nil
    case "[~]":
        return Active, nil
    case "[x]":
        return Done, nil
    default:
        return Pending, fmt.Errorf("notes: unknown checkbox %q", box)
    }
}
```

The state machine itself is the existing `claim` (Pending → Active), `resolve` (Active → Done), `unclaim` (Active → Pending), `reopen` (Done → Pending) verbs from `lib/notes_core.sh`. Each is a method on `*Note`.

### Goal 2 — `HUMAN_NOTES.md` parser + writer

The current bash parser is a 60-line `awk`-and-`sed` chain in `lib/notes.sh`. The Go port lives in `internal/notes/parser.go` and uses a small line-based scanner:

```go
type Note struct {
    ID       string      // M001, M002, ... (assigned by parser if missing)
    Tag      string      // BUG | FEAT | POLISH | TEST | UI | … (tag registry)
    State    State
    Title    string
    Body     []string    // subsequent indented lines
    LineNum  int         // for round-trip fidelity
}

func Parse(r io.Reader) (*Document, error)
func (d *Document) Write(w io.Writer) error  // round-trips with the same byte layout
```

Round-trip fidelity is load-bearing: `tekhton note done M042` must produce the same byte sequence as the bash `mark_note_done M042` did, modulo the single checkbox change. The parity gate (Goal 6) asserts this.

The tag registry (BUG, FEAT, POLISH, TEST, UI, …) is read from `lib/notes_core.sh:60-100` — port as a `var DefaultTags = []string{...}` slice, no behavior change. Custom tags can be added via `pipeline.conf` (existing key, already in `internal/config/`).

### Goal 3 — `HUMAN_NOTES_BLOCK` native rendering

Today's flow:

1. `internal/prompt/render.go` needs `HUMAN_NOTES_BLOCK`.
2. It execs `lib/prompts.sh` which calls `extract_unchecked_notes` from `lib/notes.sh`.
3. The bash function reads `HUMAN_NOTES.md`, filters by tag if `HUMAN_NOTES_TAG` is set, and prints the unchecked items.
4. The output is captured and substituted.

Per render. Every prompt render. The prompt engine is in Go (m15) — there is no reason to subshell to bash for this any more. m24 replaces step 2-3 with a direct Go call:

```go
// internal/prompt/render.go
import "github.com/geoffgodwin/tekhton/internal/notes"

func (r *Renderer) renderHumanNotesBlock(ctx context.Context) (string, error) {
    doc, err := notes.LoadDocument(r.ProjectDir)
    if err != nil {
        if errors.Is(err, notes.ErrNotFound) {
            return "", nil // matches bash semantics for missing file
        }
        return "", err
    }
    return notes.Extract(doc, notes.ExtractOpts{
        OnlyState: notes.Pending,
        FilterTag: r.HumanNotesTag,
    }), nil
}
```

The bash `extract_unchecked_notes` function deletes. The bash shim in `lib/prompts.sh` that invoked it deletes. Other template variables that route through `lib/prompts.sh` continue to do so until later milestones port them.

### Goal 4 — `tekhton note` CLI surface

This is the first Phase 5 subcommand authored as **visible** (not `Hidden`) because end users invoke `tekhton note add ...` directly. Mirror the m22 `tekhton preflight` shape, but flip `Hidden: false`.

Subcommand surface (matches the existing bash `tekhton note` dispatch in `lib/notes_cli.sh:add_human_note` + `list_human_notes_cli`):

```
tekhton note add      [--tag TAG] [--title TEXT] [BODY...]
tekhton note list     [--tag TAG] [--state STATE] [--format md|json]
tekhton note done     <ID>
tekhton note reopen   <ID>
tekhton note claim    <ID>
tekhton note unclaim  <ID>
tekhton note triage   [--auto] [--threshold N]
tekhton note migrate                # V2→V3 format upgrade (idempotent)
tekhton note rollback <SNAPSHOT_ID> # restore from .claude/notes_snapshots/
tekhton note resolve  [--pattern P] # bulk-resolve by tag/regex
```

`list --format json` emits a `tekhton.notes.list.v1` envelope (versioned per `DESIGN_v4.md` §Output Format Conventions). The default `--format md` mirrors today's bash list output byte-for-byte for shell-pipeline compatibility.

### Goal 5 — Six finalize hooks port

Each of the six bash hooks in the two finalize-shim case arms gets a pure-Go body under `internal/finalize/hooks/`:

| Hook | Source bash | What it does |
|------|-------------|-------------|
| `baseline_cleanup` | `_hook_baseline_cleanup` in `notes_cleanup.sh` | Clears `[~]` Active markers from notes that were claimed but the stage failed before resolution. |
| `express_persist` | `_hook_express_persist` in `notes_cleanup.sh` | Persists express-mode note resolutions to disk. |
| `note_acceptance` | `_hook_note_acceptance` in `notes_acceptance.sh` | Applies tag-specific acceptance heuristics — e.g. a BUG note resolves only if the test that was failing now passes. |
| `failure_context_reset` | `_hook_failure_context_reset` in `notes_cleanup.sh` | On run failure, resets `[~]` → `[ ]` so the next run sees a clean slate. |
| `cleanup_resolved` | `_hook_cleanup_resolved` in `notes_cleanup.sh` | Removes notes that have been `Done` for more than the retention window. |
| `resolve_notes` | `_hook_resolve_notes` in `notes_cleanup.sh` | Detects in-scope notes that the run completed and bumps their state to `Done`. |

`internal/finalize/orchestrator.go` swaps the six entries from "shim dispatch" to "Go body" — the registration order in `lib/finalize.sh:218-243` is the authority, and the order-mismatch test must be updated to expect the new Go bodies.

The `_hook_baseline_cleanup` case arm in `finalize_shim.sh:70` also lists `_hook_failure_context_reset` — these two hooks ship in the same `lib/failure_context.sh` file. Failure-context state itself is touched by both notes and drift; m24 ports the notes-side state-write only, leaving `lib/failure_context.sh::reset_failure_context_state` for m25 (drift) to delete or relocate. The Go hook calls `notes.ClearActive(...)` and does not touch failure-context state directly.

### Goal 6 — Parity gate

`tests/test_notes_parity.sh` runs four captured scenarios:

1. **Greenfield:** empty `HUMAN_NOTES.md`. Expected: zero-output `HUMAN_NOTES_BLOCK`; `tekhton note list` shows zero rows; finalize hooks all no-op.
2. **Populated-three-tags:** seeded `HUMAN_NOTES.md` with three BUG, two FEAT, one POLISH note in mixed states. Expected: `HUMAN_NOTES_BLOCK` byte-identical between bash baseline and Go; `note list --format md` byte-identical; `note done M003` produces byte-identical file diff.
3. **Post-completion-sweep:** simulate a run that resolved two of the six notes. Expected: `_hook_resolve_notes` flips both to `[x]`; `_hook_baseline_cleanup` clears any leftover `[~]`; `_hook_express_persist` persists; the final file matches the captured bash baseline.
4. **V2-format-migration:** seed a V2-format `HUMAN_NOTES.md` (no ID column). Expected: `tekhton note migrate` upgrades in place; downstream operations work on the new file; a backup is written to `.claude/notes_snapshots/<timestamp>/`.

Each scenario asserts byte-identical output via `tests/lib/parity.sh` (extracted in m23).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/notes/state.go` | Create | Three-state state machine + tag registry. |
| `internal/notes/parser.go` | Create | `HUMAN_NOTES.md` parser + writer with round-trip fidelity. |
| `internal/notes/extract.go` | Create | `HUMAN_NOTES_BLOCK` builder + filter (ports `extract_unchecked_notes`). |
| `internal/notes/acceptance.go` | Create | Tag-specific milestone acceptance heuristics (ports `notes_acceptance.sh`). |
| `internal/notes/cleanup.go` | Create | Post-success sweep + active-marker cleanup (ports `notes_cleanup.sh`). |
| `internal/notes/triage.go` | Create | Heuristic scoring + agent escalation (ports `notes_triage*.sh`). |
| `internal/notes/migrate.go` | Create | V2→V3 format migrator (ports `notes_migrate.sh`). |
| `internal/notes/rollback.go` | Create | Snapshot rollback (ports `notes_rollback.sh`). |
| `internal/notes/single.go` | Create | `--human` mode single-note utilities (ports `notes_single.sh`). |
| `internal/notes/*_test.go` | Create | Per-file unit tests + round-trip fixtures under `internal/notes/testdata/`. |
| `cmd/tekhton/note.go` | Create | `tekhton note` Cobra subcommand tree (visible, not Hidden). |
| `cmd/tekhton/note_test.go` | Create | CLI smoke + flag wiring. |
| `internal/finalize/hooks/baseline_cleanup.go` | Create | `_hook_baseline_cleanup` Go body. |
| `internal/finalize/hooks/express_persist.go` | Create | `_hook_express_persist` Go body. |
| `internal/finalize/hooks/note_acceptance.go` | Create | `_hook_note_acceptance` Go body. |
| `internal/finalize/hooks/failure_context_reset.go` | Create | `_hook_failure_context_reset` Go body (notes-side only — drift-side ports in m25). |
| `internal/finalize/hooks/cleanup_resolved.go` | Create | `_hook_cleanup_resolved` Go body. |
| `internal/finalize/hooks/resolve_notes.go` | Create | `_hook_resolve_notes` Go body. |
| `internal/finalize/orchestrator.go` | Modify | Wire six hooks in-process; remove from `shim.go` dispatch list. |
| `internal/finalize/orchestrator_test.go` | Modify | Update expected hook-order test list to include the six new Go bodies. |
| `internal/prompt/render.go` | Modify | `HUMAN_NOTES_BLOCK` calls `notes.Extract` directly; no bash subshell. |
| `internal/prompt/render_test.go` | Modify | Test `HUMAN_NOTES_BLOCK` rendering against an in-process `notes.Document`. |
| `lib/finalize_shim.sh` | Modify | Remove the two case arms covering the six ported hooks. |
| `lib/prompts.sh` | Modify | Remove the `extract_unchecked_notes` call path; the Go prompt engine is the only caller now. |
| `tekhton-legacy.sh` | Modify | Replace `add_human_note` + `extract_unchecked_notes` + V2 migrate fallback callsites with `tekhton note ...`. |
| `tests/test_notes_parity.sh` | Create | Four-scenario byte-identical parity gate. |
| `tests/lib/parity.sh` | Modify | Add notes-scenario helpers if the m23 driver needs minor extension. |
| `lib/notes.sh` | Delete | Ported to `internal/notes/extract.go` + `state.go`. |
| `lib/notes_acceptance.sh` | Delete | Ported to `internal/notes/acceptance.go`. |
| `lib/notes_acceptance_helpers.sh` | Delete | Ported to `internal/notes/acceptance.go`. |
| `lib/notes_cleanup.sh` | Delete | Ported to `internal/notes/cleanup.go`. |
| `lib/notes_cli.sh` | Delete | Ported to `cmd/tekhton/note.go` + `internal/notes/cli.go`. |
| `lib/notes_cli_write.sh` | Delete | Ported to `cmd/tekhton/note.go`. |
| `lib/notes_core.sh` | Delete | Ported to `internal/notes/state.go` + `parser.go`. |
| `lib/notes_core_normalize.sh` | Delete | Ported to `internal/notes/parser.go` (normalize logic). |
| `lib/notes_migrate.sh` | Delete | Ported to `internal/notes/migrate.go`. |
| `lib/notes_rollback.sh` | Delete | Ported to `internal/notes/rollback.go`. |
| `lib/notes_single.sh` | Delete | Ported to `internal/notes/single.go`. |
| `lib/notes_triage.sh` | Delete | Ported to `internal/notes/triage.go`. |
| `lib/notes_triage_flow.sh` | Delete | Ported to `internal/notes/triage.go`. |
| `lib/notes_triage_report.sh` | Delete | Ported to `internal/notes/triage.go`. |
| `docs/v4-phase5-stub.md` | Modify | Update row 5 status to "done (m24)"; update LOC budget table with the post-m24 count. |

---

## Acceptance Criteria

- [ ] `internal/notes/state.go` declares `State` enum with exactly three values (`Pending`, `Active`, `Done`); `ParseCheckbox` and `State.Checkbox()` round-trip the three `[ ]` / `[~]` / `[x]` strings, asserted by a table-driven test.
- [ ] `internal/notes/parser.go::Parse` followed by `Document.Write` round-trips a fixture `HUMAN_NOTES.md` byte-for-byte. The fixture lives at `internal/notes/testdata/golden/round_trip.md` and covers all six tag types, all three states, and at least one multi-line body.
- [ ] `internal/notes/extract.go::Extract` produces byte-identical output to the bash `extract_unchecked_notes` for the populated-three-tags scenario — verified by the parity gate.
- [ ] `internal/prompt/render.go` no longer execs `lib/prompts.sh` for `HUMAN_NOTES_BLOCK` — verified by `grep -n 'extract_unchecked_notes\|lib/prompts.sh' internal/prompt/render.go` returning zero matches and `internal/prompt/render_test.go` exercising the in-process path.
- [ ] All 14 `lib/notes*.sh` files are deleted from the repo; `find lib -name 'notes*.sh'` returns nothing.
- [ ] No remaining bash file sources any `notes*.sh` — `grep -rn 'source.*lib/notes' lib stages tekhton-legacy.sh` returns zero matches.
- [ ] No remaining bash file calls notes functions directly — `grep -rnE '(add_human_note|extract_unchecked_notes|mark_note_done|claim_note|resolve_note|run_notes_triage|migrate_notes_v2)\b' lib stages tekhton-legacy.sh` returns zero matches (occurrences inside `cmd/tekhton/note.go` and docs are fine).
- [ ] Six pure-Go finalize hook files exist under `internal/finalize/hooks/`: `baseline_cleanup.go`, `express_persist.go`, `note_acceptance.go`, `failure_context_reset.go`, `cleanup_resolved.go`, `resolve_notes.go`. Each is registered in `internal/finalize/orchestrator.go` and has a passing unit test.
- [ ] `lib/finalize_shim.sh` no longer matches the six hook names in any case arm — `grep -nE '_hook_(baseline_cleanup|express_persist|note_acceptance|failure_context_reset|cleanup_resolved|resolve_notes)' lib/finalize_shim.sh` returns zero matches inside case statements.
- [ ] `tekhton note --help` lists at least nine subcommands (`add`, `list`, `done`, `reopen`, `claim`, `unclaim`, `triage`, `migrate`, `rollback`, `resolve`); the command is **visible** in `tekhton --help` (no `Hidden: true`).
- [ ] `tekhton note list --format json` produces a `tekhton.notes.list.v1` envelope — verified by `tekhton note list --format json | jq -e '.proto == "tekhton.notes.list.v1"'` against a populated fixture project.
- [ ] `tests/test_notes_parity.sh` exits 0 across all four documented scenarios (greenfield, populated-three-tags, post-completion-sweep, V2-format-migration).
- [ ] `make dogfood` exits 0 (self-host parity matrix still green).
- [ ] `bash scripts/wedge-audit.sh` exits 0 (audit extended to forbid re-introduction of `add_human_note`, `extract_unchecked_notes`, etc. as bash function definitions with non-trivial bodies).
- [ ] `go test ./internal/notes/... ./internal/prompt/... ./internal/finalize/... ./cmd/tekhton/...` passes.
- [ ] `bash tests/run_tests.sh` reports zero new failures vs the m23 close baseline. `test_notes_*.sh` test files (there are several) are either: (a) updated to drive `tekhton note ...`, or (b) skip-stubbed with a one-line pointer to the Go test that replaces them. Option (a) is preferred — skip-stubbing is a quality regression.
- [ ] `docs/v4-phase5-stub.md` LOC budget table shows the new post-m24 count and the row "Notes + variants" marked "done (m24 — fourteen files deleted, six finalize-shim arms removed, `tekhton note` joins the visible CLI surface)".
- [ ] `VERSION` reads `4.24.0` on milestone close.
- [ ] `.claude/milestones/MANIFEST.cfg` has the row `m24|Notes Port|done|m23|m24-notes-port.md|phase5`.
- [ ] The implementation run is itself driven by `tekhton run --milestone m24 --complete`.

## Watch For

- **m24 is the largest single port surface so far (2188 LOC, 14 files).** The m22 dogfooding cycle produced 17 patch bumps for 1501 LOC; expect 25-35 patch bumps for m24 on a linear extrapolation, more if the round-trip fidelity work surfaces parser edge cases. If the bump count crosses 40, pause and audit — the milestone may need to split (notes-state + notes-CLI as m24, notes-acceptance + notes-triage as a new m24b). Aborting and re-authoring mid-flight is correct response, not a failure.
- **Round-trip fidelity is the hardest invariant.** `HUMAN_NOTES.md` is a markdown file users edit by hand. Whitespace, trailing newlines, list-item indentation, blank-line-between-tag-sections — every byte the bash parser preserved is a byte users learned to expect. The parity-gate scenarios cover the common cases; the production surface will surface long-tail layouts. Fix issues forward; do not weaken the parity gate.
- **The V2 migrator runs once per project, ever.** `lib/notes_migrate.sh` was last touched in V2 and has not been exercised in V3 for projects that already migrated. The Go port must preserve idempotency (running `tekhton note migrate` on a V3 file is a no-op) and must preserve the snapshot side effect (a backup lands in `.claude/notes_snapshots/<timestamp>/`). Test against a captured V2 fixture in `internal/notes/testdata/v2_format/`.
- **`failure_context_reset` is half-owned.** The bash file `lib/failure_context.sh` is also touched by the drift subsystem (m25). m24 ports the notes-side hook body to Go but leaves `lib/failure_context.sh` intact — m25 deletes it when drift ports. Do not delete `failure_context.sh` here, but do not let the m24 Go hook depend on its bash internals either.
- **The `tekhton note` CLI is the first visible Phase 5 subcommand.** Help text quality matters; this is user-facing surface. Each subcommand needs example invocations in `--help`, and `tekhton note --help` should land with a usage exemplar at the top. Compare against `git stash --help` for the bar.
- **Don't expand to drift in this milestone.** m22 Seeds Forward proposed "notes + drift + clarify" as a single milestone (3799 LOC). That's been split — drift + clarify is m25. Resist the temptation to port `lib/drift_artifacts.sh` opportunistically when the m21 closeout drift entry surfaces during testing — the router fix lands in m25's Go body, not as a bash patch here.

## Seeds Forward

- **m25 — Drift + clarify port:** Inherits the m21 closeout drift entry (non-blocking router misclassifying CI-failing tests). The router lives in `lib/drift_artifacts.sh` and the symptom shows up in note state transitions, but the fix belongs in the m25 Go port of drift, not as a bash patch on the dying subsystem. m25's `internal/drift/router.go` is where the fix lands. Also: m25 deletes `lib/failure_context.sh` after porting the drift-side reset to Go (m24 already ported the notes-side reset).
- **m26 — Dashboard emitters port:** `emit_dashboard_notes` in `lib/dashboard_emitters.sh:523` reads `HUMAN_NOTES.md` directly. After m24, the dashboard's bash emitter can switch to calling `tekhton note list --format json` and parsing the versioned envelope — fewer lines, no parser duplication. Even better: m26 ports the emitter to Go and consumes `internal/notes` directly.
- **Tag registry as a config-loader concern:** Custom tags currently extend `DEFAULT_NOTE_TAGS` via `pipeline.conf`. m16 already owns the config loader; m24's `internal/notes/state.go::Tags()` reads from `internal/config/Config.NoteTags`. No new config surface needs adding — wire it through.
- **`internal/atomicfile/` extraction trigger:** If m23's `internal/tui/state.go::SaveAtomic` and m24's `internal/notes/parser.go::Document.Write` both reach for the temp-file + os.Rename pattern, m24 promotes it to `internal/atomicfile/` as a shared helper. If only one of them needed it (or they need different ordering — e.g. notes needs a fsync), defer extraction to m26.
- **Visible vs Hidden subcommand precedent:** `tekhton note` joins the visible surface; `tekhton preflight`, `tekhton finalize`, `tekhton tui` remain Hidden. The rule of thumb forming: user-facing utilities are visible; internal seams that exist to support bash callers during the migration are Hidden. m25, m26 should classify their CLI surfaces on the same axis.
- **Dogfooding feedback loop:** Continue the patch-bump tracking. m24 is large; expect 25-35 patch bumps over the cycle. If a bump fixes a parity-gate failure, write the postmortem against the *parity scenario number*, not the symptom — e.g. "scenario 3 surfaced ordering issue: `_hook_resolve_notes` ran before `_hook_baseline_cleanup` in the new Go orchestrator, but bash ordered them reversed." That format makes the lesson reusable for m25-m26.
