<!-- milestone-meta
id: "4"
status: "todo"
-->

# m04 — Phase 1 Hardening

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Closes Phase 1. Two wedges have landed (m02 causal, m03 state); both need a coverage gate, a fuzz harness, a wedge-audit script that prevents regression, and a written retro that rolls forward into Phase 2. Without this milestone, Phase 1 is "code present" rather than "Phase 1 done." |
| **Gap** | No coverage gate enforced in CI yet (m01 scaffolded the lint job but not coverage). No fuzz tests on the JSON parsers. No automated check that every bash call site for `emit_event` / `write_pipeline_state` actually goes through the shim. No retrospective written. |
| **m04 fills** | (1) 80% coverage gate in CI for `internal/causal` and `internal/state`. (2) `FuzzStateSnapshot` and `FuzzCausalEvent` parser fuzz harnesses, run for a fixed seed in CI and 5 minutes nightly. (3) `scripts/wedge-audit.sh` greps the bash tree for direct-write call sites and fails CI if any bypass the shim. (4) `docs/go-migration.md` records what changed in Phase 1, what's left, and what early lessons rolled into the Phase 2 plan. |
| **Depends on** | m02, m03 |
| **Files changed** | `internal/causal/log_test.go`, `internal/state/snapshot_test.go`, `internal/causal/fuzz_test.go`, `internal/state/fuzz_test.go`, `scripts/wedge-audit.sh`, `.github/workflows/go-build.yml`, `docs/go-migration.md` |
| **Stability after this milestone** | Stable. Phase 1 closed; the bash↔Go seam pattern proven and documented. |
| **Dogfooding stance** | Already dogfooded once m02 + m03 landed; m04 is gates-and-docs, no behavior change. Safe to land in working copy as soon as CI passes. |

---

## Design

### Goal 1 — Coverage gate

Add a coverage step to `.github/workflows/go-build.yml` after `go test`:

```yaml
- name: Coverage
  run: |
    go test -coverprofile=cover.out ./internal/causal/... ./internal/state/...
    go tool cover -func=cover.out
    pct=$(go tool cover -func=cover.out | awk '/^total:/ { sub(/%/, "", $3); print $3 }')
    awk "BEGIN { exit ($pct < 80) }"
```

The gate is scoped to the two ported packages; `cmd/tekhton/` and `internal/proto/` are excluded (CLI plumbing and pure types — coverage there is theatre).

If either package's coverage drops below 80%, CI fails with the per-function breakdown logged. Add fixture/edge-case tests in m02/m03 retroactively if needed to hit the bar before this milestone closes.

### Goal 2 — Fuzz harnesses

Two `Fuzz*` functions, both using Go's native fuzzing:

```go
// internal/state/fuzz_test.go
func FuzzStateSnapshot(f *testing.F) {
    seeds := []string{
        `{"proto":"tekhton.state.v1","run_id":"r","mode":"human"}`,
        `{}`,
        `## Exit Reason\nfoo\n`,  // legacy markdown
    }
    for _, s := range seeds { f.Add(s) }
    f.Fuzz(func(t *testing.T, in string) {
        store := state.New(writeTemp(t, in))
        snap, err := store.Read()
        if err != nil { return } // tolerated
        // round-trip invariant: a successful parse must re-serialize without panicking
        if writeErr := store.Write(snap); writeErr != nil {
            t.Fatalf("round-trip failed for %q: %v", in, writeErr)
        }
    })
}
```

Same pattern for `FuzzCausalEvent` against the JSONL line parser.

CI runs each fuzz target with `-fuzztime=20s` (fast, deterministic). A separate nightly workflow runs `-fuzztime=5m` and uploads any new corpus entries as artifacts.

### Goal 3 — Wedge audit

`scripts/wedge-audit.sh` is a 50-line bash script that:

1. Lists every bash file under `lib/` and `stages/`.
2. For each, greps for direct writes to `CAUSAL_LOG.jsonl`, `PIPELINE_STATE`, `*_SEQ_DIR/*` files.
3. Allows only the shim files (`lib/causality.sh`, `lib/state.sh`) to contain such writes.
4. Fails with a per-file report if any other file does.

The grep patterns:

```bash
PATTERNS=(
    '>>?[[:space:]]*"\?\$\?{?CAUSAL_LOG_FILE'
    '>>?[[:space:]]*"\?\$\?{?PIPELINE_STATE_FILE'
    '_LAST_EVENT_ID='     # in-process counter — Go owns this now
    '_CAUSAL_EVENT_COUNT='
)
ALLOWED=( "lib/causality.sh" "lib/state.sh" )
```

Wired into the `lint` job in CI. Bypasses are detected at PR time, not at runtime.

### Goal 4 — Phase 1 retrospective

`docs/go-migration.md` (~150 lines, ongoing document):

- **Phase 1 summary.** What landed in m01–m03. Wedge pattern proven.
- **What worked.** JSON proto envelope. Bash shim shape. Per-package coverage gate.
- **What needed adjustment.** (Filled in based on real issues encountered. Common candidates: legacy reader scope creep, CGO accidental enabling, golangci-lint preset friction.)
- **Phase 2 plan deltas.** Any milestone-shape changes to m05–m10 driven by Phase 1 lessons. If none, say so explicitly.
- **Next-wedge entry checklist.** A reusable list: design proto, implement Go side, write parity test, write shim, delete bash, add coverage, retro.

This document is the institutional memory for the migration. It grows one section per phase.

### Goal 5 — Phase 2 entry checklist

A closeout section in `docs/go-migration.md`:

- [ ] Supervisor design doc finalized (= DESIGN_v4.md "Per-Subsystem Porting Notes — Agent Monitor" section + any m04-driven amendments).
- [ ] No open Phase 1 bugs.
- [ ] Phase 1 coverage gates green for 5 consecutive CI runs.
- [ ] Wedge audit clean.
- [ ] Self-host check passing.

m05 cannot start until every item is checked off.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/causal/log_test.go`, `internal/state/snapshot_test.go` | Modify | Backfill any tests needed to hit 80% coverage. |
| `internal/causal/fuzz_test.go` | Create | `FuzzCausalEvent` parser fuzz. ~40 lines. |
| `internal/state/fuzz_test.go` | Create | `FuzzStateSnapshot` parser fuzz, includes V3 markdown seeds. ~50 lines. |
| `scripts/wedge-audit.sh` | Create | Bash script that fails CI on direct-write bypasses. ~50 lines. |
| `.github/workflows/go-build.yml` | Modify | Add coverage step (per-package gate at 80%); add wedge-audit step; add nightly fuzz workflow. |
| `docs/go-migration.md` | Create | Phase 1 retro + Phase 2 entry checklist. ~150 lines. |

---

## Acceptance Criteria

- [ ] CI coverage step passes with `internal/causal` ≥ 80% and `internal/state` ≥ 80%; per-function breakdown printed in CI logs.
- [ ] `go test -fuzz=FuzzCausalEvent -fuzztime=20s ./internal/causal/...` exits 0 with no new corpus failures.
- [ ] `go test -fuzz=FuzzStateSnapshot -fuzztime=20s ./internal/state/...` exits 0; the V3-markdown seed produces a successful legacy-reader parse.
- [ ] `scripts/wedge-audit.sh` exits 0 when run against HEAD (only the shim files write to causal/state paths); exits non-zero when an intentional violation is added (test case in CI).
- [ ] Nightly fuzz workflow exists and triggers on schedule; reports artifacts when failures occur.
- [ ] `docs/go-migration.md` exists and contains the four required sections (Phase 1 summary, what worked, what needed adjustment, Phase 2 plan deltas) plus the entry checklist.
- [ ] All five entry-checklist items are marked complete in `docs/go-migration.md` before the milestone is marked done.
- [ ] m02 and m03 acceptance criteria still pass; self-host check still passes.
- [ ] No bash file outside `lib/causality.sh` and `lib/state.sh` writes to `CAUSAL_LOG.jsonl` or `PIPELINE_STATE_FILE`.

## Watch For

- **The 80% gate is per-package, not global.** A weighted average across all packages would let an under-tested file hide behind a well-tested one. The CI step must check each package independently.
- **Fuzz seeds must include the legacy markdown shape.** Without it, the legacy reader's parser surface is uncovered and a regression there would silently break V3 → V4 resume.
- **Wedge-audit grep patterns are fragile.** Test the script by intentionally adding a bypass (in a temp branch) and verifying the script catches it. Then revert.
- **`docs/go-migration.md` is institutional memory, not marketing copy.** Write it in past tense, name specific bugs by causal event ID where applicable, link to the PRs that resolved them. Future readers will mine this for patterns.
- **Don't merge m05 until the entry checklist is fully checked off.** This is the gate against scope-creep into Phase 2 with Phase 1 debt.
- **Coverage gate exclusions.** `cmd/tekhton/` and `internal/proto/` are excluded by design. Don't expand the inclusion list silently — every additional package needs a justified % bar.

## Seeds Forward

- **m05 supervisor scaffold:** the Phase 2 entry checklist gates the start. The wedge audit pattern from m04 generalizes — m10 will reuse it for "no `python3 -c` in lib/" and similar invariants.
- **Phase 2/3/4 retros:** `docs/go-migration.md` grows one section per phase. The structure established here (summary / worked / adjusted / next-deltas) repeats.
- **Cross-package coverage policy:** as `internal/supervisor/` and friends arrive, each gets added to the per-package gate at 80%. The list lives in CI, not in this doc, so the bar is enforced uniformly.
- **Decision §3 (prompt engine timing):** if Phase 1 surfaced any prompt-related friction with the bash↔Go seam, note it in the Phase 2 plan deltas section. The default decision (Phase 1 as a pure library) can flip to Phase 4 here without contradicting the design.
