# Coder Summary — m04 Phase 1 Hardening

## Status: COMPLETE

## What Was Implemented

m04 closes Phase 1 of the V4 Go migration with gates and docs (no behavior
change). Five goals shipped:

1. **Per-package coverage gate (≥80%).** New CI step `Coverage gate
   (per-package)` in `vet-test` job. Iterates `internal/causal` and
   `internal/state`, runs `go test -coverprofile`, fails the build if either
   total drops below 80%. `cmd/tekhton/` and `internal/proto/` are excluded
   by design — CLI plumbing and pure types — and adding a new package to the
   gate is a single-line change in the workflow file. The 80% bar is
   enforced independently per package so an under-tested file cannot hide
   behind a well-tested one.

2. **Coverage backfill** in `internal/causal/log_test.go` and
   `internal/state/snapshot_test.go`. Added: `Open`/`Read` empty-path
   guards, `Emit` empty-stage/type guards, `Path()` getters, `Count()` after
   emit, `Close()` no-op, `pruneArchives` retention=0 branch, `Archive`
   no-source-file branch, empty-file `ErrCorrupt` branch, `Write(nil)` and
   empty-path branches, and `parseLegacyMarkdown` rejection of garbage
   input. These cover the previously-uncovered error/getter paths so the
   80% bar is reachable without theatre tests.

3. **Fuzz harnesses.** Two new files using Go native fuzzing:
   - `internal/causal/fuzz_test.go` — `FuzzParseStageAndSeq` (resume
     seeder), `FuzzCausalEvent` (full Emit → JSON round-trip on the
     bash-safe input subset), `FuzzQuote_RoundTrip` (escape helper). All
     three skip JSON-validity assertions on inputs containing unescaped
     control bytes since the writer mirrors bash `_json_escape` semantics
     by design — panic-freedom is the universal invariant.
   - `internal/state/fuzz_test.go` — `FuzzStateSnapshot` exercises the full
     `Read` path on arbitrary bytes with a seed corpus that includes
     well-formed v1 JSON, partial JSON, and **V3 markdown shapes** (the
     legacy reader's parser surface is what the m04 spec called out as
     critical to fuzz). `FuzzParseLegacyMarkdown` targets the legacy
     reader directly so coverage doesn't depend on Read's discriminator.
     Round-trip invariant: a successful Read must Write without error and
     re-Read to the same `ExitStage` + `ResumeTask`.

4. **`scripts/wedge-audit.sh`** (97 lines, shellcheck-clean). Greps `lib/`
   and `stages/` for direct-write patterns to `CAUSAL_LOG_FILE`,
   `PIPELINE_STATE_FILE`, plus the in-process counter assignments that Go
   now owns. Allowed shim writers: `lib/causality.sh`, `lib/state.sh`,
   `lib/state_helpers.sh`. Verified end-to-end by injecting a synthetic
   violation (3-line file with all 3 pattern shapes) and confirming the
   audit fails with all three names in the report; reverted, audit clean.

5. **`docs/go-migration.md`** — Phase 1 retrospective + Phase 2 entry
   checklist. Sections: summary, what worked, what needed adjustment
   (named the m03 `go vet -copylocks` issue, the `git_diff_stat` JSON
   shape change, the state-helpers split, the per-package vs global
   coverage shift, the fuzz precondition lesson), Phase 2 plan deltas
   (none required — m05–m10 stand), and a reusable next-wedge entry
   checklist (9 steps from "design proto" through "record retro section").

6. **CI workflow updates.** `.github/workflows/go-build.yml` gains the
   per-package coverage step, the deterministic 20-second fuzz burst, and
   the wedge audit step. New file `.github/workflows/go-fuzz-nightly.yml`
   runs each fuzz target for 5 minutes nightly with a strategy matrix and
   uploads any new corpus entries on failure.

7. **Cross-reference in `docs/go-build.md`.** Added "Migration
   retrospective", "Wedge invariants", and "Coverage and fuzz gates"
   sections so users land on the migration retro from the canonical Go
   build docs.

## Root Cause (bugs only)

N/A — m04 is gates and docs, no behavior change.

## Files Modified

| File | Change | Description |
|------|--------|-------------|
| `internal/causal/log_test.go` | Modify | Backfill: empty-path/empty-stage/empty-type guards, `Path()`/`Count()`/`Close()`, retention=0 prune, missing-source archive. ~+80 lines. |
| `internal/state/snapshot_test.go` | Modify | Backfill: `Path()` getter, empty-file `ErrCorrupt`, empty-path `Read`, `Write(nil)` + empty-path, garbage legacy parse. ~+50 lines. |
| `internal/causal/fuzz_test.go` | NEW | `FuzzParseStageAndSeq`, `FuzzCausalEvent`, `FuzzQuote_RoundTrip`. 161 lines. |
| `internal/state/fuzz_test.go` | NEW | `FuzzStateSnapshot` (V3 markdown + JSON seeds, round-trip), `FuzzParseLegacyMarkdown`. 117 lines. |
| `scripts/wedge-audit.sh` | NEW | Bash invariant gate for direct-write bypasses. 97 lines, shellcheck-clean. |
| `.github/workflows/go-build.yml` | Modify | Per-package coverage gate, deterministic fuzz burst, wedge-audit step in `lint` job. |
| `.github/workflows/go-fuzz-nightly.yml` | NEW | Nightly extended fuzz workflow with corpus artifact upload. 57 lines. |
| `docs/go-migration.md` | NEW | Phase 1 retro + Phase 2 entry checklist + reusable next-wedge checklist. 184 lines. |
| `docs/go-build.md` | Modify | Cross-references to the migration retro, wedge audit, and coverage/fuzz gates. |

## Docs Updated

- `docs/go-migration.md` — created. New top-level migration retrospective
  document; one section per phase. Public surface: project documentation,
  cross-referenced from `docs/go-build.md`.
- `docs/go-build.md` — added three new sections (Migration retrospective,
  Wedge invariants, Coverage and fuzz gates) to surface the m04 deliverables
  to anyone reading the Go build docs.
- `README.md` — added `docs/go-build.md` to the documentation table of
  contents (was previously referenced but missing from the table). This
  ensures users building from source and developers working on V4 can
  discover the Go build and migration documentation.

## Acceptance Criteria

- [x] CI coverage step iterates per-package and fails when either
      `internal/causal` or `internal/state` drops below 80%; per-function
      breakdown is printed via `go tool cover -func`.
- [x] `FuzzCausalEvent` exists and runs in CI for 20s deterministic + 5m
      nightly. Seeds cover happy-path detail strings; preconditions filter
      bash-style escape edge cases from the strong invariant.
- [x] `FuzzStateSnapshot` exists, includes V3-markdown seeds (multiple
      shapes: minimal, with orchestration block, with milestone "none"
      sentinel, with all extra-field headings), enforces the round-trip
      Write→Read invariant.
- [x] `scripts/wedge-audit.sh` exits 0 against HEAD; injecting any of the
      three pattern shapes (`>>` redirect, `mv` into the path, in-process
      counter assignment) into a non-allowed file causes a non-zero exit
      with all violations named in the report.
- [x] Nightly fuzz workflow exists at `.github/workflows/go-fuzz-nightly.yml`,
      triggers on `cron: '30 3 * * *'`, uploads corpus artifacts on failure.
- [x] `docs/go-migration.md` contains the four required sections (Phase 1
      summary, what worked, what needed adjustment, Phase 2 plan deltas)
      plus the entry checklist and the reusable next-wedge checklist.
- [x] All five entry-checklist items in `docs/go-migration.md` are marked
      complete.
- [x] m02 and m03 acceptance criteria still pass; bash test suite still
      passes (500/500 + 250 Python passing). Self-host check unchanged.
- [x] `scripts/wedge-audit.sh` confirms no bash file outside
      `lib/causality.sh`, `lib/state.sh`, and `lib/state_helpers.sh` writes
      to `CAUSAL_LOG.jsonl` or `PIPELINE_STATE_FILE` (audit clean against
      HEAD: "253 files audited, 3 allowed shim writers").

## Architecture Decisions

- **Allowlist includes `lib/state_helpers.sh`.** The m04 spec called out
  `lib/causality.sh` and `lib/state.sh` as the two allowed shim writers,
  but `lib/state.sh` is a thin (50-line) shim that sources
  `lib/state_helpers.sh` for its bash-fallback writer (atomic
  tmpfile + mv). The helper is part of the state shim by intent — the
  split exists for the 300-line file ceiling, not to hide a writer behind
  an indirection. Documented in the script's `ALLOWED_FILES` comment and
  in the migration retro.

- **Fuzz preconditions are explicit, not implicit.** `FuzzCausalEvent` and
  `FuzzQuote_RoundTrip` early-return on inputs containing unescaped
  control bytes (< 0x20 outside `\n\r\t`) or invalid UTF-8 — the writer
  mirrors bash `_json_escape` semantics by design, so a strong JSON-validity
  assertion would fail on those inputs. The no-panic invariant runs on every
  input; the round-trip invariant runs only on the safe subset. This is
  documented inline so a future reader doesn't "fix" the precondition.

- **Fuzz seeds for `FuzzStateSnapshot` deliberately bias toward the legacy
  reader.** Without a V3-markdown-shaped seed corpus, the coverage-guided
  fuzzer would spend its budget mutating JSON inputs and never reach the
  legacy parser surface. We seed five distinct V3 shapes (minimal, with
  orchestration block, with milestone "none", with extra-fields, with
  error-classification block) so the legacy reader's branches are
  reachable from generation 0.

## Human Notes Status

No notes were listed in the Human Notes section of this run.
