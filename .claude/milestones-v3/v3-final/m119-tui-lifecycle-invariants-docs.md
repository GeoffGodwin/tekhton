# M119 - TUI Lifecycle Invariants + Model Documentation

<!-- milestone-meta
id: "119"
status: "done"
-->

## Overview

M113–M118 reshape how pipeline stages and sub-stages flow through the TUI:
new substage API, scout/rework/architect-remediation migrations, `run_op`
refactor, `tui_stage_transition` removal, Recent Events attribution,
preflight/intake timing fix. Six milestones of structural change.

M119 is the closing milestone of the initiative. Its job is twofold:

1. **Invariants test suite** — codify the lifecycle guarantees that must hold
   at every future commit so regressions are caught automatically.
2. **Model documentation** — a single `docs/tui-lifecycle-model.md` that a
   future maintainer can read to understand the stage/substage system
   without reverse-engineering it from six milestone files.

No production code changes. This is a quality gate.

## Design

### Goal 1 — Invariants test suite

New test file `tests/test_tui_lifecycle_invariants.sh`. Each invariant is a
distinct test case that seeds a controlled TUI state (using the existing
`tui_stage_begin` / `tui_substage_begin` / `tui_stage_end` /
`tui_substage_end` / `run_op` helpers) and asserts on the resulting
`tui_status.json` plus bash globals.

Required invariants:

1. **Pill ↔ stages_complete coherence** — every label appearing in
   `stages_complete` corresponds to a stage whose policy record has
   `class=pipeline|pre|post` (never `sub` or `op`).
2. **Pill row owner** — the active pill label equals `_TUI_CURRENT_STAGE_LABEL`
   (the pipeline stage), never `_TUI_CURRENT_SUBSTAGE_LABEL`.
3. **Live-row timer continuity** — opening and closing a substage inside a
   stage does not alter `_TUI_CURRENT_STAGE_START_TS`.
4. **Substage non-retention** — `tui_substage_end` does not append to
   `_TUI_STAGES_COMPLETE`.
5. **Auto-close warn** — ending a stage while a substage is open auto-closes
   the substage and emits exactly one warn event with the expected text.
6. **Opt-out no-op** — with `TUI_LIFECYCLE_V2=false`, substage functions set
   no globals, produce no status-file writes, and emit no events.
7. **No parallel mechanism** — the strings `_TUI_OPERATION_LABEL`,
   `current_operation`, and `tui_stage_transition` do not appear anywhere
   under `lib/`, `stages/`, `tekhton.sh`, or `tests/` (historical
   milestone docs excepted).
8. **Attribution source correctness** — an event emitted during a substage
   carries `source="parent » substage"`; an event emitted during a stage
   with no substage carries `source="stage"`; an event emitted outside any
   stage carries no `source`.
9. **Preflight/intake ordering** — in the happy path, the
   `stages_complete` update for preflight (and intake) precedes the
   corresponding success event in the ring buffer.

Each invariant is a small, fast test. The suite runs under `tests/run_tests.sh`
and on any CI gate that invokes the existing test runner.

### Goal 2 — Model documentation

New file `docs/tui-lifecycle-model.md`. Target length ~300–500 lines. Audience:
a future maintainer adding a new stage or sub-stage.

Required sections:

- **Three surfaces** — pill row, stage-timings panel (live row + completed
  rows + header), Recent Events. For each: what it shows, who writes it,
  who owns updates.
- **Stage classes** — `pipeline|pre|post|sub|op` from
  `get_stage_policy`. For each class: pill behavior, timings-row behavior,
  live-row ownership, when to use it.
- **Lifecycle helpers** — signatures and contracts for
  `tui_stage_begin`/`_end`, `tui_substage_begin`/`_end`, `run_op`.
  Include the auto-close-and-warn rule and the `TUI_LIFECYCLE_V2` opt-out
  semantics.
- **Status file schema** — fields currently in `tui_status.json` with types
  and semantics. Note that no `schema_version` is used; tolerance is
  per-field.
- **Event attribution** — how `_TUI_CURRENT_SUBSTAGE_LABEL` flows from
  `_tui_notify` to `tui_append_event` to renderer prefix.
- **Adding a new stage** — step-by-step checklist: add to
  `get_stage_display_label`, policy record in `pipeline_order_policy.sh`,
  pipeline order string in `pipeline_order.sh`, lifecycle call sites,
  optional tests.
- **Adding a new sub-stage** — step-by-step: policy record with `class=sub`
  and `parent=…`, `tui_substage_begin`/`_end` pair at call site, no changes
  to pill row or stages_complete logic needed.
- **Adding a new `run_op`** — drop-in; no policy record needed.
- **Debugging checklist** — common symptoms (pill flashes wrong label, live
  row label disagrees with header, stage completed twice, timer resets
  unexpectedly) mapped to likely causes.

### Goal 3 — Link the doc from existing surfaces

- Add a one-line pointer in `CLAUDE.md` under the TUI section (if one
  exists; otherwise a new subsection) to `docs/tui-lifecycle-model.md`.
- Add a reference comment at the top of `lib/tui_ops.sh` pointing readers
  to the new doc.
- Add a reference comment at the top of `tools/tui_render.py` and
  `tools/tui_render_timings.py`.

## Files Modified

| File | Change |
|------|--------|
| `tests/test_tui_lifecycle_invariants.sh` | NEW — nine invariant tests |
| `docs/tui-lifecycle-model.md` | NEW — model documentation |
| `CLAUDE.md` | Add one-line pointer to the new doc |
| `lib/tui_ops.sh` | Add header comment pointing to the new doc |
| `tools/tui_render.py` | Add header comment pointing to the new doc |
| `tools/tui_render_timings.py` | Add header comment pointing to the new doc |

## Acceptance Criteria

- [ ] `tests/test_tui_lifecycle_invariants.sh` exists and runs under
      `bash tests/run_tests.sh` with zero failures.
- [ ] All nine named invariants are implemented as distinct test cases with
      descriptive names; each invariant has exactly one authoritative test.
- [ ] Invariant #7 (no parallel mechanism) is a grep-based assertion, not a
      runtime behavior check — it catches regressions even when new code
      compiles and runs.
- [ ] `docs/tui-lifecycle-model.md` exists and covers every required
      section.
- [ ] The doc's "Adding a new stage" and "Adding a new sub-stage"
      checklists are complete enough that a dry-run through them against
      an existing stage (say, review) produces all the same files and
      call sites the current codebase has.
- [ ] `CLAUDE.md` links to the new doc.
- [ ] `lib/tui_ops.sh`, `tools/tui_render.py`, `tools/tui_render_timings.py`
      each have a header-comment pointer to the new doc (1–3 lines each,
      not a full copy).
- [ ] Shellcheck clean for `tests/test_tui_lifecycle_invariants.sh` and
      `lib/tui_ops.sh`.
- [ ] `python -m pytest tools/tests/` remains clean.
- [ ] No production code under `lib/`, `stages/`, or `tekhton.sh` is
      modified except for header comments.

## Non-Goals

- Removing `TUI_LIFECYCLE_V2` opt-out. (Separate follow-up; the flag has
  carried across multiple milestones and deserves its own retirement
  decision.)
- Rewriting M104/M108/M110 historical milestone docs. They stand as history.
- Adding new TUI features or renderer modes.
- Introducing a `schema_version` to `tui_status.json`.
- Performance testing or profiling the TUI sidecar.
