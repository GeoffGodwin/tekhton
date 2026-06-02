<!-- milestone-meta
id: "34"
status: "split"
-->

# m34 — Docs and Cleanup Stage Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — first of six sequential stage-port milestones (m34-m39). Today every `stages/*.sh` file runs as a bash subprocess that the `BashAdapter` (`internal/stagerunner/adapter.go`) spawns: it sources `lib/common.sh`, the full `DefaultLibHelpers` list (60+ files), the per-stage `Helpers` slice, `lib/stage_envelope.sh`, then the stage script itself, then calls `run_stage_<name>`. The stages do all their templating, agent invocation, file IO, and result-envelope writing inside that bash subprocess. That model has carried us through Phase 4 — but every stage that stays bash blocks four things: in-process agent invocation (each stage costs a bash fork plus a `claude` exec instead of one shared supervisor), typed error propagation (stage failures arrive as strings parsed from JSON instead of Go sentinels), unit-testable stage logic (the stage scripts can only be exercised by spawning a real bash subprocess), and Windows-native support (the V5 target). Phase 5 closes this by porting every stage to a Go-native `internal/stages/<name>/` package and retiring the bash files. M34 starts the arc with the two smallest stages — `docs.sh` (93 LOC, optional, M75-lineage) and `cleanup.sh` (294 LOC, success-path-only, M70-lineage) — because they let us establish the pattern under low blast radius before the marquee stages (coder, review, tester) follow in M35-M39. |
| **Gap** | (1) `internal/stagerunner/adapter.go` has only one Adapter implementation (`BashAdapter`); `StageDef` describes a stage exclusively in bash terms (`Script string` + `Helpers []string` — both bash file paths). There is no seam for a Go-native stage. (2) `stages/docs.sh` (93 LOC) and `stages/cleanup.sh` (294 LOC) are bash; `lib/docs_agent.sh` (153 LOC, sourced via `StageDef.Helpers` for the docs stage) is its only helper. (3) `stages/cleanup.sh` is currently **dead bash code** — it calls four functions (`select_cleanup_batch`, `mark_note_resolved`, `mark_note_deferred`, `count_unresolved_notes`) that have no in-tree definition (m24 deleted `lib/notes_cleanup.sh` and never re-introduced them; `tests/test_cleanup_notes.sh:5` documents the gap). Running cleanup in production today fails with "command not found" the moment the trigger threshold is met. So the M34.2 port must both translate the stage and resurrect the four helpers as Go-native API on `internal/notes/`. (4) There is no parity test apparatus for stage-level output yet — m18 ships envelope-level tests but no per-stage byte-diff harness. |
| **m34 fills** | Two decimal children. **M34.1 — Docs stage port + Go-adapter pattern:** Birth the pattern. Add a `GoImpl func(context.Context, *proto.StageRequestV1) (*proto.StageResultV1, error)` field to `StageDef`. Introduce a `GoAdapter` (alongside `BashAdapter`) in `internal/stagerunner/` that dispatches to `GoImpl` when set. Update `DefaultStageDefs[StageDocs]` to wire `GoImpl: docs.RunStage` (and drop the `Helpers: ["lib/docs_agent.sh"]` entry). Create `internal/stages/docs/` package containing `RunStage`, `should_skip`, public-surface extraction, and template-variable preparation — all ported from `stages/docs.sh` + `lib/docs_agent.sh`. Delete both bash files. Add unit tests + a parity harness that diffs Go stage output against a frozen pre-m34 bash baseline. **M34.2 — Cleanup stage port (pattern dogfood):** Apply the established pattern to `stages/cleanup.sh`. Create `internal/stages/cleanup/` with `RunStage`, `_process_cleanup_results`, `_parse_cleanup_report`, `_resolve_cleanup_by_file_changes` ports. Resurrect `SelectCleanupBatch`, `MarkResolved`, `MarkDeferred`, `UnresolvedCount` as exported Go API on `internal/notes/cleanup.go` (functions that the deleted-in-m24 `lib/notes_cleanup.sh` owned, recovered from git history). Wire `DefaultStageDefs[StageCleanup].GoImpl = cleanup.RunStage`. Delete `stages/cleanup.sh`. M34.2 is the smaller of the two by design — once the pattern exists, applying it to a second stage should be a mostly mechanical translation that validates the pattern. M35-M39 inherit the same shape. |
| **Depends on** | m33 |
| **Files changed** | `internal/stagerunner/helpers.go` (modify — add `GoImpl` field to `StageDef`, wire `GoImpl` for docs + cleanup, drop `lib/docs_agent.sh` helper entry), `internal/stagerunner/adapter.go` (modify — add `GoAdapter` type + dispatch shim in `BashAdapter.Run` that delegates to `GoAdapter` when `GoImpl` is non-nil; OR a new `internal/stagerunner/go_adapter.go` file — see m34.1 design), `internal/stages/docs/` (new package, ~250 LOC), `internal/stages/cleanup/` (new package, ~400 LOC), `internal/notes/cleanup.go` (modify — add `SelectCleanupBatch`, `MarkResolved`, `MarkDeferred`, `UnresolvedCount`), `stages/docs.sh` (delete in m34.1), `lib/docs_agent.sh` (delete in m34.1), `stages/cleanup.sh` (delete in m34.2), `tests/test_stage_port_parity.sh` (create in m34.1 — harness extends in m34.2). |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m18 | Pipeline runner + stage adapter introduced (`BashAdapter` only); the `StageDef`/`DefaultStageDefs` map this milestone extends. |
| m24 | Notes port; `lib/notes_cleanup.sh` deleted but the four cleanup-stage helpers (`select_cleanup_batch`, `mark_note_resolved`, `mark_note_deferred`, `count_unresolved_notes`) never re-introduced — m34.2 closes that latent gap. |
| m27 | Bash env hardening — every stage script today is `set -euo pipefail` and audited; the Go port inherits a clean baseline of which env vars each stage reads. |
| m33 | Last currently-tracked milestone before m34 — dashboard parsers ported; no stage-level work touched. |
| **m34** | **Go-adapter stage pattern established + docs + cleanup ported; pattern documented for m35-m39.** |

---

## Design

### Sequencing note

The two children are **strictly ordered**: m34.2 cannot start until m34.1 lands the `StageDef.GoImpl` field and the `GoAdapter` dispatcher, because m34.2's whole job is to dogfood that pattern on a second stage. Collapsing them into one milestone has been considered and rejected — m34.1 alone is a pattern-design exercise that needs a discrete review-and-merge cycle so the shape is debated independently of whether the cleanup-stage port itself is correct. Each child runs its own `tekhton run --milestone m34.X --complete` cycle and ships its own LOC delete.

### Goal 1 — `StageDef.GoImpl` field + the `GoAdapter` dispatch seam

The current `StageDef` (`internal/stagerunner/helpers.go:11-14`) is bash-only:

```go
type StageDef struct {
    Script  string
    Helpers []string
}
```

M34.1 extends it (additive only — existing bash stages keep working unchanged):

```go
// StageImpl is the entry point signature every Go-native stage exports.
// Identical to internal/stagerunner.Adapter.Run but scoped to a single stage,
// so the GoAdapter can dispatch by stage name without import-cycling back to
// stagerunner.
type StageImpl func(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error)

type StageDef struct {
    // Script is the bash file path the BashAdapter sources. Empty when the
    // stage has fully ported to Go (GoImpl is non-nil).
    Script  string

    // Helpers are stage-specific lib/*.sh files the BashAdapter sources
    // beyond DefaultLibHelpers. Empty for ported stages.
    Helpers []string

    // GoImpl, when non-nil, is the Go-native entry point. The stagerunner
    // dispatch prefers GoImpl over Script; an entry with both set is a
    // configuration error (caught by helpers_test.go).
    GoImpl  StageImpl
}
```

The dispatch shim lives in `internal/stagerunner/adapter.go`. Two design options:

- **Option A (chosen):** Keep one `Adapter` interface, one `BashAdapter` struct. Inside `BashAdapter.Run`, before any bash-script work, check `def.GoImpl != nil` and delegate. The bash adapter functionally becomes a "stage dispatcher" — but the rename is a future M40 concern; m34 keeps the name to minimize churn.
- **Option B (rejected):** A separate `GoAdapter` struct + a top-level `Dispatch(req)` switcher. Costs one more layer of indirection and forces the pipeline runner (`internal/runner/`) to know about both adapters; the runner today knows only about `Adapter`.

The Option-A shim:

```go
func (a *BashAdapter) Run(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
    if req == nil {
        return nil, fmt.Errorf("%w: nil request", proto.ErrInvalidStageRequest)
    }
    if err := req.Validate(); err != nil {
        return nil, err
    }
    def, ok := a.stageDefFor(req.Stage)
    if !ok {
        return nil, fmt.Errorf("%w: %q", ErrUnknownStage, req.Stage)
    }

    // NEW (m34.1): Go-native dispatch wedge.
    if def.GoImpl != nil {
        return a.runGo(ctx, req, def)
    }

    // (existing bash path follows unchanged)
    ...
}

func (a *BashAdapter) runGo(ctx context.Context, req *proto.StageRequestV1, def StageDef) (*proto.StageResultV1, error) {
    now := a.Now
    if now == nil { now = time.Now }
    start := now()
    res, err := def.GoImpl(ctx, req)
    if res != nil && res.DurationSec == 0 {
        res.DurationSec = int(now().Sub(start).Seconds())
    }
    if res != nil { res.EnsureProto() }
    return res, err
}
```

Result: every stage with `GoImpl == nil` keeps running through the bash path. Every stage with `GoImpl != nil` skips the bash sourcing chain entirely and runs in-process — no subprocess, no env composition, no `lib/*.sh` sources.

### Goal 2 — `internal/stages/<name>/` package shape

M34.1 establishes a per-stage package layout that m35-m39 will copy:

```
internal/stages/<name>/
├── stage.go              # RunStage entry point + helper orchestrator
├── stage_test.go         # Per-function tests + table-driven happy / skip / gate paths
├── prepare.go            # _<name>_prepare_template_vars and related env wiring
├── prepare_test.go
├── (per-stage extras)    # e.g. internal/stages/docs/skip.go for docs_agent_should_skip
└── testdata/
    ├── fixtures/         # Captured pre-port baselines for parity diffs
    └── golden/           # Expected outputs
```

Each stage exports exactly one symbol consumed by `stagerunner`:

```go
// internal/stages/<name>/stage.go
package <name>

func RunStage(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error)
```

Stages consume three Go packages for the work bash today does inline:

| Bash today | Go replacement | Notes |
|------------|----------------|-------|
| `render_prompt "<name>"` | `prompt.Render(promptsDir, "<name>", vars)` | promptsDir resolved from `TEKHTON_HOME` env. |
| `run_agent "Label" "model" turns prompt log tools` | `supervisor.New(causal, state).Run(ctx, agentReq)` | Supervisor seams are nil-safe; M34 wires them from request context. |
| `stage_envelope_install_all` + the bash tail block | Direct construction of `*proto.StageResultV1` returned from `RunStage` | No envelope-write-to-file dance — the GoAdapter receives the result struct directly. |
| `log "..."` / `warn "..."` / `success "..."` | `log.Info` / `log.Warn` / `log.Success` from a shared `internal/stages/staglog` helper (a thin wrapper around the existing `internal/runner/output.go` writer); m34.1 introduces if missing | The bash colored-output API needs a Go analogue; the docs stage's emit cadence is the spec. |

### Goal 3 — Per-stage I/O contract (no envelope file in Go path)

The bash path writes `TEKHTON_STAGE_RESULT_FILE`; the Go path returns `*StageResultV1` directly. This is intentional — the result file existed only because the bash subprocess had no other way to hand structured data back to the Go parent. Go stages don't have that gap, so they skip the file altogether. The `proto.StageRequestV1.ResultFile` field stays populated (callers may still want a result file for audit), but Go stages do not consult it. If a Go stage needs to persist a result file for downstream-consumer compatibility, it writes one explicitly via `os.WriteFile` and the result envelope JSON-marshal helpers — but neither m34 stage needs this.

### Goal 4 — Parity-gate strategy (frozen pre-m34 baselines)

The two stages have different parity surfaces. Docs is heuristic (LLM-driven, outputs a single best-effort agent run); cleanup is more structured (mutates `${NON_BLOCKING_LOG_FILE}` markers). The shared harness must handle both:

| Stage | Parity-diffable artifact | Normalization |
|-------|--------------------------|---------------|
| docs | `StageResultV1` envelope (verdict, exit_reason, agent_calls, duration_sec, files_touched) + the `${DOCS_AGENT_REPORT_FILE}` body when the agent ran | Timestamps stripped from report; `duration_sec` normalized to 0 in golden compare. |
| cleanup | `StageResultV1` envelope + the diff against `${NON_BLOCKING_LOG_FILE}` (which markers were toggled `[ ]` → `[x]` and `[ ]` → `[DEFERRED]`) | None — the marker diff is deterministic. |

The harness lives at `tests/test_stage_port_parity.sh`. M34.1 creates it with the docs-stage scenarios; M34.2 extends it with cleanup scenarios. m35-m39 each add their stage's scenarios as they port.

Baselines are captured **before** any Go work starts in each child milestone, under git tag `v4.{n}.99-stage-baseline-<stage>` so the bash output is recoverable even after the bash file deletes.

### Goal 5 — Bash-coexistence guarantee (the central watch-for)

During and after m34, the following must remain true:

1. **`BashAdapter.Run` continues to source the full lib/*.sh chain** for every stage whose `GoImpl` is nil — i.e. intake, coder, security, review, tester. None of those stages port in m34; they all stay bash.
2. **`DefaultStageDefs` retains its bash entries** for every un-ported stage. The docs and cleanup entries change shape: their `Script` field becomes empty (or stays populated but gets ignored — design call below) and their `GoImpl` field gets wired.
3. **`DefaultLibHelpers` does not shrink.** Removing items from it would break the bash stages that still depend on the sourced functions.
4. **`lib/docs_agent.sh` (deleted in m34.1) must not appear anywhere in `DefaultLibHelpers`** — verified by absence; it was only referenced from the docs stage's `Helpers` slice, which the m34.1 patch drops.

**Design call on the `Script` field for ported stages:** keep it set to the (now-deleted) path. Rationale: a future audit can `grep` `Script:` entries against `find stages -name "*.sh"` and the missing-file delta tells the operator which stages have ported. Setting `Script: ""` would erase that signal. The dispatcher already prefers `GoImpl`, so the never-resolved path doesn't matter at runtime.

### Goal 6 — Stage-port pattern documentation (seeds m35-m39)

M34.1 lands a short ADR-style note at `docs/go-migration.md` (append-only section "Stage-Port Pattern (m34)") that documents:

- The `StageDef.GoImpl` field and dispatch precedence.
- The per-stage `internal/stages/<name>/` layout.
- The `prompt.Render` / `supervisor.Run` / direct-return contract.
- The parity-baseline-capture protocol.
- The bash-coexistence guarantees.

This is what m35-m39 will reference rather than re-deriving the design each time. The pattern doc is part of m34.1's deliverables, not the parent's.

### Goal 7 — LOC delete accounting

| Milestone | Bash deleted | Go added (approx) | Net |
|-----------|--------------|-------------------|-----|
| m34.1 | `stages/docs.sh` (93) + `lib/docs_agent.sh` (153) = **246 LOC** | `internal/stages/docs/` (~250) + `internal/stagerunner` deltas (~40) + tests (~200) | +244 |
| m34.2 | `stages/cleanup.sh` (294) = **294 LOC** | `internal/stages/cleanup/` (~400) + `internal/notes/cleanup.go` additions (~120) + tests (~250) | +476 |
| **m34 total** | **540 LOC bash deleted** | ~1,260 LOC Go | Net +720 LOC — expected for the first child of an arc that births a pattern. |

The Go LOC overhead is highest in m34.1 because the pattern itself (GoAdapter dispatch, parity harness, pattern doc) is one-time cost. M35+ Go-to-bash ratios will be closer to 1.3x.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `.claude/milestones/m34.1-docs-stage-and-go-adapter.md` | Create | Child milestone — docs stage port + `StageDef.GoImpl` + `GoAdapter` pattern + parity harness + pattern doc. |
| `.claude/milestones/m34.2-cleanup-stage-port.md` | Create | Child milestone — cleanup stage port using the m34.1 pattern + resurrects `internal/notes/` cleanup helpers. |
| `.claude/milestones/MANIFEST.cfg` | Modify (by human at review pass) | Add three rows for m34 / m34.1 / m34.2. Not authored by this milestone — the human owns it. |

---

## Acceptance Criteria

- [ ] Both child milestone files (`m34.1-docs-stage-and-go-adapter.md`, `m34.2-cleanup-stage-port.md`) exist under `.claude/milestones/` and pass the m85 acceptance-criteria linter (`bash lib/milestone_acceptance_lint.sh .claude/milestones/m34.1-docs-stage-and-go-adapter.md` exits 0; same for m34.2).
- [ ] Each child's `Depends on` row matches the corresponding `depends_on` column in `MANIFEST.cfg` (m34.1 depends on m33; m34.2 depends on m34.1).
- [ ] The parent's status in `MANIFEST.cfg` is `split`; the runtime treats split-status parents as descriptive-only and does not schedule them for execution.
- [ ] No Go code under `internal/stages/` or `internal/stagerunner/` is modified by this parent milestone — all code-level changes live in the children.
- [ ] No bash files under `stages/` or `lib/` are deleted by this parent milestone — deletions live in m34.1 (`stages/docs.sh`, `lib/docs_agent.sh`) and m34.2 (`stages/cleanup.sh`).
- [ ] `VERSION` is not bumped at the parent level — the bumps live in m34.1 (`4.34.0`) and m34.2 (`4.34.1` or higher depending on patch-bump count during dogfooding).
- [ ] The Go-adapter pattern (`StageDef.GoImpl` field + dispatch precedence + per-stage package layout + `prompt.Render`/`supervisor.Run`/direct-return contract) is documented in m34.1's Design section in enough detail that m35 can copy the shape without re-deriving it.

## Watch For

- **`BashAdapter` must continue to dispatch every un-ported stage correctly throughout m34.** Intake, coder, security, review, tester all stay bash; their stage scripts source `DefaultLibHelpers` + per-stage `Helpers` + `lib/stage_envelope.sh` exactly as they do today. Any regression in the bash dispatch path during m34.1 (e.g. accidentally short-circuiting on a nil `GoImpl` check that returns the wrong sentinel) breaks five production stages. The first acceptance test in m34.1 is a smoke run of `intake` through the modified `BashAdapter`.
- **The docs stage is gated by `DOCS_AGENT_ENABLED=true`.** Production today runs with this flag unset, so the docs-stage port is exercised primarily by unit tests and an opt-in dogfood run; the regular pipeline never touches it. M34.1 must include at least one integration test that sets `DOCS_AGENT_ENABLED=true` and runs the Go stage end-to-end against a fixture project, or the port will be tested only at the function-call layer.
- **The cleanup stage runs only on the success-path finalize.** It triggers when `CLEANUP_ENABLED=true` AND the unresolved-notes count exceeds `CLEANUP_TRIGGER_THRESHOLD` (default 5). Test coverage in m34.2 must exercise both the no-trigger path (returns early with `verdict=skip`) and the triggered path (selects batch → invokes agent → runs build gate → processes results).
- **`stages/cleanup.sh` is broken bash code today.** The four functions it calls (`select_cleanup_batch`, `mark_note_resolved`, `mark_note_deferred`, `count_unresolved_notes`) have no in-tree definition (lib/notes_cleanup.sh was deleted in m24, never restored). Production runs that try to cleanup hit "command not found" the moment the trigger threshold is crossed. M34.2 cannot port the stage in isolation — it must also add the four missing helpers as exported Go API on `internal/notes/cleanup.go`. Source of truth for the original semantics: `git log --all -- lib/notes_cleanup.sh` (find the deletion commit, read the pre-delete blob).
- **`StageDef.Helpers: ["lib/docs_agent.sh"]` must be removed from `DefaultStageDefs[StageDocs]` in m34.1.** If the helper-source list still references the deleted file, the BashAdapter would crash when sourcing any docs-stage call — and during m34.1, the dispatcher prefers `GoImpl`, so the bash path is never taken; but if a test or operator forces the bash path (e.g. by clearing `GoImpl` for debugging), it would crash. Drop the entry alongside the file delete.
- **Decimal split is non-negotiable.** Collapsing m34.1 and m34.2 into a single milestone has been considered. Rejected because m34.1 is a pattern-design milestone (one-time cost: GoAdapter, parity harness, docs/go-migration.md ADR) and m34.2 is a pattern-validation milestone (mechanical translation that proves the pattern works for a second stage). Separating them lets m34.1's design be reviewed independently of whether the cleanup-stage port is correct, and produces a usable "single-stage pattern" artifact even if m34.2 surfaces a redesign-needing bug.

## Seeds Forward

- **m35-m39 inherit the `StageDef.GoImpl` + `GoAdapter` pattern established here.** The five subsequent stage-port milestones (intake, coder, security, review, tester — sequencing TBD per arc planning) each consist of: create `internal/stages/<name>/` package, wire `DefaultStageDefs[<name>].GoImpl = <name>.RunStage`, drop the entry's `Helpers` slice, delete the bash file, extend `tests/test_stage_port_parity.sh` with new scenarios. The pattern itself does not re-design; only the per-stage logic translates.
- **`tests/test_stage_port_parity.sh` becomes the shared parity harness for the whole stage-port arc.** Each subsequent stage milestone extends it with scenarios; the harness's normalization rules (timestamps stripped, durations zeroed, file-path placeholders) port forward unchanged.
- **`internal/stages/staglog` (or whatever colored-output helper m34.1 introduces) is shared by m35-m39.** The bash `log`/`warn`/`success` API is what stage scripts use; the Go analogue lands once in m34.1 and m35+ reuse.
- **`internal/notes/` cleanup-helper API (resurrected in m34.2) is operator-facing.** Future per-project triage policy hooks land on `SelectCleanupBatch`'s options struct.
- **The `BashAdapter`-keeps-its-name design call is technical debt by intent.** Once the last bash stage ports (post-m39), an m40 cleanup milestone renames `BashAdapter` → `StageDispatcher` (or similar) and removes the now-dead bash-sourcing scaffolding. m34's choice to leave the name in place is documented so that future renamer doesn't have to re-derive the rationale.
- **`docs/go-migration.md` Stage-Port Pattern ADR (m34.1) becomes the single reference doc for the arc.** When m35 starts, the implementer reads this section instead of re-reading m34.1's milestone file. Keeps each per-stage milestone shorter.
