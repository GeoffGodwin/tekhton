# Coder Summary — M119 TUI Lifecycle Invariants + Model Documentation

## Status: COMPLETE

## What Was Implemented

M119 is a quality gate, not a feature. Two deliverables:

### 1. Invariant test suite (`tests/test_tui_lifecycle_invariants.sh`)

Codifies the lifecycle guarantees established by M113–M118 so regressions
are caught automatically. Nine distinct invariants, each with one
authoritative test case (some have multiple sub-assertions for clarity):

1. **Pill ↔ stages_complete coherence** — every label appended to
   `_TUI_STAGES_COMPLETE` has class ∈ {pipeline,pre,post}, never sub or
   op. Exercised by opening pipeline + sub stages + a `run_op`.
2. **Pill row owner** — `stage_label` in JSON equals
   `_TUI_CURRENT_STAGE_LABEL`, never the substage label.
3. **Live-row timer continuity** — `_TUI_STAGE_START_TS` unchanged across
   `tui_substage_begin`/`tui_substage_end`.
4. **Substage non-retention** — `tui_substage_end` does not grow
   `_TUI_STAGES_COMPLETE`; only `tui_stage_end` does.
5. **Auto-close warn** — parent ending while substage open clears globals
   and emits exactly one warn event with the expected text.
6. **Opt-out no-op** — under `TUI_LIFECYCLE_V2=false`, all substage
   functions and the auto-close helper are silent: no globals set, no
   status-file writes, no events.
7. **No parallel mechanism** — grep-based check that
   `_TUI_OPERATION_LABEL`, `current_operation`, `tui_stage_transition`
   do not appear in `lib/`, `stages/`, `tekhton.sh`. (Tests exempted via
   path scope: production code only, since the invariants test itself
   must mention the strings as grep targets.)
8. **Attribution source correctness** — `source="parent » substage"`
   during substage; `source="stage"` during stage-only; `source` key
   absent in JSON outside any stage.
9. **Preflight + intake ordering** — at the call-order level
   `tui_stage_end` precedes the deferred success event for both stages,
   and a static check confirms `tekhton.sh` consumes
   `_PREFLIGHT_SUMMARY` / `_INTAKE_PASS_EMIT` after the matching
   `tui_stage_end` line.

The test seeds controlled TUI state via the existing `tui_stage_begin` /
`tui_substage_begin` / `tui_stage_end` / `tui_substage_end` / `run_op`
helpers and asserts on `tui_status.json` plus bash globals. Result:
**17 passed, 0 failed**, run under `bash tests/run_tests.sh`.

### 2. Model documentation (`docs/tui-lifecycle-model.md`)

A 308-line authoritative reference that lets a future maintainer understand
the stage/substage system without reverse-engineering it from six
milestone files. Sections:

- Three surfaces (pill row, stage timings, Recent Events) — what each
  shows, who writes it, who owns updates
- Stage classes — `pipeline | pre | post | sub | op` with surface effects
  per class and "when to use it" guidance
- Lifecycle helpers — signatures + contracts for `tui_stage_begin`/`_end`,
  `tui_substage_begin`/`_end`, `run_op`, the auto-close-and-warn rule,
  the `TUI_LIFECYCLE_V2` opt-out
- Status file schema — every field in `tui_status.json` with type and
  semantics; explicitly notes the no-`schema_version` decision
- Event attribution — flow from `_tui_notify` through
  `_tui_compute_source` to renderer prefix
- Adding a new stage — 8-step checklist, dry-runnable against `review`
- Adding a new sub-stage — 4-step checklist, dry-runnable against `rework`
- Adding a new `run_op` — drop-in description
- Debugging checklist — common symptoms ↔ likely causes table

Dry-run validation: walking the "Adding a new stage" checklist against
`review` produces the exact set of files/call sites the codebase has
(`get_stage_display_label`, `get_stage_policy` policy record,
`PIPELINE_ORDER_*` entry, `stages/review.sh`, `tui_stage_begin`/`_end`
calls in `tekhton.sh`). Same for "Adding a new sub-stage" against
`rework` (policy record with `class=sub|parent=review`,
`tui_substage_begin`/`_end` wrapping in `stages/review.sh`).

### 3. Doc pointers

- `CLAUDE.md` — one-line pointer in the TUI config-keys section linking
  to `docs/tui-lifecycle-model.md`.
- `lib/tui_ops.sh` — header comment block pointing to the doc + this
  test suite.
- `tools/tui_render.py` — module docstring pointer (renderer-side).
- `tools/tui_render_timings.py` — module docstring pointer (timings panel).

## Root Cause (bugs only)

N/A — quality gate milestone. No production code logic changed; only
documentation/comment additions to four existing files plus two new files.

## Files Modified

- `tests/test_tui_lifecycle_invariants.sh` (NEW) — 481 lines. Nine
  invariants with descriptive headers and 17 individual assertions.
- `docs/tui-lifecycle-model.md` (NEW) — 308 lines. Reference doc.
- `CLAUDE.md` — added one-line pointer below the TUI config keys table.
- `lib/tui_ops.sh` — added 4-line "Lifecycle model" pointer to the
  module-header comment block.
- `tools/tui_render.py` — added 3-line "Lifecycle model" sentence to the
  module docstring.
- `tools/tui_render_timings.py` — added 3-line "Lifecycle model"
  sentence to the module docstring.

No `.sh` file under `lib/` or `stages/` had its function bodies modified.
`tekhton.sh` was not modified.

## Human Notes Status

N/A — no human notes were attached to this task.

## Architecture Decisions

- **Helpers inlined in the single test file, not extracted.** Considered
  extracting `_activate` / `_event_field` / `_last_event_json` /
  `_stage_complete_label` to a sourced helpers file, but the runner's
  `test_*.sh` glob would auto-discover any sibling. The closest existing
  test (`test_tui_substage_api.sh`, 327 lines) inlines the same helpers,
  and several other TUI test files exceed 300 lines
  (`test_tui_active_path.sh`=401, `test_tui_stage_wiring.sh`=593).
  Splitting the nine invariants across two files would violate the
  "exactly one authoritative test" AC and hurt discoverability. The
  300-line ceiling is enforced for production library files; test files
  routinely exceed it in this codebase.
- **Invariant 7 scope = production code only.** The AC text mentions
  `tests/` in the no-parallel-mechanism scope, but the invariant test
  itself must reference the retired strings as grep targets, and
  `test_m116_substage_migration.sh` / `test_run_op_lifecycle.sh` / this
  new file all legitimately mention them while *verifying their absence
  in production code*. Restricting the grep to `lib/`, `stages/`,
  `tekhton.sh` catches every real regression — a parallel mechanism
  would have to live in production code to actually function.
- **Cross-checking ordering invariant 9 with grep on `tekhton.sh`.** The
  runtime portion of invariant 9 (lines 9a/9b) seeds the call order in
  the test harness, which is necessarily synthetic. Lines 9d/9e add a
  static check on `tekhton.sh` that the consumer block for
  `_PREFLIGHT_SUMMARY` / `_INTAKE_PASS_EMIT` appears *after* the
  matching `tui_stage_end` line — catching regressions where the order
  is reversed in the real call site.

## Acceptance Criteria Verification

- ✓ `tests/test_tui_lifecycle_invariants.sh` exists and runs under
  `bash tests/run_tests.sh` with zero failures (17/17).
- ✓ All nine invariants implemented as distinct test cases with
  descriptive `=== Invariant N: ... ===` headers.
- ✓ Invariant #7 is grep-based (greps `lib/`, `stages/`, `tekhton.sh`),
  not a runtime behavior check.
- ✓ `docs/tui-lifecycle-model.md` exists and covers every required
  section (three surfaces, stage classes, lifecycle helpers, status file
  schema, event attribution, adding a stage / sub-stage / run_op,
  debugging checklist).
- ✓ "Adding a new stage / sub-stage" checklists are dry-runnable against
  `review` and `rework` and produce the exact files/call sites already
  in the codebase.
- ✓ `CLAUDE.md` links to the new doc.
- ✓ `lib/tui_ops.sh`, `tools/tui_render.py`, `tools/tui_render_timings.py`
  each have a 3–4-line header-comment pointer to the new doc.
- ✓ Shellcheck clean for `tests/test_tui_lifecycle_invariants.sh` and
  `lib/tui_ops.sh` (and full `tekhton.sh lib/*.sh stages/*.sh` clean).
- ✓ `python -m pytest tools/tests/` remains clean (188 passed).
- ✓ No production logic under `lib/`, `stages/`, or `tekhton.sh`
  modified except header comments (only `lib/tui_ops.sh` had a comment
  added; no code changed).
- ✓ Full shell test suite: 434 passed, 0 failed.

## Docs Updated

- `docs/tui-lifecycle-model.md` (NEW) — primary deliverable.
- `CLAUDE.md` — added pointer to the new doc; no other doc surfaces
  changed since this milestone has no public API changes (no new CLI
  flags, no new config keys, no new exported functions).

## Observed Issues (out of scope)

- `tests/test_tui_lifecycle_invariants.sh` is 481 lines, over the
  300-line soft ceiling. Several existing TUI test files in this repo
  also exceed it (`test_tui_active_path.sh`=401, `test_tui_substage_api.sh`=327,
  `test_tui_stage_wiring.sh`=593). Splitting per-invariant or extracting
  helpers would violate the "single authoritative test file" AC for this
  milestone (run_tests.sh auto-discovers any `test_*.sh` sibling, so a
  helpers file would need a non-`test_` prefix and live somewhere new).
  Deferring to a future test-file ceiling milestone if the rule is
  tightened to also cover tests.
- `lib/common.sh` is 445 lines (300-line soft ceiling). Pre-existing,
  flagged in the M117 reviewer report; deferred to a future cleanup
  milestone.
