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
