# V4 Phase 3 Decision — Ship of Theseus vs Parallel Spine

**Status:** Decided 2026-05-06. Decision: **Path A — Ship of Theseus continues.**
**Reversal window:** 30 days from this date (until 2026-06-05).

This document is the m11 deliverable: an evidence-based go/no-go on how V4
continues after the Phase 2 supervisor wedge landed in m10. It records the
quantified inputs, the two paths, the trade-off matrix, the decision, the
trigger conditions for revisiting, and a 30-day reversal window.

---

## 1. Inputs

The six decision-criteria inputs from the m11 milestone, quantified.

### 1.1 Phase 1 friction count

Source: `docs/go-migration.md` Phase 1 retrospective ("What needed adjustment").
Five friction items, all caught in-cycle and resolved within their owning
milestone:

| # | Item | Severity | Resolution scope |
|---|------|----------|------------------|
| 1 | `go vet -copylocks` flagged a struct copy in `state.Store.readLocked` (m03 cycle 1) | low | 3-line fix in `internal/state/snapshot.go:193-195` |
| 2 | `git_diff_stat` placement — embedded in markdown vs JSON `extra` slot | low | shape choice during m03 design |
| 3 | `lib/state.sh` would have been ~250 lines inline; split into shim + helpers | low | extracted `state_helpers.sh`; pattern reused across wedges |
| 4 | Coverage gate boundary — first cut implied global; moved to per-package | low | `.github/workflows/go-build.yml` config |
| 5 | Fuzz-target invariants must be precondition-aware (control bytes < 0x20) | low | branched on `hasUnescapedControl` precondition |

Severity-weighted total: **5 low, 0 medium, 0 high.** No friction item
required a milestone re-spec.

### 1.2 Phase 2 friction count

Source: `docs/go-migration.md` Phase 2 retrospective. Six friction items:

| # | Item | Severity | Resolution scope |
|---|------|----------|------------------|
| 1 | `lib/agent.sh` 80-line ceiling required a second helper file (`lib/agent_shim.sh`) | low | extracted at end of m10 |
| 2 | `shellcheck` SC2034 on V3-contract globals across files | low | per-line `disable=SC2034` directives + comment |
| 3 | `python3 -c "import json"` audit found one straggler (`lib/project_version.sh`) outside the supervisor wedge | low | grep+sed replacement |
| 4 | Side-by-side bash↔Go diff is structurally impossible inside the cutover commit | medium | reframed gate as assertion-based 12-scenario matrix |
| 5 | Bash-internal tests had to be deleted, not rewritten (11 files) | low | each test's contract was already covered by `internal/supervisor/{run,retry,quota,fsnotify}_test.go` (90.5% statement coverage) |
| 6 | `lib/state_helpers.sh` legacy-markdown read branch removal (m03 "REMOVE IN m05" debt) | low | delete branch + parallel `internal/state/legacy_reader.go` |

Severity-weighted total: **5 low, 1 medium, 0 high.** The medium-severity
item (cutover diff) was a measurement-strategy adjustment, not a
structural defect; the assertion-based 12-scenario matrix is now the
permanent gate.

### 1.3 Wedge size variance

Lines added/removed per V4 milestone commit (`git show --stat <sha>` for
m01–m10). Insertions only, since deletions are dominated by the m10 cutover:

| Milestone | Files changed | Insertions | Deletions | Net |
|-----------|---------------|-----------:|----------:|-------:|
| m01 — Go Module Foundation | 33 | 1137 | 356 | +781 |
| m02 — Causal Log Wedge | 32 | 1863 | 454 | +1409 |
| m03 — Pipeline State Wedge | 51 | 3009 | 555 | +2454 |
| m04 — Phase 1 Hardening | 23 | 1185 | 242 | +943 |
| m05 — Supervisor Scaffold + Agent Contract | 29 | 1602 | 216 | +1386 |
| m06 — Supervisor Core | 38 | 1844 | 257 | +1587 |
| m07 — Retry Envelope + Typed Errors | 24 | 1422 | 422 | +1000 |
| m08 — Quota Pause + Retry-After | 23 | 2044 | 212 | +1832 |
| m09 — Windows/WSL Reaper + fsnotify | 25 | 1850 | 367 | +1483 |
| m10 — Supervisor Parity + Cutover | 54 | 2035 | 4282 | -2247 |

**Mean insertions/wedge:** ~1799 LOC. **Variance (insertions):** 1137 to 3009
(σ ≈ 525). Wedge size is predictable; the largest (m03 + m08) were both
flagged as larger than typical in their respective designs. The cutover
(m10) is the only large negative — by design.

### 1.4 Parity-test cost

Sources: `scripts/supervisor-parity-check.sh` (230 lines, 12 scenarios),
`scripts/causal-parity-check.sh` (4631 bytes), `scripts/state-resume-parity-check.sh`
(6534 bytes), `scripts/wedge-audit.sh` (110 lines).

**Wall-clock per CI run:** the m10 parity job dominates at ~30-60s
(scenarios 1, 2, 5, 6, 9, 10 each spawn a fake-agent subprocess + supervisor;
3, 4, 7, 8, 11, 12 are delegated to per-package Go tests or other shell
scripts and don't add wall-clock to the parity job specifically). The
causal and state-resume parity scripts run in <10s combined.

**Flake rate:** 0% across the m10 design's "5 consecutive runs" entry-bar
requirement. No parity scenario has been observed to flake to date.

**Maintenance cost:** each new wedge adds 1 parity-check script (~100-250
LOC) plus 1-2 PATTERNS rows in `scripts/wedge-audit.sh`. Linear scaling, low.

### 1.5 Cross-language debugging incidents

The m11 milestone proposed counting causal events tagged
`lang_origin: ambiguous`. The codebase has no such field — the wedge pattern
specifically routed Go writes through `internal/proto.*V1` envelopes that
include unambiguous `proto: "tekhton.<name>.v1"` markers, and bash readers
identify origin by parsing the discriminator. No event in any V4 run we have
visibility into has been ambiguous as to which language wrote it.

The substantive metric: **count of bugs caused by bash↔Go shape mismatch
during m02–m10.** That count is **0** — the m02 fuzz-target precondition
adjustment (Phase 1 friction #5) is the closest analogue, and that was a
cross-language *invariant* clarification, not a bug from interaction.

The pattern that prevents this is the proto envelope contract: each
subsystem's bash side and Go side talk through a versioned JSON schema
defined once in `internal/proto/`, and the wedge audit
(`scripts/wedge-audit.sh`) enforces that bash writers don't bypass the
shim. Five V4 milestones (m02, m03, m05, m06, m10) added entries to the
audit, all green.

### 1.6 Path B spike — `theseus/m11-pathb-spike`

Performed against this milestone. Branch `theseus/m11-pathb-spike` (commit
`612281a`). Files: `cmd/tekhton/run.go` (272 lines), one-line addition to
`cmd/tekhton/main.go` to wire the subcommand.

**Time-box:** ~3 hours of agent time, well under the milestone's 1-day cap.

**What the spike achieved:**

- `tekhton run --stage intake` compiles, vets clean, and runs end-to-end in
  `--dry-run` mode. The dry-run prints the rendered prompt size + the
  `agent.request.v1` envelope that *would* be passed to
  `supervisor.Retry`.
- `internal/state.Store` reads `PIPELINE_STATE` and `Update`s a verdict
  field after a hypothetical agent run. The m03 state wedge made this
  zero-friction — the spike adds 5 lines of `Update(...)` glue and the
  on-disk format is unchanged.
- The supervisor seam is clean: `supervisor.New(nil, nil)` +
  `.Retry(ctx, req, supervisor.DefaultPolicy())` is the same shape
  `lib/agent.sh` invokes today (m10), but in-process — one fewer
  subprocess hop. **This validates the DESIGN_v4 §Phase 4 prediction**
  that the orchestrate port collapses 2-hop bash → Go → Go to 1-hop.

**What the spike could NOT achieve in the time-box (the friction data):**

- **Prompt template engine.** The spike includes a 30-line `{{VAR}}`
  substituter that strips `{{IF:VAR}}…{{ENDIF:VAR}}` rather than honoring
  it. The real `lib/prompts.sh` is ~150 lines and handles conditionals,
  nested blocks, and trim semantics. To make the spike production-shaped,
  this would need to be ported (added cost ~150 LOC) or bridged via a
  `tekhton render-prompt` subcommand (re-introducing the subprocess hop
  Path B was supposed to eliminate).
- **Verdict parsing.** Stub: single-regex extraction of `Verdict:` line.
  Real `lib/intake_helpers.sh` handles 6 verdict states
  (PASS / TWEAKED / NEEDS_CLARITY / SPLIT_RECOMMENDED / REJECTED /
  CONFIRM_TWEAKS), confidence scores, tweaked-content extraction, and the
  M118 success-line deferral. ~150 LOC of parsing logic.
- **Context injection.** Intake's bash stage reaches into seven adjacent
  subsystems — notes, health, indexer, causality query, project index,
  UI detection, run memory — for prompt context. The spike stubs each as
  empty strings. A production Path B implementation has to either port
  each subsystem (the same Path A wedges, just front-loaded onto stage 1)
  or bridge them via subprocess calls back into bash (defeating the
  in-process advantage).
- **Drift writes, TUI updates, milestone-DAG hooks, dashboard emitters.**
  None wired. Each is an independent subsystem the bash stage integrates
  via global helpers. In Go each is a separate package port.

**Total visible spike-friction:** the spike ports *one* of intake's
~12 dependencies (state). Reaching production-shape for Path B's first
stage requires ~7-12 additional subsystem ports OR an equivalent number of
bash-bridges. This front-loads decisions Path A would amortize across
Phase 4 + Phase 5.

The spike is preserved on `theseus/m11-pathb-spike` as the friction record.
If the decision is reversed within the 30-day window, the spike is the
starting point. Otherwise the branch is deleted in the m11 cleanup pass.

---

## 2. Path A characterization — Ship of Theseus continues

**Shape.** Continue wedging bash subsystems into Go one at a time, with
bash as the shrinking outer shell. After Phase 2: ports the orchestration
loop, milestone DAG + sliding window, prompt engine, config loader, error
taxonomy, dashboard emitters, TUI status writer; then stages
(intake → security → review → tester → coder), then the long tail
(diagnose, health, init, plan, draft-milestones, migrate, notes-cli,
rescan, rollback, draft, status, report, metrics).

**Wedge size estimate.** Mean Phase 1+2 wedge = ~1799 LOC insertions.
σ ≈ 525. Phase 4 wedges may run larger because orchestrate (~1869 LOC of
bash across 8 files) and milestones (~3000+ LOC across 15+ files) are
each the size of multiple Phase 2 wedges' worth of bash. Conservative
estimate: Phase 4 wedges run 1500-3500 LOC inserted each, with the same
~6:1 net deletion at cutover.

**Estimated remaining milestones.** Phase 4 (orchestrate + DAG + prompt +
config + error + dashboard + TUI = ~7 wedges) + Phase 5 stages (~5 wedges)
+ Phase 5 long tail (~12 small wedges, mostly UI/CLI). **~24 milestones**
to V4 complete. At ~10/year cadence (Phase 1+2 was 10 milestones in
~2 months calendar), this is roughly 18-30 calendar months.

**Risk profile.**
- Predictable. Every Phase 1+2 wedge fit the template. No surprise has
  required a re-spec.
- Reversible. Each wedge is independently revertable; the bash side
  exists right up to the cutover commit.
- Front-loads no decisions. Each subsystem is decided when its wedge
  comes up.
- Behavior-preserving by construction (parity gate per wedge).

**End state.** `tekhton.sh` becomes a one-line wrapper that exec's the
binary; `lib/` and `stages/` are empty; the Go binary is the entry point.

---

## 3. Path B characterization — Parallel spine

**Shape.** Start a new `tekhton run` Go entry point that re-implements the
orchestration loop natively. Bash continues to work for unported features
during the transition. Eventually the bash entry point is deprecated.

**Stage size estimate.** From the m11 spike: production-shape `tekhton run
--stage intake` requires ~700-1000 LOC for the stage itself plus the
ports of ~7 dependencies (prompt engine, intake helpers, notes, health,
indexer, project index, UI detection). Pessimistically, the first Path B
stage is the size of 4-5 Path A wedges — those subsystems get ported
*regardless*, just on Path B they all happen at once.

**Estimated remaining milestones.** 5-6 stage milestones (intake,
security, review, tester, coder, ?docs) at ~3-4 weeks each; plus a
parallel-spine integration milestone; plus deprecation of the bash entry
point. **~10 milestones** to V4 complete. Sounds faster — but each is
larger and more interlocked.

**Risk profile.**
- **Two code paths during transition.** The bash spine and the Go spine
  both exist. Bug fixes must be applied to both, or one diverges. The m10
  retro called this out: "Path (b) buys speed at the cost of a second code
  path."
- **Front-loads the prompt engine + helper ports.** Path A treats each as
  its own milestone with its own design pass; Path B forces all of them
  in stage 1.
- **Test infrastructure churn.** The bash test suite asserts against the
  bash spine. Path B either runs both suites (cost) or migrates en bloc
  (risk).
- **Parity gates harder.** The 12-scenario supervisor parity gate works
  because the bash supervisor is a contained subsystem. A whole-spine
  parity gate is fixture-heavy (a full pipeline run × 6+ stages × happy
  + edge paths).

**End state.** Same as Path A: Go binary is the entry point. The
difference is the path taken.

---

## 4. Trade-off matrix

| Dimension | Path A (Theseus) | Path B (Parallel Spine) |
|-----------|-----------------|------------------------|
| **Speed (calendar)** | 18-30 months | 12-18 months (estimate) |
| **Speed (wall-clock per milestone)** | Predictable from m01–m10 | First milestone ~4× larger; uncertain |
| **Risk** | Low (parity per wedge) | Medium (two code paths, harder parity) |
| **Total cost (LOC churned)** | ~25k inserts / ~25k deletes over 24 milestones | ~15k inserts / ~25k deletes over 10 milestones; similar net |
| **End-state cleanliness** | Identical | Identical |
| **Contributor cognitive load (during)** | Low — one spine, shrinking bash surface | Medium — two spines, cross-cutting bug fixes |
| **Contributor cognitive load (end)** | Identical | Identical |
| **Reversibility** | Per-wedge revertable | Per-stage-port revertable, but interlocked |
| **Design surface forced upfront** | None — each subsystem decided when wedged | Prompt engine + helper ports + orchestrate shape all decided in stage 1 |
| **Pattern reusability for V5** | Wedge pattern is reusable (provider abstraction = next wedge) | Stage-port pattern is reusable but lower-leverage |
| **Phase 1+2 evidence supports** | **Yes — the wedge pattern landed cleanly** | No direct evidence; spike showed ~7 dependency front-loading |

The tilt is asymmetric: Path A has an evidence-backed track record (Phase
1 + Phase 2 = 10 wedges, all on-template, low friction). Path B has a
3-hour spike that compiled and worked at the seam level but surfaced the
front-loading problem clearly.

---

## 5. Decision

**Path A — Ship of Theseus continues.** Phase 4 begins with `lib/orchestrate.sh`
as the next wedge.

**Reasoning.** Three considerations, in priority order:

1. **The wedge pattern works.** Phase 1 and Phase 2 produced ten milestones
   with low-severity friction (5 low + 5 low + 1 medium-on-measurement).
   The "next-wedge entry checklist" in `docs/go-migration.md` is a
   validated template. Path A's risk is calibrated; Path B's risk is
   inferred from a 3-hour spike.

2. **Path B front-loads decisions Path A amortizes.** The spike ported
   one of intake's ~12 dependencies (state, already wedged) and stubbed
   the rest. To produce a production-shape `tekhton run --stage intake`,
   either (a) the prompt engine, intake helpers, notes, health, indexer,
   project index, and UI detection all need to be ported in stage 1, or
   (b) each is bridged via subprocess back into bash (defeating Path B's
   stated advantage). Path A treats each as its own wedge; Path B does
   not save work, only re-orders it.

3. **The supervisor seam already proves the in-process advantage Path B
   wants.** Phase 4's orchestrate port can call `internal/supervisor.Retry`
   directly — no subprocess hop, no `_RWR_*` globals to round-trip. Path
   A captures this benefit at orchestrate-port time without a second
   spine. Path B's "in-process" claim is already redeemable by the
   wedging path.

The m10 retrospective's recommendation entering m11 was "stay on Path
(a)." The Phase 2 evidence + spike confirmation supports that.

---

## 6. Trigger to revisit

The decision is conditional on Phase 4 behaving like Phase 1 + 2. Specific
triggers that fire a re-evaluation:

| Trigger | Threshold | Source signal |
|---------|-----------|---------------|
| **Phase 4 wedge size blowout** | A single wedge exceeds 5000 LOC inserted, OR wedge turn budget exceeds 200% of plan | `git show --stat` per milestone commit; milestone retro |
| **Repeated friction at the same seam** | A single subsystem requires 3+ revisions across consecutive milestones to stabilize | Causal log scan for `rework_cycle` events on the same `stage` |
| **Bash side starts diverging** | Bash patches landing on a not-yet-wedged subsystem outpace the wedge cadence by 2:1 across a calendar quarter | `git log --since` on `lib/` + `stages/` vs Go file count |
| **Test infrastructure breaks** | The parity gate flakes, OR the bash test suite + Go test suite take >15 min CI wall clock combined | CI dashboard metrics |
| **Contributor friction** | Any V4 PR review surfaces "I don't know which side this lives on" >2 times in a quarter | PR review comments |

If any trigger fires, this document is amended (Section 5 updated, Path B
re-spiked from the current m11 branch as a starting point) and the next
phase's design is reconsidered.

---

## 7. Reversal window

**This decision is reversible without political cost until 2026-06-05
(30 days from 2026-05-06).** Within that window:

- New evidence — a single Phase 4 milestone that runs into trouble the
  Path B spike suggested would be easier — is sufficient grounds to flip.
- The reversal is recorded by amending Section 5 of this document and
  authoring a `docs/v4-phase-3-decision-amendment.md` note. No new design
  milestone required.
- The `theseus/m11-pathb-spike` branch is the starting point. It is
  preserved unmodified during the reversal window.

**After 2026-06-05:** the decision is in force. Reversal still possible,
but requires a new design milestone (`v4-phase-N-decision.md`) with its
own evidence base. The bar rises because Phase 4 is in flight; reversing
mid-flight is more disruptive than reversing pre-flight.

The reversal window is a deliberate hedge: m11's job was to make a call,
not to lock the team into 18 months of regret. If the call was wrong,
the cost of admitting it within 30 days is bounded.

---

## Appendix — Spike branch metadata

- **Branch:** `theseus/m11-pathb-spike`
- **Tip commit:** `612281a [m11 spike] Path B prototype: tekhton run --stage intake`
- **Files added:** `cmd/tekhton/run.go` (272 lines)
- **Files modified:** `cmd/tekhton/main.go` (+1 line — `cmd.AddCommand(newRunCmd())`)
- **Build status:** `go build ./cmd/tekhton/` — clean.
- **Vet status:** `go vet ./cmd/tekhton/` — clean.
- **Test status:** `go test ./...` — all packages pass (cmd/tekhton tests
  unchanged from m10, spike adds no tests since it is a friction probe,
  not production code).
- **Smoke test:** `./tekhton run --stage intake --task "test task" --dry-run`
  produces an `agent.request.v1` envelope and a 6567-byte rendered prompt.
- **Disposition:** preserved during the 30-day reversal window; deleted
  in the m11 cleanup pass on 2026-06-05 if Path A holds.
