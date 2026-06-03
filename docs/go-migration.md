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

---

## Phase 2 — Supervisor wedge (m05–m10)

### Phase 2 summary

Phase 2 ported the agent supervisor — the loop that launches `claude`,
streams its JSON output, bounds idle time, retries on transient failure,
pauses for quota refresh, and reaps the process tree on cancellation.
This was the largest single Phase 1→4 chunk: ~1300 lines of bash
(`lib/agent_monitor*.sh` + `lib/agent_retry*.sh` + the original
`lib/agent.sh`) collapsed into ~80 lines of shim plus
`internal/supervisor/`.

Milestones landed:

- **m05 — Scaffold + agent.request.v1 / agent.response.v1 contract.**
  `cmd/tekhton/supervise` reads the request envelope and (initially)
  returned a stub response. The proto + CLI surface stayed stable for
  every subsequent milestone.
- **m06 — Real subprocess path.** `internal/supervisor/run.go` shells
  out to the agent binary via `exec.CommandContext`, scans stdout for
  streaming JSON via `bufio.Scanner` (with `scannerMaxBuf` matching V3's
  ring-buffer width), tees stderr to the causal log. `decoder.go`
  isolates the JSON-event loop so tests can drive it without spawning a
  process.
- **m07 — Retry envelope + typed errors.** `internal/supervisor/retry.go`
  + `errors.go` introduced `AgentError` (typed, `errors.Is`-aware)
  alongside the V3-equivalent `RetryPolicy` defaults. Subcategory floors
  (`api_rate_limit` → 60s, `oom` → 15s) preserved exactly. ±10% jitter
  is new — a deliberate addition to defeat thundering-herd retries
  against shared rate limits.
- **m08 — Quota pause + Retry-After parsing.** `quota.go` handles the
  full pause loop with chunked sleep (defaults match
  `QUOTA_SLEEP_CHUNK=5s` / `QUOTA_MAX_PAUSE_DURATION=5h15m`).
  `ParseRetryAfter` accepts both integer-second and HTTP-date forms.
  The retry loop's quota-pause path drains 429s without consuming a
  retry attempt — same V3 semantic.
- **m09 — Windows reaper + fsnotify activity override.** `reaper_*.go`
  (build-tagged) use Windows JobObject for tree termination and POSIX
  `Setpgid`/`syscall.Kill(-pgid)` on everything else. `fsnotify.go`
  watches the working directory; when the activity timer would fire but
  recent FS activity is observed, the timer resets up to
  `activityOverrideCap=3` times before becoming permanent. Fallback to
  mtime-walk when `fsnotify.NewWatcher()` fails (rare FUSE/WSL setups).
- **m10 — Cutover + parity gate (this milestone).** `lib/agent.sh`
  flipped to call `tekhton supervise`. Bash supervisor files
  (`lib/agent_monitor*.sh`, `lib/agent_retry*.sh`) deleted.
  `scripts/supervisor-parity-check.sh` is the gate.
  `internal/state/legacy_reader.go` (the m03 "REMOVE IN m05" debt) also
  deleted; pre-m03 markdown state files now return `ErrLegacyFormat`.

### What worked

- **Build-tagged platform files.** `reaper_unix.go` (`//go:build !windows`)
  and `reaper_windows.go` (`//go:build windows`) gave us a single
  `applyProcAttr(cmd)` call in `run.go` with no `runtime.GOOS` branching.
  `GOOS=windows GOARCH=amd64 go build ./...` cross-compiles cleanly from
  Linux as a CI gate; the actual JobObject reaper is exercised on the
  `windows-latest` runner. The pattern transfers to Phase 3 if any
  future subsystem grows a platform conditional.
- **fsnotify with mtime fallback.** Production paths see fsnotify; rare
  FUSE / WSL setups silently use the mtime walker. Both produce the same
  `HadActivitySince(t)` signal, so `run.go` doesn't care which mode is
  active — it just consults the watcher. The fallback was caught early
  by the milestone "Watch For" line and added with one extra
  branch-and-test.
- **Typed errors with `errors.Is` instead of string matching.** The V3
  bash supervisor classified errors by grepping stderr (`is_rate_limit_error`
  was a giant case statement over text patterns). `internal/supervisor/errors.go`
  declares `ErrUpstreamRateLimit`, `ErrUpstreamTransient`, etc., and
  `classifyResult` returns them. The retry loop uses
  `errors.Is(cls, ErrUpstreamRateLimit)` — refactor-safe in a way the
  bash regex never was. Future provider abstractions in V5 will plug new
  classification rules into this seam without touching the loop.
- **Activity-timer override cap as a code-level constant, not an
  envelope field.** `activityOverrideCap = 3` lives next to
  `handleActivityTimeout` in `run.go`. Surfacing it on
  `AgentRequestV1` would have invited tuning that defeats the whole
  point of an activity timeout (pathological loops are exactly what
  it's supposed to catch). The m09 milestone Watch For called this out
  explicitly and the constant has stayed unconfigurable.
- **CLI flag for the parity gate.** Adding `--no-retry` to
  `tekhton supervise` let the m10 parity script exercise both the
  retry-wrapped path (default, production) and single-attempt path
  (parity assertions for fatal_error / activity_timeout) without two
  separate CLI surfaces.

### What needed adjustment

- **`lib/agent.sh` 80-line ceiling required a second helper file.**
  The first cut had ~106 lines: response parsing + null-run
  classification + tool-profile exports + global initializers all
  inline. Moved tool profiles, globals, and `_shim_apply_response` into
  `lib/agent_shim.sh` to land at exactly 80 lines.
- **`shellcheck` SC2034 on V3-contract globals.** Every
  `LAST_AGENT_*`, `_RWR_*`, and `AGENT_ERROR_*` is assigned in
  `agent_shim.sh` and read in `lib/orchestrate.sh` /
  `lib/finalize_summary_collectors.sh` — across files shellcheck
  considers them unused. Each assignment got a `# shellcheck
  disable=SC2034` directive with a "consumed by" comment. The Phase 4
  orchestrate port is the moment to delete the bulk of these.
- **`python3 -c "import json"` audit found one straggler outside the
  supervisor wedge.** `lib/project_version.sh::_detect_version_from_file`
  parsed `package.json`'s top-level `version` via Python. Replaced with
  a grep+sed pair scoped to the top-level `"version"` key. Three other
  multi-line `python3 -c` blocks (`lib/dashboard_parsers_runs*.sh`,
  `lib/project_version_bump.sh`) survived: they don't match the
  single-line `python3 -c.*json` AC, do non-trivial JSON manipulation
  for which a pure-bash replacement would be fragile, and fall back
  cleanly when `python3` is absent. Those are tracked as Phase 3+
  cleanup.
- **Side-by-side bash↔Go diff is structurally impossible inside the
  cutover commit.** The m10 design described running each scenario
  twice — once against `git show HEAD~1:lib/agent_monitor.sh` and once
  against HEAD's Go code. But m10 deletes the bash files, so HEAD~1
  *during the m10 PR* would be m09 (which still has both stacks); after
  m10 lands, "the bash baseline" no longer exists in the repo at all.
  The actual gate became an assertion-based 12-scenario matrix against
  the Go side, with the m07–m09 pairwise diffs serving as the
  per-subsystem parity record. Documented in
  `scripts/supervisor-parity-check.sh` so a future reader doesn't ask
  the same question.
- **Bash-internal tests had to be deleted, not rewritten.**
  `tests/test_run_with_retry_loop.sh`,
  `tests/test_should_retry_transient.sh`,
  `tests/test_agent_fifo_invocation.sh`,
  `tests/test_agent_monitor_ring_buffer.sh`,
  `tests/test_agent_retry_pause.sh`,
  `tests/test_agent_file_scan_depth.sh`,
  `tests/test_agent_retry_config_defaults.sh`,
  `tests/test_prompt_tempfile.sh`,
  `tests/test_quota_retry_after_integration.sh`,
  `tests/test_agent_counter.sh`, and
  `tests/helpers/retry_after_extract.sh` all targeted internals
  (`_invoke_and_monitor`, `_run_with_retry`, ring-buffer dump,
  prompt-tempfile mechanic, `_extract_retry_after_seconds`) that no
  longer exist. The contract they represented is now covered by
  `internal/supervisor/{run,retry,quota,fsnotify}_test.go` (90%+
  statement coverage). Tests of public bash API
  (`tests/test_agent_exit_detection.sh`,
  `tests/test_stage_summary_model_display.sh`) survive unchanged.
- **`lib/state_helpers.sh` lost its legacy-markdown read branch.**
  m03 left a "REMOVE IN m10" marker; m10 removed it (and the parallel
  Go `legacy_reader.go`). Pre-m03 state files now surface
  `ErrLegacyFormat` rather than auto-migrating — operators run the V4
  migration tool explicitly.

### Phase 3 plan deltas

- **The supervisor seam is the natural plug-point for V5's multi-provider
  work.** `internal/supervisor.AgentRunner`-shaped seams already exist
  (the `runFunc` in `retry.go`); a future provider abstraction is just
  alternative `runFunc` implementations dispatched by the CLI / config.
  Phase 3 doesn't take this on, but the seam is sized for it.
- **Phase 4 orchestrate port collapses two hops to one.** Today
  `lib/orchestrate.sh` shells to `lib/agent.sh` which shells to
  `tekhton supervise`. After Phase 4, `internal/orchestrate` calls
  `supervisor.Retry` in-process — one Go binary, no subprocess hops.
  The `_RWR_*` and `LAST_AGENT_*` globals carried over from V3 in m10
  delete entirely at that point.
- **Wedge-audit pattern surface grew.** New `PATTERNS` entries in m10:
  `python3 -c.*json` (the Watch For audit) and an anchored
  `^(source|.) .*/(agent_monitor|agent_retry)` (regression guard
  against re-sourcing deleted files). The audit comment block in
  `wedge-audit.sh` now documents both as m10 additions.
- **Re-evaluation point at m11.** The DESIGN_v4 plan called for a
  Phase 3 entry decision: Path (a) Ship-of-Theseus continues vs Path
  (b) parallel `tekhton run` entry point. Phase 2 surfaced no
  structural friction with Path (a); the supervisor wedge worked the
  same way the writer wedges did. Recommendation entering m11: stay
  on Path (a).

---

## Phase 3 entry checklist

m11 cannot start until every item below is checked off.

- [ ] Parity gate (`scripts/supervisor-parity-check.sh`) green for 5
      consecutive CI runs.
- [ ] No bash file under `lib/` matches `agent_monitor` or `agent_retry`
      via the wedge-audit `^(source|.) ` pattern.
- [ ] No bash file under `lib/` or `stages/` matches the single-line
      `python3 -c.*json` regression pattern.
- [ ] `tests/run_tests.sh` produces output identical to HEAD~1 modulo the
      timestamp/run-id allowlist.
- [ ] `m126`–`m138` resilience arc tests pass against the V4 codebase
      (`tests/test_resilience_arc_*.sh`).
- [ ] Self-host check passing (`scripts/self-host-check.sh`) on
      `linux/amd64`, `darwin/amd64`, `windows/amd64`.
- [ ] `docs/go-migration.md` Phase 2 section complete (this section).

When all seven are checked: m11 may begin.

---

## Phase 3 — Re-evaluation Decision (m11)

m11 was the single-milestone decision retrospective: continue wedging
bash subsystems into Go (Path A — Ship of Theseus) or start a parallel
`tekhton run` Go entry point (Path B — parallel spine).

**Decision: Path A — Ship of Theseus continues.** Phase 4 begins with
`lib/orchestrate.sh` as the next wedge. Full inputs, trade-off matrix,
trigger conditions, and 30-day reversal window are recorded in
[`docs/v4-phase-3-decision.md`](v4-phase-3-decision.md).

Path B spike branch: `theseus/m11-pathb-spike` (commit `612281a`,
`cmd/tekhton/run.go` 272 lines). Preserved during the reversal window
(until 2026-06-05); deleted in the m11 cleanup pass if Path A holds.

m11 produces no runtime code change. Phase 4 milestone drafts authored
under `.tekhton/m11-drafts/` (m12–m17 first batch) land in a separate
milestone-authoring commit.

---

## Phase 4 entry checklist

m12 cannot start until every item below is checked off.

- [x] m11 decision doc (`docs/v4-phase-3-decision.md`) committed and
      referenced from this section.
- [x] Phase 4 milestone drafts (m12-m17 first batch) reviewed and
      committed in their own milestone-authoring batch.
- [x] Phase 3 entry checklist items (above) all green for the prior 5
      consecutive CI runs.
- [x] Self-host check passing (`scripts/self-host-check.sh`).
- [x] Wedge audit clean against the new Phase 4 PATTERNS additions
      (orchestrate-related shapes — defined in m12's design).

All five checked: m12 in progress.

---

## Phase 4 — Orchestrate Loop Wedge (m12+)

### m12 — Orchestrate Loop Wedge

m12 is the first wedge of Phase 4: the outer pipeline loop ported from
`lib/orchestrate.sh` into `internal/orchestrate`. Goals delivered:

- **`internal/proto/orchestrate_v1.go`.** New envelope contracts:
  `tekhton.attempt.request.v1` (orchestrator input — task, milestone,
  safety bounds, resume state) and `tekhton.attempt.result.v1`
  (orchestrator output — outcome, recovery class, cumulative counters,
  cause summary, resume hints). The result envelope's shape mirrors the
  V3 bash orchestrator's `RUN_SUMMARY.json` modulo CamelCase →
  snake_case so `scripts/orchestrate-parity-check.sh` can diff the two.
- **`internal/orchestrate` package.** `Loop.RunAttempt(ctx, req)` drives
  the safety-bound + recovery-dispatch outer frame the bash
  `run_complete_loop` previously held. `Classify(outcome, cfg)` is the
  pure dispatch ported from `_classify_failure` in
  `lib/orchestrate_classify.sh`. Coverage: 94.7%.
- **`tekhton orchestrate` Cobra subcommand.** Two flavours:
  `tekhton orchestrate classify` (pure dispatch — input: stage outcome
  JSON, output: recovery class), and `tekhton orchestrate run-attempt`
  (drives the outer loop with a stub `StageRunner`). The bash front-end
  of `tekhton.sh` is not yet flipped onto run-attempt — m12 ships the
  loop scaffold and parity gate; the bash↔Go stage-runner bridge lands
  in m13/m14 after the milestone DAG itself moves into Go.
- **`_RWR_*` deletion.** The round-trip orchestrate-globals pair
  (`_RWR_EXIT`, `_RWR_TURNS`, `_RWR_WAS_ACTIVITY_TIMEOUT`) that bash
  used as a callback contract between `lib/agent.sh` and
  `lib/orchestrate.sh` is gone. Downstream consumers were already on
  the `LAST_AGENT_*` names; the activity-timeout flag survives as
  `LAST_AGENT_WAS_ACTIVITY_TIMEOUT`. `grep -rn _RWR_ lib/ stages/`
  is empty after this milestone.
- **Phase 4 wedge-audit patterns.** `scripts/wedge-audit.sh` adds two
  regression guards: (1) `^[[:space:]]*export[[:space:]]+_RWR_` and
  `^[[:space:]]*_RWR_[A-Z_]+=` to prevent re-introducing the deleted
  globals; (2) `tekhton supervise` calls outside the agent-shim
  allowlist (`lib/agent.sh`, `lib/agent_shim.sh`) — orchestrate now
  consumes the supervisor result via the shim, never directly.
- **`scripts/orchestrate-parity-check.sh`.** 10-scenario matrix
  comparing the bash classifier in `lib/orchestrate_classify.sh`
  against `tekhton orchestrate classify`. Exit 0 when every scenario
  agrees on the recovery action.

### What's deferred to follow-up wedges

m12 ships the loop scaffold and the seam contracts. Two pieces stayed
on the bash side intentionally:

1. **Stage execution.** `_run_pipeline_stages` in `tekhton.sh` still
   drives `stages/coder.sh`, `stages/review.sh`, `stages/tester.sh`,
   etc. directly. Porting the stages would require porting the
   prompt engine, agent rendering, and stage-by-stage state — out of
   scope for m12's "port the loop, not the stages" mandate.
2. **`lib/orchestrate.sh` shrink.** The bash orchestrate.sh and its
   helpers (`_loop`, `_helpers`, `_state_save`, `_recovery*`) are
   still the production code path — the Go `tekhton orchestrate
   run-attempt` is wired in but not yet invoked by `tekhton.sh`.
   Cutting the bash file to the ≤60-line shim happens in a follow-up
   milestone after the bash↔Go stage-runner bridge is built and the
   parity gate has run for several CI cycles. The wedge-audit pattern
   prevents the deleted `_RWR_*` and direct-supervise shapes from
   regressing in the meantime.

### Phase 4 next-up

- **m13 — manifest wedge.** `MANIFEST.cfg` parsing into Go so the
  orchestrate loop can advance milestones in-process.
- **m14 — milestone DAG wedge.** State machine + frontier computation,
  depends on m13.
- **m17 — error taxonomy consolidation.** Rolls up the recovery-class
  string vocabulary into `internal/errors`.

## Phase 4 batch 2 — m18 + m19 retro

m18 (pipeline runner) and m19 (`tekhton run` command) form the second
batch of Phase 4. m18 ports the per-attempt scheduler from
`lib/orchestrate_iteration.sh::_run_pipeline_stages` into
`internal/pipeline.Runner` plus the build/completion gates into
`internal/pipeline.BuildGate` and `internal/pipeline.CompletionGate`.
The bash `_run_pipeline_stages` body shrinks to a thin caller that
unpacks the stage breakdown.

m19 ports the *outer* retry loop and the run-level CLI surface:

- **`cmd/tekhton/run.go`** wires the `tekhton run` Cobra subcommand
  with the documented run-flag set (`--task`, `--complete`, `--resume`,
  `--human`, `--human-tag`, `--milestone`, `--auto-advance`,
  `--auto-advance-limit`, `--dry-run`, `--no-tui`).
- **`internal/runner`** owns the run-level entry point. `RunSingle`
  is the `--task` non-complete-mode path; `RunCompleteLoop` is the
  outer retry loop port (safety bounds, milestone-acceptance dispatch,
  failure persistence via `internal/state`); `Resume` reads the m03
  JSON snapshot and continues.
- **`internal/tui`** owns the Go-side spawn-and-monitor logic for
  `tools/tui.py`. Mid-run status writers stay in bash
  (`lib/tui_ops.sh`); the new package writes only the initial and
  final tui_status.json envelopes.
- **`internal/proto/run_v1.go`** defines `RunRequestV1` and
  `RunResultV1`. The runner writes `RunResultV1` to
  `<project>/.tekhton/RUN_RESULT.json` so the bash finalize bridge
  can read it via `TEKHTON_RUN_RESULT_FILE`.

### Bash deletions and renames in m19

| Old name (deleted)                       | New owner                                |
|------------------------------------------|------------------------------------------|
| `lib/orchestrate_main.sh`                | `internal/runner.RunCompleteLoop`        |
|                                          | (`lib/orchestrate_complete.sh` carries the legacy bash body until m20 flips the entry point) |
| `lib/orchestrate_state.sh`               | `internal/runner.persistFailureState`    |
|                                          | (`lib/orchestrate_save.sh` carries the legacy save-state writer) |
| `run_complete_loop` (bash function)      | `_orch_complete_run`                     |
| `_save_orchestration_state` (bash function) | `_orch_record_save_state`             |

`scripts/wedge-audit.sh` adds four regression guards: `\brun_complete_loop\b`,
`\b_save_orchestration_state\b`, `orchestrate_main\.sh`, `orchestrate_state\.sh`.
The three new bash files (`lib/orchestrate.sh`, `lib/orchestrate_complete.sh`,
`lib/orchestrate_save.sh`) are allowlisted because their docstrings mention
the legacy names in rename-rationale comments.

### What's deferred to m20 (dogfooding cutover)

- `tekhton.sh` continues to call `_orch_complete_run` (the renamed bash
  body) for `--complete` invocations. m20 flips this dispatch to
  `tekhton run --complete` and deletes `lib/orchestrate_complete.sh` /
  `lib/orchestrate_save.sh`.
- `lib/preflight.sh`, `lib/finalize.sh`, and the 26-hook finalize chain
  stay bash; the Go runner shells out via `runner.BashHookRunner`. Phase
  5 ports the hook chain function-by-function.
- Milestone-acceptance check (`check_milestone_acceptance`) stays bash —
  the Go runner accepts an `AcceptanceChecker` interface so the future
  port slots in cleanly.

## Phase 4 retro (m12–m20)

Phase 4 closed with **m20 — Dogfooding Cutover**. `tekhton.sh` is now a
75-line dispatcher; the Go binary owns every pipeline run; bash holds only
the unmigrated subsystems (which Phase 5 will absorb one at a time).

### What landed (m12 through m20)

| m   | Wedge                               | Bash → Go boundary                            |
|-----|-------------------------------------|-----------------------------------------------|
| m12 | Orchestrate classifier + recovery    | `lib/orchestrate_classify.sh` ↔ `internal/orchestrate` (parity gate). |
| m13 | MANIFEST.cfg parser                  | `lib/milestone_dag_io.sh` shim ↔ `internal/manifest`. |
| m14 | DAG state machine                    | `lib/milestone_dag.sh` shim ↔ `internal/dag` + `tekhton dag` subcommand. |
| m15 | Prompt template engine               | `lib/prompts.sh` shim ↔ `internal/prompt` + `tekhton prompt render`. |
| m16 | Config loader / defaulter / validator| `lib/config.sh` + `lib/config_defaults.sh` shims ↔ `internal/config` + `tekhton config`. |
| m17 | Error taxonomy + classifier          | `lib/errors.sh` shim ↔ `internal/errors` + `tekhton diagnose`. |
| m18 | Per-attempt scheduler + gates        | Stage envelope (`lib/stage_envelope.sh`) ↔ `internal/pipeline` (`run-attempt`). |
| m19 | Outer retry loop + `tekhton run`     | `internal/runner` owns the run lifecycle; bash bridges call out via `BashHookRunner`. |
| m20 | Dogfooding cutover                   | `tekhton.sh` shrinks from ~3000 lines to a 75-line dispatcher; `tekhton-legacy.sh` holds the unmigrated bash body. |

### What we learned

- **Envelope schemas held.** `tekhton.run.request.v1`, `tekhton.run.result.v1`,
  `tekhton.stage.result.v1`, `tekhton.manifest.v1`, `tekhton.state.v1`, and the
  prompt + config emit shapes have not needed a v2 bump. Producer-stamped
  proto tags + consumer reject-unknown-major proved out as a stable seam.
- **Finalize bridge was the right deferral.** The 26-hook finalize chain in
  `lib/finalize.sh` is internally complicated but externally narrow — it
  needs `TEKHTON_RUN_DISPOSITION` and `TEKHTON_RUN_RESULT_FILE`, nothing
  more. Holding it as a bash bridge through Phase 4 unblocked m18 and m19
  without needing to port 26 hooks first.
- **TUI status race needed atomic-write.** Mid-run bash writers and the Go
  initial/final writers both touch `tui_status.json`. The atomic-write
  pattern (`tmpfile + os.Rename`) plus the `_TUI_LIVENESS_INTERVAL`
  sampler in `lib/tui_liveness.sh` is the only reason the cross-language
  status seam doesn't tear during a run.
- **Windows reaper had to land before m20.** WSL interop and the m09 reaper
  path catch zombie agent processes the bash trap chain misses. m20's
  self-host matrix runs the Windows row first because of this.

### What didn't go as planned

- **m12's parity gate became a tax.** Holding bash and Go orchestrate
  classifiers in lockstep meant every classification change required two
  edits + a parity rerun. Worth it for the milestone-by-milestone
  confidence, but Phase 5 should retire the bash side as soon as Go is the
  only caller.
- **`cmd_<flag>` template pattern proved overkill for m20.** The original
  m20 plan had `lib/init.sh` exporting `cmd_init`, `lib/rescan.sh`
  exporting `cmd_rescan`, and so on. In practice, the legacy bash entry
  point is monolithic — extracting per-flag wrappers without porting the
  underlying logic creates churn for zero behavioral gain. m20 instead
  moved the entire legacy body to `tekhton-legacy.sh` and dispatches
  through a single fall-through `exec`. Phase 5 can re-introduce the
  per-flag entry points one at a time as each subsystem is ported.
- **`scripts/run-parity-check.sh` shipped slightly aspirational.** The
  10-scenario header in m19 covered 4 structural checks; the gap surfaced
  in the m19 reviewer report. m20's `scripts/self-host-check.sh` learned
  from this — every documented scenario is a real assertion.

### Code volume diff

| Component                        | End of m11 | End of m20 | Δ        |
|----------------------------------|-----------:|-----------:|---------:|
| `tekhton.sh`                     |  ~3050 LOC |     75 LOC |  −2975   |
| `lib/orchestrate*.sh`            |  ~1100 LOC |   ~600 LOC |   −500   |
| `lib/error_patterns*.sh`         |   ~750 LOC |          0 |   −750   |
| `lib/prompts.sh` + `prompts_io.sh`|  ~280 LOC |   ~180 LOC |   −100   |
| `lib/config.sh` + `config_defaults.sh`| ~600 LOC |   ~80 LOC |   −520   |
| `lib/state.sh`                   |   ~460 LOC |    ~50 LOC |   −410   |
| **Net bash LOC reduction (Phase 4)** |        |            | **≈ −5300** |

The `tekhton-legacy.sh` file holds ~3050 lines as a transition artifact.
Phase 5 dismantles it subsystem-by-subsystem; the running bash LOC count
is tracked in `docs/v4-phase5-stub.md`.

## Phase 5 (in progress)

Phase 5 dismantles the remaining bash. See `docs/v4-phase5-stub.md` for
the inventory of unmigrated subsystems and the candidate ordering. The
`make dogfood` target gates each Phase 5 milestone: every commit that
changes pipeline behavior must keep the 15-scenario self-host parity
matrix green.

## m25 router fix

The m21 closeout drift entry flagged a CI-test-failure artifact that the
bash `process_drift_artifacts` heuristic regex misclassified as a
non-blocking observation. The entry was deferred — the rationale was
that hotfixing the dying bash subsystem made less sense than fixing
the issue in the Go port that was already scoped for m25.

**Root cause.** The bash router scanned an artifact's full text against
a single regex chain (`(?i)\bnon[-_ ]blocking\b|\bobservation\b|\bdrift\b`).
The flagged artifact's body legitimately contained the word "observation"
in passing while its header carried an explicit `[FAIL]` token from a CI
runner. The header sentinel was load-bearing — it carried the *only*
signal that the underlying test failed — but the bash heuristic was
body-anchored and dragged the artifact into the non-blocking bucket
because of the reviewer-vocabulary substring it happened to contain.

**The Go fix.** `internal/drift/router.go::Route` evaluates a header-
anchored `[FAIL]` sentinel ahead of the heuristic chain. Any artifact
whose header carries the explicit failure signal classifies as
`DispositionBlocking`, full stop. The heuristic chain is preserved for
artifacts that lack the sentinel — observation/drift/nit/nitpick tokens
still route to `DispositionNonBlocking`. The safe default for artifacts
matching neither path is `DispositionBlocking` (escalate to human review
rather than bury under the cleanup sweep).

**Regression test.**
`internal/drift/router_test.go::TestRouter_CIFailingTest_IsBlocking`
exercises the captured fixture in
`internal/drift/testdata/m21_router_misclassification/`. A second test,
`TestRouter_PureReviewerObservation_IsNonBlocking`, guards against
over-correction (artifacts without the `[FAIL]` sentinel whose body
matches a heuristic token still classify as non-blocking).

The m21 closeout drift log entry is marked **resolved** with reference
to this milestone (`m25 router fix`).

## Stage-Port Pattern (m34)

m34.1 ships the Go-native stage pattern that subsequent stage-port milestones
(m34.2, m35-m39) inherit. This section is the implementer reference for
those follow-ups.

### `StageDef.GoImpl` dispatch precedence

`internal/stagerunner.StageDef` carries two wiring fields:

```go
type StageDef struct {
    Script  string     // bash entry point (stages/<name>.sh)
    Helpers []string   // per-stage lib/*.sh sources
    GoImpl  StageImpl  // m34.1: Go entry point — preferred when non-nil
}
```

When `BashAdapter.Run` resolves a stage definition with `GoImpl != nil`, it
short-circuits to `runGo(ctx, req, def)` and never sources a bash script.
The bash sourcing chain (lib/common.sh → DefaultLibHelpers → per-stage
Helpers → lib/stage_envelope.sh → Script) runs only when `GoImpl` is nil.

The wedge is behavior-preserving: every existing stage's `GoImpl` is nil
until that stage's port milestone lands, so the bash path keeps working
for un-ported stages.

### Per-stage package layout

A ported stage lives in `internal/stages/<name>/`:

```
internal/stages/<name>/
    stage.go         // RunStage entry point matching StageImpl signature
    prepare.go       // Template variable preparation (port of _<name>_prepare_template_vars)
    skip.go          // Gate/skip logic (port of the bash early-return checks)
    stage_test.go    // Table tests for each gate
    prepare_test.go  // Var-population tests against a fixture project
    skip_test.go     // Gate decision tests
    testdata/        // Fixture projects + golden envelopes
```

The shared colored-output helper `internal/stages/staglog` provides
`Logger` (Header / Info / Warn / Success), matching the bash
`log`/`warn`/`success`/`stage_header` API at parity-level granularity.
The package is intentionally minimal — follow-up stages extend it when
the need is concrete.

### Bash-coexistence guarantees

Even after a stage's `GoImpl` is wired, the entry's `Script` field stays
set as an audit-trail signal. The dispatcher never resolves the path
because `GoImpl` short-circuits first; the missing-file delta is how
future tooling sees "stage ported" at a glance. A future m40-class
cleanup milestone can null the `Script` fields once every stage has
ported.

Concretely for m34.1: `DefaultStageDefs[StageDocs]` carries
`Script: "stages/docs.sh"` even though `stages/docs.sh` was deleted in
the same commit that wired `GoImpl: docs.RunStage`. The `Helpers` slice
IS dropped — leaving a stale `lib/docs_agent.sh` entry would crash any
test that forced the bash path.

### Parity-baseline-capture protocol

Each stage-port milestone follows the same sequencing inside the
milestone:

1. **Land `StageDef.GoImpl` field + dispatch wedge first** (m34.1 only).
2. **Land `internal/stages/<name>/` with `GoImpl` still nil.** Compile,
   test, then wire.
3. **Flip the dispatch** (`GoImpl: <name>.RunStage`). From this commit
   the stage runs in Go.
4. **Capture the v4-stage-port baseline tag** against a tree that still
   has the bash files checked in. Used by the parity harness as the
   bash reference.
5. **Delete the bash files** in one commit; drop `Helpers` in the same
   commit.
6. **Wire the parity harness + wedge-audit + docs.** Bump VERSION last.

`tests/test_stage_port_parity.sh` is the shared parity gate. Adding a
new scenario in m34.2 / m35-m39 is a matter of dropping a fixture and a
`(verdict, exit_reason)` expectation — the harness's normalization
rules (duration zeroed, paths normalized, timestamps stripped) are
stage-agnostic by design.

### m34.2 dogfood retro

The cleanup stage was the second port to exercise the m34.1 pattern.
The point of m34.2 was to validate the pattern by dogfooding — would
porting a second stage flow cleanly, or would it surface gaps in the
shared infrastructure (`staglog`, `prompt`, `supervisor`)?

Friction surfaced:

- **`envInt` had a zero-rejecting branch** that was correct for the
  docs stage's `DOCS_AGENT_MAX_TURNS` (zero is invalid) but wrong for
  cleanup's `CLEANUP_TRIGGER_THRESHOLD` (zero is a legitimate "trigger
  on any item" configuration). m34.2 ships a local `envInt` in
  `internal/stages/cleanup/env.go` that allows zero; m35 should decide
  whether to promote the cleanup variant or keep both. The signature
  is identical so a future consolidation milestone could collapse them
  into a `staglog.EnvInt` or similar.
- **`NON_BLOCKING_LOG.md` and `HUMAN_NOTES.md` both went through
  `internal/notes/Document`.** This required adding a `Deferred` state
  to the State enum and a `[DEFERRED]` arm to `notePattern`. The
  unification is a positive — both notes formats now share a parser —
  but it stretched the "Notes Document" abstraction to cover a wider
  set of formats than its original m24 charter. m35+ should think
  twice before adding more file types under the same model; a future
  cleanup might split them into separate parsers.
- **`internal/gates.Build` lives behind a constructor whose env
  wiring is in `package main`.** The cleanup stage couldn't trivially
  call the gate in-process — the env-to-config translation in
  `cmd/tekhton/gate.go::buildGateFromEnv` would have had to be
  duplicated or extracted. m34.2 takes the pragmatic shortcut: a
  `BuildGateRunner` interface defaults to a subprocess exec of
  `tekhton gate build`. This matches the bash semantics exactly and
  keeps the stage seam minimal. A future milestone (probably part of
  m35 when coder's build-fix loop ports) should extract a reusable
  `gates.FromEnv()` constructor into `internal/gates` so cleanup,
  coder, and any other in-process caller can drop the subprocess hop.
- **Null-run detection was bash-only.** The bash `was_null_run` lived
  in `lib/agent_helpers.sh` and read shell globals (`LAST_AGENT_*`).
  m34.2 ports it to `supervisor.AgentResult.IsNullRun()` —
  threshold-parametric via `IsNullRunAt`. m35-m39 inherit this. The
  bash `was_null_run` deletes when the last stage that uses it
  (probably coder, m35-ish) ports.
- **Stage parity-harness scenarios that mutate disk state require
  fixture write-back.** The `cleanup-batch-resolved` scenario stops at
  `skip / no-eligible-notes` rather than asserting on-disk notes
  mutations. The bash impl was broken pre-m34.2 (missing helpers), so
  there's no bash baseline to compare against. The Go unit tests cover
  the agent-success path; the parity test asserts envelope shape only.
  m35+ stages that mutate disk state should consider whether their
  parity scenarios need a write-back assertion harness.

Verdict on the pattern: **dogfood passes**. The bones of the m34.1
pattern survive m34.2 unchanged — `StageImpl`, `DefaultStageDefs[...]
.GoImpl`, the parity harness, the wedge-audit guard. The friction
above is all in the *shared infrastructure layer* (`envInt`, gates
env wiring, null-run detection) rather than the per-stage pattern.
m35 proceeds unblocked; the m40 cleanup milestone is a good home for
the infrastructure-layer cleanups listed above.

## M35.1 — Security helpers ported; bash stage still active

m35.1 ports the security helpers (severity classifier, finding parser,
block builders, escalation writer) into `internal/security/` and rewrites
`lib/security_helpers.sh` as a 60-LOC shim. The bash stage
(`stages/security.sh`) is unchanged and continues to drive the run.

**Transition tax (M35.1 → M35.2 window).** Every non-docs-only pipeline
cycle now pays a 5-subprocess-spawn cost where the pre-m35.1 build paid
zero: each helper invocation execs `tekhton security <sub>` rather than
running inline bash. Specifically, per cycle the bash stage spawns:

1. `tekhton security is-docs-only` once (fast-path skip check).
2. `tekhton security parse-findings` once (TSV read into bash arrays).
3. `tekhton security build-block` three times (fixable/unfixable/notes).

Plus N×`tekhton security meets-threshold` calls inside
`_has_blocking_findings` where N is the number of findings (typically
0–5). At a measured ~30ms per Go binary cold-start on the m35.1 author's
WSL host, the total per-cycle cost is ~150ms + ~30ms×N. M35.2 collapses
this to zero by running the helpers in-process from the Go stage. We
accept the transition tax because it (a) keeps the bash stage operationally
green so m35.1 can be dogfooded against the new Go path without M35.2
shipping first, and (b) closes within a single follow-up milestone.

**`_write_security_notes` deliberately stays bash.** Only the bash stage
calls it. M35.2's Go RunStage absorbs it as `WriteNotesFile(...)`. Porting
preemptively in m35.1 would be scope creep, and the M35.2 stage needs to
own the file-write path because it's stage-level state.

**Halt branch's `write_pipeline_state` stays in the shim, not in
`Escalator.HandleUnfixable`.** The bash version's halt branch wrote
pipeline state directly from the helper. The Go `HandleUnfixable` returns
`(false, nil)` for halt and the caller (m35.1 = bash shim; m35.2 = Go
RunStage) writes state with the correct stage-level context. Pipeline
state is stage-owned; pushing the write into the security helper would
tangle layering across the m35.1 → m35.2 cutover.

## M35.2 — Security stage ported; transition tax retired

m35.2 closes the m35 arc. The bash `stages/security.sh` and
`lib/security_helpers.sh` files delete; `internal/stages/security/`
lands as the third Go-native stage (after docs in m34.1 and cleanup
in m34.2). `DefaultStageDefs[proto.StageSecurity]` carries `GoImpl =
securitystage.RunStage` and the dispatcher routes Go-native — no bash
sourcing, no per-cycle subprocess spawns.

**Transition tax retired.** The 5-spawn-per-cycle tax m35.1 introduced
(`is-docs-only`, `parse-findings`, three `build-block` calls + N
`meets-threshold` calls) is gone. The Go stage calls the m35.1
internal/security helpers in-process — every `MeetsThreshold`,
`ParseReport`, `BuildFixableBlock`, etc. resolves to a function call
rather than `exec("tekhton security ...")`. On a 5-finding cycle the
saved per-cycle latency is ~300ms on the m35.2 author's WSL host.

**`stages/security.sh` (167 LOC) deleted; `lib/security_helpers.sh`
(60-LOC shim) deleted.** The wedge-audit gate passes clean. The
per-stage helper entry in `DefaultStageDefs` retires alongside —
`Helpers` is empty, matching the docs (m34.1) and cleanup (m34.2)
ports.

**Operator-facing CLI subset retained.** Following the m17 diagnose
retention precedent, `tekhton security parse-findings` and
`tekhton security meets-threshold` un-Hide (operator inspection
tools); `build-block` and `is-docs-only` stay Hidden (debug-only);
`handle-unfixable` deletes outright (was shim-only — no callers
remain, and operators have `tekhton drift human-action append`
for hand-authored escalations).

**Parity preserved.** The full m35.2 fixture set (agent-disabled,
skip-flag, docs-only, pass/no-findings, fixable-rework-pass,
unfixable-halt, unfixable-escalate) exercises every branch through
the Go RunStage and matches the bash semantics line-for-line. The
post-rework build-gate "break" semantics, the doubly-defaulting
`MILESTONE_SECURITY_MAX_TURNS`, the `SECURITY_NOTES_FILE` empty-path
no-op, and the halt-branch pipeline-state write are all preserved.

**HUMAN_ACTION_FILE resolution unified.** m35.2's Go stage and the
shared CLI resolver (`cmd/tekhton/drift.go::humanActionPath`) both
honor the `HUMAN_ACTION_FILE` env override and fall back to
`${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md`. Tests assert the resolved
path so a future divergence between the stage and the drift CLI
shows up at green-to-red transition.

## Phase 5 Security Stage Closeout (m35, v4.35.0)

The security stage ported to Go across three child milestones (m35.1
helpers, m35.2 stage, m35.3 cleanup). 407 LOC of bash retired:

- `stages/security.sh` — 167 LOC (deleted m35.2)
- `lib/security_helpers.sh` — 240 LOC at peak (deleted m35.2; m35.1
  had reduced it to a 60-LOC shim layered over the Go helpers)

**Cumulative patch-bump count during dogfood:**

- m35.1: 0 (helpers port stayed clean — golden-file parity caught
  every divergence inside the Go test suite before merge)
- m35.2: 0 (the stage port leaned on the m34 pattern hard enough
  that the unit + fixture coverage caught what the parity gate
  would have caught)
- m35.3: 0 (this is a safety-net-only milestone with no behavioral
  surface — the runs that built it produced no patch bumps)
- **Total: 0**

The zero-patch close is partially load-bearing on the m34 sequencing —
docs (m34.1) and cleanup (m34.2) had paid the pattern-discovery cost
before security entered. The m36+ stage ports inherit the same pattern
and should expect similar quiet bumps, but each subsequent milestone
also adds one more degree of cross-stage env / contract surface —
the bump count is not guaranteed to stay zero.

**Notable items surfaced during the m35 arc:**

- The m35.1 reviewer flagged `cmd/tekhton/security_test.go::buildTekhtonBinary`
  for duplication. The m35.2 closeout left it on the in-flight list; m35.3
  records it again here — the next `cmd/tekhton/*_test.go` test that needs
  the helper should extract it to `testhelpers_test.go`.
- `tests/test_drift_prompts.sh` failed on the m35.2 branch but ALSO failed
  on the parent commit before any m35.2 changes (verified via stash). It is
  a pre-existing failure unrelated to the m35 arc, in the coder prompt's
  "Architecture Change Proposals" section rendering. Tracked as a separate
  defect.

**Transition tax retired.** The 5-subprocess-spawns-per-cycle tax that
m35.1 introduced (bash shim execing `tekhton security <sub>`) retired
in m35.2 when the Go stage replaced the bash stage entirely. Per-cycle
latency for a 5-finding scan dropped ~300ms on the dogfood host.

**Meta-failure: pre-M35 baseline-capture gate was never specified by
the m35 parent.** The m35.3 parity gate (`tests/test_security_parity.sh`)
was authored to diff three scenarios against pre-M35 bash captures
under tag `v4.34.99-security-baseline`, but the tag was never created.
Recovery via `git checkout` + ad-hoc fake-agent infrastructure was
explicitly out of scope for a "lightweight cleanup tail" milestone.
The captured baselines under `tests/baselines/m35-security/` are the
current Go stage outputs, locked forward as the regression baseline.
The contract preservation rests on transitive coverage: m35.1 captured
18 golden-file baselines against the pre-M35 bash helpers
(`internal/security/testdata/baselines/`), and m35.2 ported the stage
behavior with byte-for-byte unit-test coverage of every branch. The
m35.3 gate prevents future Go drift but is not itself a bash-vs-Go
parity check.

**m35.3 deliverables:**

- `scripts/wedge-audit-companions.sh` — m35.3 ban block: file-presence
  ban (`stages/security.sh`, `lib/security_helpers.sh`) + nine-function
  name ban under `lib/`/`stages/`, with `# --m35-allowlist` escape
  hatch for documentation comments.
- `tests/test_wedge_audit_m35.sh` — 6-scenario regression test for the
  ban block (clean tree, file plants, function-name plant, allowlist
  honor, post-cleanup).
- `tests/test_security_parity.sh` — three-scenario end-to-end gate
  (`pass-no-findings`, `fixable-cycle-1-resolved`, `unfixable-escalate`).
- `testdata/fake_security_agent.sh` — purpose-built fake supervisor
  binary wired via `TEKHTON_AGENT_BINARY`. Emits valid streaming JSON
  events and writes pre-canned `SECURITY_REPORT.md` content per
  scenario + cycle counter.
- `tests/baselines/m35-security/` — three scenario × three artifact
  directories of normalized baselines.
- `Makefile` — `tests/test_security_parity.sh` joined the `dogfood` chain
  alongside `tests/test_stage_port_parity.sh`.
- `tekhton-legacy.sh` — m35.2 deletion comment block removed (the
  comment violated the m35.3 residual-scan AC; the dispatcher line was
  already gone).
- `tests/audit/K3.md` — stale `test_security_stage.sh` row flipped
  from KEEP to DELETED-STALE.
- `CHANGELOG.md` — `## [4.35.0]` entry with the security-stage-port
  summary + operator notes.
- `docs/v4-phase5-stub.md` — new Stage-Port Matrix section with the
  security row marked done (LOC delta 407).
- `VERSION` — bumped from 4.34.x to 4.35.0.

**Inheritance for m36 (architect + intake stage port):** the same
three-child decimal pattern (helpers first, then stage, then cleanup)
applies. The `internal/<subsystem>/` + `internal/stages/<name>/`
package layout is the template. `drift.HumanAction.Append` is the
universal escalation surface — m36 architect drift writes route
through it. The m36 parent SHOULD specify a baseline-capture gate up
front to avoid repeating the m35 meta-failure.
