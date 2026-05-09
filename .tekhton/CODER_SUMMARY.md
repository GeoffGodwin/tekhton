# Coder Summary
## Status: COMPLETE

m20 — Dogfooding Cutover (Phase 4 batch 2, third and final wedge).

## What Was Implemented

### Goal 1: `tekhton.sh` shrinks to a 75-line dispatcher

- **`tekhton.sh`** (modified, was ~3050 lines, now 75) is a pure dispatcher:
  bash version guard, path resolution, `--version`/`-v` handling
  (in-process), `--help`/`-h` routing to `tekhton run --help`, run-flag
  detection (anywhere in argv), and a fall-through `exec bash
  "${TEKHTON_HOME}/tekhton-legacy.sh" "$@"` for everything else.
- Run-flag detection covers the documented set: `--task`, `--complete`,
  `--resume`, `--human`, `--milestone`, `--auto-advance`, `--dry-run`,
  `--no-tui`. When any of these appears at any argv position, the
  dispatcher exec's `${TEKHTON_BIN} run "$@"`.
- `_tekhton_ensure_bin` builds the Go binary on demand if `bin/tekhton`
  is missing — first-run convenience so a fresh clone doesn't fail to
  dispatch run-flags.
- `TEKHTON_DEBUG_DISPATCHER=1` traces the routing decision (one line per
  exec) — the diagnostic the milestone "Watch For" called out.
- **`tekhton-legacy.sh`** (NEW) holds the V3 entry-point body that has
  not yet been ported to Go. Header comment marks it as a transition
  file, exempt from the 300-line ceiling per the m20 rationale, with a
  Phase 5 inventory at `docs/v4-phase5-stub.md`.

### Goal 2: 15-scenario self-host parity matrix

- **`scripts/self-host-check.sh`** (modified, was ~88 lines, now ~190
  lines including the matrix). Builds the Go binary, prepends `bin/` to
  PATH, asserts each documented run-flag combination routes to
  `tekhton run` and each legacy flag routes to `tekhton-legacy.sh`.
  The matrix uses `TEKHTON_DEBUG_DISPATCHER=1` to capture the dispatcher's
  routing trace and points `TEKHTON_BIN` at a fake stub for routing
  scenarios so the real binary's checkpoint bridge doesn't `git stash`
  the working tree mid-test.
- Scenarios 01–15 cover: trivial task, build-gate retry, review rework,
  security gate, tester baseline, complete loop happy path, complete
  with retries, MAX_PIPELINE_ATTEMPTS, AUTONOMOUS_TIMEOUT, single
  milestone, milestone+complete+auto-advance, resume, human+tag,
  no-tui, dry-run.
- Legacy invariants (L1–L5) confirm `--status`, `--metrics`, `--rollback`,
  `--diagnose`, `--report` continue to route to `tekhton-legacy.sh`.
- Version invariants (V1–V3) confirm `tekhton --version`,
  `tekhton.sh --version`, and PATH resolution all match `VERSION`.
- `TEKHTON_SELF_HOST_DRY_RUN=1` enables an additional live `--dry-run`
  smoke (gated because it needs Claude CLI auth).

### Goal 3: `make dogfood` Makefile target

- **`Makefile`** (modified) adds `make self-host` (runs the parity
  matrix) and `make dogfood` (runs `make self-host` plus a banner
  reminding the operator that post-m20 milestones run via `tekhton
  run --milestone <id>`). `dogfood` depends on `self-host` which depends
  on `build`, so a single command rebuilds, tests, and gates the cutover.

### Goal 4: Phase 4 retro and Phase 5 stub

- **`docs/go-migration.md`** (modified) gets a "Phase 4 retro (m12–m20)"
  section: per-milestone wedge map, what we learned (envelope schemas
  held; finalize bridge was the right deferral; TUI status race needs
  atomic-write; Windows reaper was a pre-req for m20), what didn't go
  as planned (m12 parity gate became a tax; `cmd_<flag>` template was
  overkill; `run-parity-check.sh` was aspirational), code volume diff
  (~5300 lines of bash retired across Phase 4), and a forward pointer
  to Phase 5.
- **`docs/v4-phase5-stub.md`** (NEW) inventories every remaining bash
  subsystem with a port/shim/leave disposition (40 entries), candidate
  ordering for Phase 5 milestones (m21–m28), open questions (acceptance
  check residency, `tekhton-legacy.sh` lifetime, reaper consolidation,
  prompt template residency), and a bash LOC budget tracker.

### Goal 5: Version bump and tag

- **`VERSION`** → `4.20.0`. The cutover commit will be tagged
  `v4.20.0-dogfood` per the milestone description.
- **`README.md`** updated: subtitle now reads "v4.20.0 — Dogfooding
  Cutover (Go runtime)" and a callout block notes the dispatcher
  cutover and points at `docs/v4-phase5-stub.md`.

### Goal 6: Wedge-audit ban patterns + dispatcher tests

- **`scripts/wedge-audit.sh`** (modified) gains three regression
  guards: `\b_run_pipeline_stages\b`, and source-line bans on
  `orchestrate_complete\.sh` / `orchestrate_save\.sh` so new lib files
  cannot accidentally re-introduce the legacy retry chain.
  Allowlists `lib/orchestrate_aux.sh`, `lib/orchestrate_classify.sh`,
  `lib/orchestrate_iteration.sh` for their existing rationale-comment
  references to `_run_pipeline_stages` and the cross-source.
- **`tests/test_dispatcher.sh`** (NEW) exercises 31 routing scenarios
  covering every documented run-flag (leading and trailing positions),
  `--help`/`-h`, `--version`/`-v`, every documented legacy flag, and
  bare positional task strings. Uses a fake `TEKHTON_BIN` stub to
  avoid triggering the real Go runner's checkpoint bridge during tests.

### Goal 7: Test maintenance

The cutover moved the V3 entry-point body from `tekhton.sh` to
`tekhton-legacy.sh`. Every test that grep'd `tekhton.sh` for content
that legitimately moved was updated to grep `tekhton-legacy.sh`:

- `tests/test_dedup_callsites.sh` — Suite 3 source-grep.
- `tests/test_docs_site.sh` — `--docs` flag handler grep.
- `tests/test_drift_resolution_sourcing_convention.sh` — comment grep
  (5 sites).
- `tests/test_gates_extraction.sh` — Test 5 source-grep.
- `tests/test_human_orchestration_bounds.sh` — Tests 4 + 5 invoke
  `tekhton-legacy.sh` directly to exercise the bash-side `--human`
  validation that the dispatcher now exec's around.
- `tests/test_milestone_split.sh` — integration grep (1 site).
- `tests/test_milestones_flag_smoke.sh` — `--help` test now matches the
  Go formatter's output (split `--auto-advance` and
  `--auto-advance-limit`); `--help --all` keeps the legacy `[N]`
  notation grep against the legacy script.
- `tests/test_nonblocking_log_fixes.sh` — dashboard sync + intake-budget
  greps.
- `tests/test_tui_lifecycle_invariants.sh` — invariant 7 audits both
  `tekhton.sh` and `tekhton-legacy.sh`; invariants 9d/9e check the
  consumer ordering in `tekhton-legacy.sh` (which still has the
  preflight/intake post-stage emit blocks).
- `tests/test_watchtower_html.sh` — `inbox.sh` source-grep.

## Root Cause (bugs only)

N/A — milestone implementation, not a bug fix.

## Files Modified

### Created (NEW)
- `tekhton-legacy.sh` (NEW) — V3 entry-point body, transition file.
- `tests/test_dispatcher.sh` (NEW) — 31-scenario dispatcher routing test.
- `docs/v4-phase5-stub.md` (NEW) — Phase 5 bash-deprecation inventory.

### Modified
- `tekhton.sh` — shrunk from ~3050 lines to 75; dispatcher only.
- `scripts/self-host-check.sh` — expanded to 15-scenario parity matrix.
- `scripts/wedge-audit.sh` — three new regression patterns; three new
  allowlist entries (`orchestrate_aux.sh`, `orchestrate_classify.sh`,
  `orchestrate_iteration.sh`).
- `Makefile` — adds `make self-host` and `make dogfood` targets.
- `VERSION` — `4.19.0` → `4.20.0`.
- `README.md` — subtitle bumped to v4.20.0; cutover callout block.
- `docs/go-migration.md` — Phase 4 retro section + Phase 5 forward
  pointer.
- `tests/test_dedup_callsites.sh` — Suite 3 grep target.
- `tests/test_docs_site.sh` — `--docs` flag handler grep target.
- `tests/test_drift_resolution_sourcing_convention.sh` — grep target
  rewrite.
- `tests/test_gates_extraction.sh` — Test 5 grep target.
- `tests/test_human_orchestration_bounds.sh` — direct
  tekhton-legacy.sh invocation.
- `tests/test_milestone_split.sh` — integration grep target.
- `tests/test_milestones_flag_smoke.sh` — Go formatter help
  expectation.
- `tests/test_nonblocking_log_fixes.sh` — two grep targets.
- `tests/test_tui_lifecycle_invariants.sh` — invariant 7 + 9d/9e
  scope.
- `tests/test_watchtower_html.sh` — inbox.sh grep target.

## Architecture Change Proposals

### `tekhton-legacy.sh` instead of per-flag `cmd_<flag>` wrappers

- **Current constraint**: m20's milestone description shows a
  `cmd_<flag>` template (`source lib/init.sh; cmd_init "$@"`) implying
  per-flag entry-point functions in each lib file.
- **What triggered this**: `cmd_<flag>` functions don't exist in any
  lib file today (verified via `grep -rn '^cmd_'` returning nothing).
  Creating per-flag wrappers requires extracting per-flag pipeline
  orchestration logic from `tekhton.sh`'s monolithic body, which is
  exactly what the milestone "Watch For" section says NOT to do
  ("Don't try to port legacy flags in m20").
- **Proposed change**: move the entire V3 entry-point body to
  `tekhton-legacy.sh` at the repo root. The dispatcher routes run-flags
  via exec to the Go binary; everything else falls through to `exec
  bash tekhton-legacy.sh "$@"`. This preserves byte-for-byte legacy
  behavior without needing to extract per-flag entry points.
- **Backward compatible**: Yes. All flags (`--init`, `--plan`, etc.)
  behave exactly as they did pre-m20. `tekhton.sh --version` continues
  to print `Tekhton X.Y.Z`; `tekhton.sh --help` now invokes
  `tekhton run --help` per the explicit m20 acceptance criterion.
- **ARCHITECTURE.md update needed**: Yes — once Phase 5 lands and
  `tekhton-legacy.sh` is dismantled, the architecture doc's "Layer 1:
  Entry Point" section can document the cutover. Out of scope for m20.

The `cmd_<flag>` pattern in the milestone description was illustrative,
not a hard requirement — the milestone's spirit is "tekhton.sh is a
dispatcher, legacy flag handling is preserved verbatim, Phase 5 collapses
each subsystem one at a time." The `tekhton-legacy.sh` approach satisfies
all five m20 goals and every acceptance criterion while honouring the
"don't port legacy flags in m20" guidance. `docs/go-migration.md` Phase 4
retro records the rationale.

## Docs Updated

- `README.md` — subtitle + dogfooding-cutover callout.
- `docs/go-migration.md` — Phase 4 retro section.
- `docs/v4-phase5-stub.md` — Phase 5 bash-deprecation inventory (NEW).

## Human Notes Status

No human notes (`HUMAN_NOTES.md` items) were provided for this run.

## Observed Issues (out of scope)

- **Pre-existing `scripts/wedge-audit.sh:106` SC2016 info** — first
  flagged in m19. Out of scope.
- **`tests/test_m01_go_module_foundation.sh` T7a — exec bit on
  `scripts/self-host-check.sh`.** The Edit tool drops the executable
  bit on rewrite. The fix that holds across `bash tests/run_tests.sh`
  runs is: ensure the file is `chmod +x` AFTER any final edit lands.
  m20's last-touched state has the bit set; if a future review or
  rework touches the file, the bit must be re-applied.

## Acceptance Criteria Audit

- [x] `wc -l tekhton.sh` reports ≤80 lines (75).
- [x] `tekhton.sh --task`, `--complete`, `--resume`, `--human`,
      `--milestone`, `--auto-advance`, `--dry-run`, `--no-tui` all exec
      `tekhton run` (verified by `tests/test_dispatcher.sh`).
- [x] `tekhton.sh --init`, `--rescan`, `--draft-milestones`, `--report`,
      `--status`, `--metrics`, `--migrate`, `--health`, `--rollback`,
      `--notes` route to `tekhton-legacy.sh`
      (verified by `tests/test_dispatcher.sh`).
- [x] `tekhton.sh --version` prints `Tekhton 4.20.0` (in-dispatcher
      handling).
- [x] `tekhton.sh --help` runs `tekhton run --help`.
- [x] `tekhton.sh --milestone m21 --complete` (run-flag in trailing
      position) dispatches to `tekhton run`
      (verified by `tests/test_dispatcher.sh::trailing-complete`).
- [x] `scripts/self-host-check.sh` exits 0 on Linux (target matrix
      execution covers darwin/windows in CI; m20 verifies linux/amd64
      locally).
- [x] `make dogfood` exits 0.
- [x] `bash scripts/wedge-audit.sh` exits 0
      (246 files audited, 12 allowed shim writers).
- [x] `bash tests/run_tests.sh` passes; `go test ./...` passes.
- [x] `docs/go-migration.md` has a "Phase 4 retro" section with shipped
      milestones, lessons, LOC diff.
- [x] `docs/v4-phase5-stub.md` exists and lists each remaining bash
      subsystem with a one-line disposition.
- [x] `VERSION` reads `4.20.0`.
- [ ] Cutover commit tagged `v4.20.0-dogfood` — pending the merge
      commit. The milestone author / CI handles the tag at merge time.
- [ ] m21 (next V4 milestone) authored after m20 closes — explicitly
      in the m20 milestone description's "Seeds Forward" section, not
      part of m20's code scope.

## Remaining Work

None for the m20 code surface. Tagging `v4.20.0-dogfood` happens at
merge time. m21 authoring is scheduled by the milestone description
to land after m20 closes.
