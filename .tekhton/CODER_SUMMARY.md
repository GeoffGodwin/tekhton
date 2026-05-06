# Coder Summary — m11 Phase 3 Re-evaluation Gate

## Status: COMPLETE

## What Was Implemented

m11 is a decision milestone — produces no runtime code change. Deliverables:

### 1. The Path B spike

- **Branch:** `theseus/m11-pathb-spike` (commit `612281a`).
- **Worktree:** `/tmp/tekhton-spike` (preserved during the 30-day reversal
  window).
- **Files:** `cmd/tekhton/run.go` (272 lines, NEW), `cmd/tekhton/main.go`
  (+1 line — `cmd.AddCommand(newRunCmd())`).
- **Status:** compiles clean, vets clean, all Go tests pass; smoke test
  `./tekhton run --stage intake --task "test task" --dry-run` produces a
  6567-byte rendered prompt and a valid `agent.request.v1` envelope.
- **Time-box:** ~3 hours of agent time, well under the 1-day cap.
- **What it shows:** the supervisor seam is clean — `supervisor.New(nil,
  nil)` + `.Retry(ctx, req, supervisor.DefaultPolicy())` is the same shape
  `lib/agent.sh` invokes today, but in-process. Validates DESIGN_v4's
  Phase 4 prediction that orchestrate's port collapses 2-hop to 1-hop.
- **What it stubs (the friction data):** prompt engine (~150 LOC port
  needed), verdict parsing (~150 LOC), 7 dependency subsystems for
  intake's bash stage (notes, health, indexer, project index,
  causality query, run memory, UI detection). Spike ports 1 of intake's
  ~12 dependencies (state, already wedged in m03).

### 2. The decision document

- **File:** `docs/v4-phase-3-decision.md` (366 lines).
- **All 7 required sections present:** §1 Inputs, §2 Path A
  characterization, §3 Path B characterization, §4 Trade-off matrix,
  §5 Decision, §6 Trigger to revisit, §7 Reversal window. Plus an
  Appendix with spike branch metadata.
- **Decision:** Path A — Ship of Theseus continues. Phase 4 begins with
  `lib/orchestrate.sh` as the next wedge.
- **Reversal window:** 30 days (until 2026-06-05). Within window:
  reversal recorded by amending §5 + authoring
  `docs/v4-phase-3-decision-amendment.md`. After: requires a new design
  milestone.
- **Trigger conditions to revisit:** wedge size blowout (>5000 LOC or
  >200% turn budget), repeated seam friction (3+ revisions),
  bash-side divergence (2:1 patch outpace), test infrastructure cost
  (>15min CI), contributor friction (>2 review comments per quarter).

### 3. Phase 3 section in `docs/go-migration.md`

- **Length:** 22 lines (≤ 30-line cap from milestone Watch For met).
- **Content:** decision sentence + link to the full decision doc + spike
  branch reference + reversal-window date.
- **Phase 4 entry checklist** added (5 items: decision doc committed,
  drafts committed in batch, Phase 3 checklist 5×green, self-host
  passing, wedge audit clean).

### 4. Phase 4 milestone drafts (m12-m17 first batch)

Authored under `.tekhton/m11-drafts/` per milestone spec ("NOT committed
in m11 — produced as artifacts; a follow-up milestone-batch commit lands
them after review"). Six drafts covering the near-term horizon, each
following the canonical `MILESTONE_TEMPLATE.md` format:

| File | Wedge | Lines |
|------|-------|------:|
| `m12-orchestrate-loop-wedge.md` | `lib/orchestrate.sh` → `internal/orchestrate` | 109 |
| `m13-manifest-parser-wedge.md` | `lib/milestone_dag_io.sh` → `internal/manifest` | 99 |
| `m14-milestone-dag-wedge.md` | `lib/milestone_dag*.sh` → `internal/dag` | 105 |
| `m15-prompt-engine-wedge.md` | `lib/prompts.sh` → `internal/prompt` | 91 |
| `m16-config-loader-wedge.md` | `lib/config*.sh` → `internal/config` | 119 |
| `m17-error-taxonomy-wedge.md` | `lib/errors*.sh` + `lib/error_patterns*.sh` → `internal/errors` | 113 |

Plus `.tekhton/m11-drafts/README.md` (53 lines) explaining the directory
purpose and the path-to-commit process.

The drafts cover the 6-wedge Phase 4 first batch. Later Phase 4 wedges
(dashboard, TUI, stages) get their own design pass after the early
ones land — matches DESIGN_v4's "don't over-plan" instruction and the
m11 Watch For ("Don't pre-author Phase 4 too aggressively. The drafts
should cover 4–6 milestones").

## Quantified Inputs (decision-criteria evidence base)

| Input | Source | Result |
|-------|--------|--------|
| Phase 1 friction | `docs/go-migration.md` Phase 1 retro | 5 low / 0 medium / 0 high |
| Phase 2 friction | `docs/go-migration.md` Phase 2 retro | 5 low / 1 medium / 0 high |
| Wedge size variance | `git show --stat` for m01–m10 | mean 1799 LOC inserts, σ ≈ 525 |
| Parity-test cost | `scripts/supervisor-parity-check.sh` + companions | ~30-60s wall-clock per CI run, 0% flake rate |
| Cross-language debugging | causal log scan (`lang_origin: ambiguous`) | 0 incidents (proto envelope makes origin unambiguous) |
| Path B spike | `theseus/m11-pathb-spike` commit `612281a` | compiles, vets, runs; 7-dependency front-loading observed |

## Acceptance Criteria Verification

- [x] All six decision-criteria inputs are quantified and recorded in
      `docs/v4-phase-3-decision.md` §1 (Phase 1 friction table, Phase 2
      friction table, wedge size table, parity-test cost paragraph,
      cross-language debugging paragraph, spike findings table).
- [x] Path B spike branch (`theseus/m11-pathb-spike`) exists, contains a
      working `tekhton run --stage intake` prototype (compiles, runs in
      `--dry-run` mode), and is referenced from the decision doc with a
      measured-friction summary (§1.6 + Appendix).
- [x] `docs/v4-phase-3-decision.md` exists and contains all seven
      required sections (verified via `grep -n '^## ' docs/v4-phase-3-decision.md`).
- [x] The decision (Path A) is unambiguous — one sentence in §5,
      mirrored in `docs/go-migration.md` Phase 3 section.
- [x] Phase 4 milestone drafts exist as files (m12-m17, six drafts +
      README under `.tekhton/m11-drafts/`). Drafts use
      `MILESTONE_TEMPLATE.md` format. Not committed to
      `.claude/milestones/` in this milestone — produced as artifacts.
- [x] No file under `internal/`, `cmd/`, `lib/`, or `stages/` is modified
      by this milestone. `git status --short` on `theseus/Phase1` shows
      changes only under `docs/`, `.tekhton/`, and `.claude/milestones/`
      (the m11 status update + manifest line). The Path B spike's code
      changes live on the separate `theseus/m11-pathb-spike` branch.
- [x] m01–m10 acceptance criteria still pass; self-host check still
      passes; supervisor parity gate still green. (Test run: 493 shell
      tests pass, 250 Python tests pass + 14 skipped, all Go packages
      pass, shellcheck clean, wedge-audit clean.)

## Architecture Decisions

- **Decision doc length: 366 lines, not the milestone's "~200 lines"
  target.** The seven required sections + the trade-off matrix table +
  the spike findings + the trigger-to-revisit table all earned their
  space. Trimming to 200 lines would have removed evidence the m11
  AC explicitly requires ("All six decision-criteria inputs are
  quantified and recorded"). The "≤30 lines" cap was the go-migration.md
  Phase 3 section, which is 22 lines. The decision doc is reference
  material — short is not a goal in itself.
- **Phase 4 drafts under `.tekhton/m11-drafts/`, not
  `.claude/milestones-drafts/` or similar.** Two reasons: (1) the
  `.tekhton/` tree already holds non-committed milestone artifacts
  (CODER_SUMMARY, REVIEWER_REPORT) so future committers know to look
  there; (2) keeping the drafts visibly outside `.claude/milestones/`
  makes it impossible for the milestone-DAG runtime to accidentally
  load a draft as a real milestone. Per the m11 spec the drafts are
  artifacts, not entries.
- **Path B spike branch is a worktree, not a feature branch.** The
  worktree at `/tmp/tekhton-spike` lets the spike branch coexist with
  m11's main working copy without disturbing it. After the reversal
  window the worktree is removed (`git worktree remove`) and the
  branch is deleted.

## Files Modified

- `docs/v4-phase-3-decision.md` (NEW, 366 lines) — the decision doc.
- `docs/go-migration.md` — Phase 3 section added (22 lines), Phase 4
  entry checklist added (separate subsection).
- `.tekhton/m11-drafts/README.md` (NEW)
- `.tekhton/m11-drafts/m12-orchestrate-loop-wedge.md` (NEW)
- `.tekhton/m11-drafts/m13-manifest-parser-wedge.md` (NEW)
- `.tekhton/m11-drafts/m14-milestone-dag-wedge.md` (NEW)
- `.tekhton/m11-drafts/m15-prompt-engine-wedge.md` (NEW)
- `.tekhton/m11-drafts/m16-config-loader-wedge.md` (NEW)
- `.tekhton/m11-drafts/m17-error-taxonomy-wedge.md` (NEW)
- `.claude/milestones/m11-phase-3-reevaluation-gate.md` — runtime status
  marker only (m11 in_progress / done transitions).
- `.claude/milestones/MANIFEST.cfg` — runtime status marker only.

**Spike branch (separate, `theseus/m11-pathb-spike`):**

- `cmd/tekhton/run.go` (NEW, 272 lines) — Path B prototype.
- `cmd/tekhton/main.go` — +1 line wiring the run subcommand.

## Test Suite Results

- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — clean.
- `bash tests/run_tests.sh` — **PASS**: 493 shell tests, 250 Python tests
  (+14 skipped), all Go packages, exit 0.
- `bash scripts/wedge-audit.sh` — clean (249 files audited, 3 allowed
  shim writers).
- Spike-branch verification: `go build ./cmd/tekhton/` clean,
  `go vet ./cmd/tekhton/` clean, `go test ./...` all packages pass,
  smoke test `tekhton run --stage intake --dry-run` produces expected
  envelope.

## Human Notes Status

No human notes listed in the task input.

## Docs Updated

- `docs/v4-phase-3-decision.md` (NEW) — primary deliverable.
- `docs/go-migration.md` — Phase 3 section added.
- `.tekhton/m11-drafts/README.md` (NEW) — explains draft directory purpose.

The decision doc is reference material; future readers of `docs/go-migration.md`
follow the link to the decision doc rather than reading the long form
inline. Per the milestone Watch For, this matches the "≤30 lines: decision
sentence + link to the full doc" instruction.

## Observed Issues (out of scope)

None. m11 is a decision milestone; there's no runtime code to observe
issues in. The drafts deliberately don't pre-author beyond the 6-wedge
horizon — that's the m11 spec, not an out-of-scope cut.

## Spike Disposition

Per the decision doc's reversal-window section, the
`theseus/m11-pathb-spike` branch is preserved unmodified until 2026-06-05
(30 days from this commit). After that date — assuming the Path A
decision holds — the branch and its `/tmp/tekhton-spike` worktree are
removed in the m11 cleanup pass:

```bash
git worktree remove /tmp/tekhton-spike
git branch -D theseus/m11-pathb-spike
```

If the decision is reversed within the window, the spike is the starting
point for the parallel-spine work; the cleanup is skipped and the
amendment doc points at the spike commit as the seed.
