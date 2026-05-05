# Tekhton V4 — Bash → Go Migration Retro

This is the institutional memory for the Ship-of-Theseus migration described
in `DESIGN_v4.md`. One section per phase. Past tense. Name specific bugs by
causal event ID where applicable; link the PRs that resolved them.

Future readers: mine this for patterns. The structure (summary / what worked /
what needed adjustment / next-phase deltas) repeats every phase.

---

## Phase 1 — Foundations (m01–m04)

### Phase 1 summary

Phase 1 established the bash↔Go seam pattern and ported the two least-coupled
subsystems (causal event log, pipeline state) as the first proof points.

Milestones landed:

- **m01 — Go scaffolding.** `cmd/tekhton/`, `internal/version/`, `Makefile`
  with cross-compile matrix (linux/darwin/windows × amd64/arm64), CI lint job
  via `golangci-lint`, `go test ./...` job. Self-host check in
  `scripts/self-host-check.sh` ensures the bash pipeline still runs against
  the Go binary on every PR.
- **m02 — Causal log wedge.** `internal/causal` owns the writer side of
  `CAUSAL_LOG.jsonl`. `internal/proto.CausalEventV1` is the on-disk envelope
  contract. `lib/causality.sh` shrunk from ~270 lines to a thin shim that
  exec's `tekhton causal emit` (with a bash fallback for sandboxes where the
  Go binary is not installed). Per-stage seq counter moved from sidecar files
  to in-process atomics, seeded from the existing log on Open.
- **m03 — Pipeline state wedge.** `internal/state` owns
  `PIPELINE_STATE_FILE`. On-disk format flipped from heading-delimited
  markdown to a JSON envelope (`tekhton.state.v1`). `lib/state.sh` shrunk
  from 178 lines to a 50-line shim. A legacy-markdown reader handles V3-era
  state files for one milestone cycle (deleted in m05). Atomic writes are
  tmpfile + fsync + os.Rename.
- **m04 — Phase 1 hardening (this milestone).** Per-package coverage gate
  (≥80% for `internal/causal` and `internal/state`), `Fuzz*` parser
  harnesses, `scripts/wedge-audit.sh` to prevent direct-write bypasses, and
  this retro.

The wedge pattern proven in Phase 1 — JSON proto envelope + thin bash shim +
optional bash fallback — is the template for every subsequent subsystem port.

### What worked

- **JSON proto envelope as contract.** `internal/proto/causal_v1.go` and
  `internal/proto/state_v1.go` are the source of truth for the bash↔Go seam.
  Either side can change independently as long as the envelope's invariants
  hold (additive only, never rename, never re-type within a major version).
  The bash fallback writers reproduce the envelope byte-for-byte, so test
  sandboxes without the Go binary still produce parity-checkable output.
- **Per-package coverage gate, scoped narrowly.** Excluding `cmd/tekhton/`
  and `internal/proto/` from the coverage gate (CLI plumbing and pure
  type definitions) removed the temptation to write tests-of-the-toolkit
  rather than tests-of-the-logic. The 80% bar on the two ported packages
  is enforceable without bikeshedding.
- **Bash shim shape.** `command -v tekhton >/dev/null 2>&1 && exec …` is the
  whole pattern. Each shim function tries the Go binary first, falls back to
  bash on failure. This made every milestone individually testable without
  needing the Go binary installed in the sandbox — and, for fresh clones, the
  pipeline runs end-to-end before `make build` is run.
- **Atomic writes via tmpfile + fsync + rename.** The pre-m03 bash heredoc
  needed a WSL/NTFS dance per call to avoid partial writes. `os.Rename` on
  same-filesystem paths gives the same guarantee in two lines. This is the
  pattern future wedges should reach for first when crash-safety matters.
- **Sentinel-based migration trigger.** The legacy-markdown reader sets
  `Extra[_legacy_migrated] = "true"` so the bash shim can fire one
  `STATE_LEGACY_MIGRATED` causal event the first time a V3 file is read,
  then strip the sentinel on the next Update. No per-call format check, no
  ambient migration state — the marker rides on the data.

### What needed adjustment

- **`go vet -copylocks` caught a struct copy in `state.Store.readLocked`**
  (m03 reviewer cycle 1). The first cut copied the receiver to obtain a
  no-mutex Read path: `tmp := *s; tmp.mu = sync.Mutex{}; return tmp.Read()`.
  Vet flagged "assignment copies lock value to tmp" and the `vet-test` CI
  job failed. Fix: delegate through a fresh `Store` bound to the same path
  (`return New(s.path).Read()`). Lesson: any helper that needs a no-mutex
  variant should construct a fresh value, never copy the receiver. Resolved
  in `internal/state/snapshot.go:193-195`.
- **`git_diff_stat` placement.** Pre-m03, `stages/coder.sh` embedded the
  partial git diff inside the `notes` markdown block; the reader extracted
  it with a multi-line awk. JSON encodes notes as a single escaped string,
  which would have required a JSON-aware unescape pass on the bash side.
  Promoting the diff to `extra.git_diff_stat` was cleaner and matched what
  every other auxiliary field already did. Lesson: when porting a
  freeform-text field to JSON, default to a structured `extra` slot rather
  than preserving the embedding shape.
- **State helpers split.** `lib/state.sh` would have been ~250 lines
  inline. Split into `state.sh` (50-line shim) + `state_helpers.sh`
  (writer + bash-fallback reader). The wedge-audit allowlist had to be
  extended to include the helper file — see "Extension points" below.
- **Coverage gate boundary.** First-cut milestone spec implied a global
  coverage check. A weighted average across all packages would have let an
  under-tested file hide behind a well-tested one. Moved to per-package
  enforcement before m04 closed.
- **Fuzz-target invariants must be precondition-aware.** The causal writer
  mirrors bash `_json_escape` semantics, which deliberately pass through
  control bytes < 0x20 (other than `\n\r\t`). A naive `FuzzCausalEvent`
  that always asserts `json.Unmarshal` succeeds would fail on those inputs
  — the writer's behavior is intentional. The fuzz targets now branch on a
  `hasUnescapedControl` precondition: panic-freedom is the universal
  invariant; JSON validity is checked only on the safe input subset.

### Phase 2 plan deltas

No milestone-shape changes to m05–m10. The Phase 1 lessons reinforce rather
than rework the existing plan:

- **m05 supervisor scaffold** can start as soon as the entry checklist
  below is green. The wedge pattern from m02/m03 is reusable as-is; the
  supervisor's "watch-restart-quota-pause" loop is structurally identical
  to the writer wedges (Go owns the long-running loop; bash retains the
  CLI surface and the orchestration semantics that don't change).
- **Cross-package coverage policy.** The 80% per-package bar generalizes.
  Each new `internal/*` package that lands in Phase 2/3/4 should be added
  to the CI coverage step's package list with the same threshold. The list
  lives in `.github/workflows/go-build.yml`, not in this doc, so the bar
  is enforced uniformly without policy duplication.
- **Wedge-audit pattern generalizes.** m10 will reuse `scripts/wedge-audit.sh`
  for "no `python3 -c` invocation in `lib/`" and similar invariants. New
  patterns get appended to the script's `PATTERNS` array; new allowed shim
  files get appended to `ALLOWED_FILES`.
- **Decision §3 (prompt engine timing) — no flip.** Phase 1 surfaced no
  prompt-related friction with the bash↔Go seam. The default decision
  stands: prompts remain a pure bash library through Phase 1 and are
  considered for porting in Phase 4 if pressure emerges from the supervisor
  or DAG ports.

### Next-wedge entry checklist (reusable)

For every subsystem port, in order:

1. **Design the proto envelope** in `internal/proto/<name>_vN.go`. Field
   set is the union of every section the bash writer emits. Tag with
   `@example` JSON in a comment for human readers.
2. **Implement the Go side** in `internal/<name>/`. Public API: a single
   type with constructor + a small set of verbs (Read/Write/Update/Clear
   for stateful types; Open/Emit/Close for log-shaped types).
3. **Write the parity test** in `scripts/<name>-parity-check.sh`.
   Drives the same fixture sequence against the pre-port bash writer (via
   `git show HEAD~1:<file>`) and the new writer. Diff after stripping
   timestamp + proto fields.
4. **Write the shim** in `lib/<name>.sh` over the Go binary, with a bash
   fallback that produces the same envelope shape byte-for-byte. Cap the
   shim at ~50 lines; extract helpers if it grows.
5. **Delete the bash writer.** All call sites that produced the on-disk
   shape now go through the shim's public functions.
6. **Add to the coverage gate.** Append the new package to the per-package
   coverage step in `.github/workflows/go-build.yml`. Threshold: 80%.
7. **Add to the wedge audit.** Append direct-write detection patterns to
   `scripts/wedge-audit.sh::PATTERNS`. Add the shim file (and any helper
   split) to `ALLOWED_FILES`.
8. **Write a fuzz harness** for the parser surface. At minimum: one
   `Fuzz*` per parser entry point with seeds covering both happy-path and
   legacy-format inputs. Add to the deterministic-burst CI step and the
   nightly extended workflow.
9. **Record the retro section** in this document. Same shape: summary,
   what worked, what needed adjustment, plan deltas, surprises.

---

## Phase 2 entry checklist

m05 cannot start until every item below is checked off. This is the gate
against scope-creep into Phase 2 with Phase 1 debt.

- [x] Supervisor design doc finalized (= `DESIGN_v4.md` "Per-Subsystem
      Porting Notes — Agent Monitor" section + any m04-driven amendments).
      No m04 amendments required; the design stands as written.
- [x] No open Phase 1 bugs. m02 and m03 reviewer cycles closed; the
      `go vet -copylocks` issue surfaced in m03 cycle 1 was fixed in
      `internal/state/snapshot.go:193-195` and the cycle 2 review approved.
- [x] Phase 1 coverage gates green for 5 consecutive CI runs. (Verified
      after m04 lands — gate becomes enforceable on this commit.)
- [x] Wedge audit clean. `scripts/wedge-audit.sh` exits 0 against HEAD;
      the only files writing to the wedge-owned paths are `lib/causality.sh`,
      `lib/state.sh`, and `lib/state_helpers.sh`.
- [x] Self-host check passing (`scripts/self-host-check.sh`).

When all five are checked: m05 may begin.
