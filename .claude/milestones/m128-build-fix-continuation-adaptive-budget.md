# M128 - Build-Fix Continuation Loop & Adaptive Turn Budgeting

<!-- milestone-meta
id: "128"
status: "pending"
-->

## Overview

After M126 (deterministic UI execution) and M127 (confidence-based
classification/routing), one major recovery gap remains:

- Build-fix currently gets one short attempt (`base/3` turns,
  `stages/coder.sh:1148-1155`),
- The stage immediately re-runs the gate (`stages/coder.sh:1158`),
- On failure it exits the pipeline with `build_failure`
  (`stages/coder.sh:1160-1167`).

In real failures, especially UI/test-infra-adjacent code fixes,
single-attempt build-fix is too brittle. A short budget can exhaust on
triage and partial remediation, yielding no meaningful second attempt
even when progress exists.

M128 introduces a bounded build-fix continuation loop with adaptive
budgets and progress gating. The goal is to retain deterministic
termination while allowing enough recovery depth to avoid premature
pipeline exits.

This milestone does not alter reviewer/tester stage iteration policy;
it only upgrades the coder-stage build-fix sub-loop.

## Design

### Goal 1 - Replace single build-fix attempt with bounded continuation loop

Current flow at `stages/coder.sh:1101-1170`:

1. run build gate,
2. if fail -> M127 routing decision (skip if `noncode_dominant`),
3. one build-fix coder call at `base/3` turns,
4. rerun gate once,
5. if fail -> exit `build_failure`.

Replace with a loop:

```text
attempt = 1..BUILD_FIX_MAX_ATTEMPTS
  classify routing via M127 (LAST_BUILD_CLASSIFICATION)
  if classification rules reject continuation -> break
  run build-fix coder (adaptive turns)
  run build gate
  if gate passes -> success
  if no progress -> break early
end
if still failing -> exit build_failure with structured notes
```

New config knobs (defaults in `lib/config_defaults.sh`):

- `BUILD_FIX_ENABLED=true`
- `BUILD_FIX_MAX_ATTEMPTS=3`
- `BUILD_FIX_BASE_TURN_DIVISOR=3` (preserves current baseline)
- `BUILD_FIX_MAX_TURN_MULTIPLIER=1.0` (cap at full coder budget)
- `BUILD_FIX_REQUIRE_PROGRESS=true`
- `BUILD_FIX_TOTAL_TURN_CAP=120` (cumulative cap, see Goal 6)

### Goal 2 - Adaptive turn budget per build-fix attempt

Base budget remains aligned with current behavior:

```bash
base_turns = max(8, EFFECTIVE_CODER_MAX_TURNS / BUILD_FIX_BASE_TURN_DIVISOR)
```

(`EFFECTIVE_CODER_MAX_TURNS` is the existing precedence-resolved budget
used at `stages/coder.sh:1148`.)

Adaptive schedule (attempt-indexed):

- Attempt 1: `1.0 * base_turns`
- Attempt 2: `1.5 * base_turns` (integer arithmetic: `base_turns * 3 / 2`)
- Attempt 3: `2.0 * base_turns`

Clamp all attempts to:

- Lower bound: 8 turns
- Upper bound: `EFFECTIVE_CODER_MAX_TURNS * BUILD_FIX_MAX_TURN_MULTIPLIER`

Use integer arithmetic only — bash has no native floating-point math
(see M127's note about avoiding `bc` in orchestration paths). Multiplier
of `1.0` is implemented as `* 100 / 100`.

Rationale:

- First attempt stays lightweight,
- Later attempts permit deeper edits only when earlier passes fail,
- Hard cap prevents runaway cost.

### Goal 3 - Progress-gated continuation (avoid blind repeated retries)

Continuation beyond attempt 1 must be contingent on progress.

Add helper in the extracted file from Goal 8:

```bash
# _build_fix_progress_signal PREV_ERROR_COUNT NEW_ERROR_COUNT PREV_TAIL NEW_TAIL
# Pure function. Returns one of: improved | unchanged | worsened
# - improved   when NEW_ERROR_COUNT < PREV_ERROR_COUNT
# - worsened   when NEW_ERROR_COUNT > PREV_ERROR_COUNT
# - unchanged  when counts equal AND PREV_TAIL == NEW_TAIL (last 20 non-blank lines)
# - improved   when counts equal but tails differ (some signal moved)
```

Inputs are computed inside `stages/coder_build_fix.sh` from
`BUILD_RAW_ERRORS_FILE` (or `BUILD_ERRORS_FILE` fallback, matching
existing precedence at `stages/coder.sh:1110-1115`):

- **Error count**: line count of `BUILD_RAW_ERRORS_FILE` after each gate
  run. No diffstat or git inspection — keep the helper pure and fast.
- **Tail**: last 20 non-blank lines of `BUILD_RAW_ERRORS_FILE`.

If `BUILD_FIX_REQUIRE_PROGRESS=true` and result is `unchanged` or
`worsened` on attempt N (N >= 2), abort loop early with:

`Build-fix halted early: no measurable progress after attempt N.`

When the loop terminates this way, increment
`BUILD_FIX_PROGRESS_GATE_FAILURES` (see export contract below).

### Goal 4 - Persist build-fix attempt diagnostics for postmortem clarity

Add new artifact:

- `BUILD_FIX_REPORT_FILE="${TEKHTON_DIR}/BUILD_FIX_REPORT.md"`

Add the default to `lib/artifact_defaults.sh` alongside the other
`${TEKHTON_DIR}/` paths (see lines 16-50). Do **not** hardcode
`.tekhton/` — every other artifact uses the variable.

Per attempt, append:

- Attempt number
- Turn budget used
- Agent terminal class (success / max_turns / error)
- Gate result after attempt (pass / fail)
- Progress signal (improved / unchanged / worsened)
- Error-count delta (PREV → NEW)
- M127 routing classification at start of attempt (`LAST_BUILD_CLASSIFICATION`)

When the loop exits unsuccessfully, the report path is referenced in
`PIPELINE_STATE.md` notes and exposed via the env var contract below.

### Goal 5 - Integrate with existing error taxonomy and state writing

When build-fix loop exhausts attempts:

- Keep exit reason `build_failure` for backward compatibility.
- Pass extra notes to `write_pipeline_state` (`lib/state.sh:30`) including:
  - total attempts,
  - final progress signal,
  - last agent classification,
  - pointer to `${BUILD_FIX_REPORT_FILE}`.

When loop aborts early due to no progress:

- Still `build_failure`,
- Note `terminated_early_no_progress=true` for diagnose tooling.

#### M129 cause-context seed (forward integration)

When this milestone lands before M129, set the following env vars on
**every terminal failure path** of the build-fix loop so M129's
`write_last_failure_context` (Goal 2 of m129) can persist them without
modifying this code again:

```bash
export PRIMARY_ERROR_CATEGORY="${PRIMARY_ERROR_CATEGORY:-}"
export PRIMARY_ERROR_SUBCATEGORY="${PRIMARY_ERROR_SUBCATEGORY:-}"
export SECONDARY_ERROR_CATEGORY="AGENT_SCOPE"
export SECONDARY_ERROR_SUBCATEGORY="max_turns"
export SECONDARY_ERROR_SIGNAL="build_fix_budget_exhausted"
export SECONDARY_ERROR_SOURCE="coder_build_fix"
```

Primary cause is left empty here — M127's classifier provides the
primary signal via `LAST_BUILD_CLASSIFICATION` and pattern matches; if
the loop has access to a derived primary token (e.g. `noncode_dominant`
mapping to `ENVIRONMENT/test_infra`) it MAY set primary fields, but is
not required to for M128 to be complete. M129 will fill the gap.

If the helpers `set_secondary_cause`/`reset_failure_cause_context`
already exist (M129 deployed), call them instead of raw exports. Detect
with `command -v set_secondary_cause &>/dev/null`.

### Goal 6 - Guardrails for budget and agent calls

1. **Cumulative turn cap.**
   - `BUILD_FIX_TOTAL_TURN_CAP=120` (default).
   - Track cumulative budget used across attempts in
     `BUILD_FIX_TURN_BUDGET_USED`. Stop additional attempts once
     cumulative cap is reached. The next attempt's adaptive budget is
     clamped to `cap - used` if positive, else loop exits.

2. **Autonomous-agent accounting (no new code needed).**
   - `run_agent` (`lib/agent.sh`) already increments `_ORCH_AGENT_CALLS`
     and the `MAX_AUTONOMOUS_AGENT_CALLS=200` cap fires from
     `lib/orchestrate.sh:177`. Build-fix attempts MUST go through
     `run_agent`; do not invoke the agent CLI directly.

### Goal 7 - Build-fix env var export contract (for M132)

The build-fix loop MUST export the following four env vars at every
exit path (success, exhausted attempts, early no-progress stop). These
are read verbatim by M132's `_collect_build_fix_stats_json`:

| Variable | Type | Values |
|----------|------|--------|
| `BUILD_FIX_ATTEMPTS` | integer | 0..`BUILD_FIX_MAX_ATTEMPTS` |
| `BUILD_FIX_OUTCOME` | enum | `passed` \| `exhausted` \| `no_progress` \| `not_run` |
| `BUILD_FIX_TURN_BUDGET_USED` | integer | cumulative turns spent in build-fix |
| `BUILD_FIX_PROGRESS_GATE_FAILURES` | integer | times progress gate aborted (0 unless `no_progress`) |

`BUILD_FIX_OUTCOME` token vocabulary is **frozen** by this milestone —
M132 dashboards branch on these exact strings. Do not introduce
additional tokens; do not rename. If a new outcome class is needed,
introduce it as a separate field, not a vocabulary extension.

`not_run` means the loop never executed (gate passed first time, or
`BUILD_FIX_ENABLED=false`, or M127 short-circuited via single-attempt
`noncode_dominant`). On these paths the four vars must still be set
(to `0` / `not_run` / `0` / `0`) so M132 sees a stable shape.

Reset all four vars at the start of every coder stage invocation.

### Goal 8 - File-size hygiene: extract build-fix loop helpers

`stages/coder.sh` is currently 1180 lines (verified via `wc -l`). The
new loop, helpers, and report writer add an estimated 150-200 LOC,
which would push the file past the CLAUDE.md non-negotiable rule 8
ceiling (300 lines) **and** materially worsen an already-large file.

Plan from the start to extract into a new file:

- `stages/coder_build_fix.sh`

Containing:

- `run_build_fix_loop` (top-level entry replacing the inline block at
  `stages/coder.sh:1101-1170`)
- `_compute_build_fix_budget ATTEMPT BASE_TURNS USED`
- `_build_fix_progress_signal PREV_COUNT NEW_COUNT PREV_TAIL NEW_TAIL`
- `_append_build_fix_report ATTEMPT BUDGET TERMINAL_CLASS GATE_RESULT PROGRESS DELTA CLASSIFICATION`
- `_export_build_fix_stats OUTCOME` (sets the four Goal 7 vars)

`stages/coder.sh` sources the new file (consistent with how stages
currently source helpers) and replaces the inline block with a single
`run_build_fix_loop` call.

### Goal 9 - Test matrix for continuation semantics

Create `tests/test_build_fix_loop.sh`. No `tests/run_tests.sh` edit is
required because the runner already auto-discovers `tests/test_*.sh`.
All tests use shell stubs only — no real coder agent invocation, no
network. Reuse the `RETRY_STATE` counter pattern established by
`tests/test_ui_build_gate.sh` Test 8.

1. **`unit_progress_signal_truth_table`** (pure-function unit test)
   Call `_build_fix_progress_signal` directly with crafted args:
   - `(10, 5, "tail-A", "tail-B")` → `improved`
   - `(5, 10, ..., ...)` → `worsened`
   - `(7, 7, "x", "x")` → `unchanged`
   - `(7, 7, "x", "y")` → `improved`

2. **`unit_compute_budget_clamps`** (pure-function unit test)
   Verify adaptive schedule: attempt=1 → 1.0×, attempt=2 → 1.5×,
   attempt=3 → 2.0×. Clamp at lower 8 and upper
   `EFFECTIVE_CODER_MAX_TURNS * MULTIPLIER`. Verify cumulative-cap
   clamp returns 0 when used >= cap.

3. **`retries_until_pass`**
   Stub: gate fails twice then passes. Assert exactly **2** build-fix
   attempts executed; `BUILD_FIX_OUTCOME=passed`,
   `BUILD_FIX_ATTEMPTS=2`.

4. **`stops_at_max_attempts`**
   Stub: perpetual failure with strictly decreasing error counts (so
   progress gate does not trip). Assert
   `BUILD_FIX_ATTEMPTS == BUILD_FIX_MAX_ATTEMPTS`,
   `BUILD_FIX_OUTCOME=exhausted`.

5. **`early_stop_no_progress`**
   Stub: identical errors and identical tail across attempts. Assert
   loop stops at attempt 2; `BUILD_FIX_OUTCOME=no_progress`,
   `BUILD_FIX_PROGRESS_GATE_FAILURES=1`.

6. **`total_turn_cap_enforced`**
   Synthetic large `EFFECTIVE_CODER_MAX_TURNS`, low
   `BUILD_FIX_TOTAL_TURN_CAP`. Assert loop exits when cumulative cap
   reached even before max attempts.

7. **`report_written`**
   Verify `${BUILD_FIX_REPORT_FILE}` is created, contains one block per
   attempt, and includes turn budget / terminal class / gate result /
   progress / classification fields.

8. **`pipeline_state_notes_include_build_fix_summary`**
   Verify `PIPELINE_STATE.md` notes on `build_failure` exit include
   attempt count and `${BUILD_FIX_REPORT_FILE}` pointer.

9. **`stats_exported_on_every_exit_path`**
    Verify the four Goal 7 vars are non-empty after success path,
    exhausted path, no-progress path, and `not_run` path. Specifically
    assert `BUILD_FIX_OUTCOME` is one of the four allowed tokens.

10. **`single_attempt_compat_mode`**
    Set `BUILD_FIX_MAX_ATTEMPTS=1` and verify behavior matches
    pre-M128: one attempt then exit. (Rollback safety.)

## Files Modified

| File | Change |
|------|--------|
| `stages/coder.sh` | Replace the inline block at lines 1101-1170 with a single call to `run_build_fix_loop` (sourced from new `coder_build_fix.sh`). Remove the inline build-fix code path. |
| `stages/coder_build_fix.sh` | **New file.** Houses `run_build_fix_loop`, `_compute_build_fix_budget`, `_build_fix_progress_signal`, `_append_build_fix_report`, `_export_build_fix_stats`. Must stay under 300 lines. |
| `lib/config_defaults.sh` | Add six build-fix config defaults (`BUILD_FIX_ENABLED`, `BUILD_FIX_MAX_ATTEMPTS`, `BUILD_FIX_BASE_TURN_DIVISOR`, `BUILD_FIX_MAX_TURN_MULTIPLIER`, `BUILD_FIX_REQUIRE_PROGRESS`, `BUILD_FIX_TOTAL_TURN_CAP`) and corresponding `_clamp_config_value` calls (see existing pattern at line 567). |
| `lib/artifact_defaults.sh` | Add `: "${BUILD_FIX_REPORT_FILE:=${TEKHTON_DIR}/BUILD_FIX_REPORT.md}"` alongside the existing artifact paths (lines 16-50). |
| `lib/state.sh` | No signature change. Build-fix loop calls `write_pipeline_state` with the existing 5-arg form, passing the structured summary string as `extra_notes` (5th arg). The function body at line 30 is unchanged. |
| `lib/prompts.sh` | Register `BUILD_FIX_REPORT_FILE` and the six new config keys as template variables (consistent with how other artifact and config vars are exposed). |
| `tests/test_build_fix_loop.sh` | **New file.** Test cases T1–T10 above. |
| `tests/run_tests.sh` | **No change required.** Runner auto-discovers `tests/test_*.sh`; `test_build_fix_loop.sh` is picked up by filename convention. |
| `docs/resilience.md` | Document build-fix continuation policy, caps, and early-stop criteria. |
| `docs/reference/configuration.md` | Document the six new build-fix config keys with defaults. |

## Acceptance Criteria

- [ ] Build-fix flow supports up to `BUILD_FIX_MAX_ATTEMPTS` attempts, stopping early on success.
- [ ] Turn budget increases per attempt according to the 1.0× / 1.5× / 2.0× schedule using integer arithmetic; respects 8-turn lower bound and `EFFECTIVE_CODER_MAX_TURNS * BUILD_FIX_MAX_TURN_MULTIPLIER` upper bound.
- [ ] Continuation beyond attempt 1 is blocked when `BUILD_FIX_REQUIRE_PROGRESS=true` and `_build_fix_progress_signal` returns `unchanged` or `worsened`.
- [ ] Cumulative build-fix turns are capped by `BUILD_FIX_TOTAL_TURN_CAP=120`.
- [ ] `${BUILD_FIX_REPORT_FILE}` is created under `${TEKHTON_DIR}/` and records every attempt with budget / terminal class / gate result / progress / classification.
- [ ] On terminal `build_failure`, `PIPELINE_STATE.md` notes include attempt count and report pointer.
- [ ] On every exit path (including the `not_run` path), the four env vars `BUILD_FIX_ATTEMPTS`, `BUILD_FIX_OUTCOME`, `BUILD_FIX_TURN_BUDGET_USED`, `BUILD_FIX_PROGRESS_GATE_FAILURES` are exported with valid values; `BUILD_FIX_OUTCOME` is one of `passed | exhausted | no_progress | not_run`.
- [ ] On terminal failure paths, `SECONDARY_ERROR_CATEGORY=AGENT_SCOPE`, `SECONDARY_ERROR_SUBCATEGORY=max_turns`, `SECONDARY_ERROR_SIGNAL=build_fix_budget_exhausted` are exported (or, when M129 helpers are present, `set_secondary_cause` is called with the same args).
- [ ] `BUILD_FIX_MAX_ATTEMPTS=1` reproduces pre-M128 single-attempt behavior (rollback safety).
- [ ] `stages/coder.sh` lines decreased (inline block extracted) and `stages/coder_build_fix.sh` is below 300 lines.
- [ ] All build-fix loop tests pass; all existing coder-stage and gate-bypass tests remain green.
- [ ] `shellcheck` clean for `stages/coder.sh`, `stages/coder_build_fix.sh`, `lib/config_defaults.sh`, `lib/artifact_defaults.sh`.

## Watch For

- **`BUILD_FIX_OUTCOME` token vocabulary is a cross-milestone contract.**
  M132's `_collect_build_fix_stats_json` (`m132-run-summary-causal-fidelity-enrichment.md`)
  branches on the exact strings `passed | exhausted | no_progress | not_run`.
  Renaming, abbreviating, or adding tokens silently breaks the dashboard.
  If a new state is needed, introduce a new exported field instead.
- **Export the four Goal 7 vars on `not_run` paths too.** When the gate
  passes first time or `BUILD_FIX_ENABLED=false`, M132 still expects to
  read `BUILD_FIX_OUTCOME=not_run`, `BUILD_FIX_ATTEMPTS=0`. Skipping
  the export silently drives M132's `_collect_build_fix_stats_json`
  into "absent → enabled:false" inference, which is the wrong default.
- **Read `LAST_BUILD_CLASSIFICATION` (M127), do not re-classify.** M127
  exports the routing token after every gate run. The build-fix loop
  reads it directly; do not re-invoke `classify_routing_decision`. The
  four-token vocabulary (`code_dominant | noncode_dominant |
  mixed_uncertain | unknown_only`) is M127's contract — M128 only
  needs to *consume* it.
- **Do not double-count agent calls.** Build-fix attempts must invoke
  `run_agent` (`lib/agent.sh`), which already increments
  `_ORCH_AGENT_CALLS` and respects `MAX_AUTONOMOUS_AGENT_CALLS=200`
  (`lib/orchestrate.sh:177`). Do not bump the counter manually; do not
  call the agent CLI directly.
- **Bash has no floating-point math.** The 1.5× multiplier is integer
  arithmetic: `base_turns * 3 / 2`. The 1.0 multiplier is `* 100 / 100`.
  Do not introduce a `bc` dependency in orchestration paths (see M127
  Watch For for the same constraint).
- **State writer is `lib/state.sh`, not `lib/pipeline_state_io.sh`.**
  The function is `write_pipeline_state` at `lib/state.sh:30`. The
  5th positional argument is `extra_notes`. No signature change is
  required by this milestone — pass the structured summary as a string.
- **`${BUILD_FIX_REPORT_FILE}` placement.** Use the variable everywhere;
  do not hardcode `.tekhton/`. `lib/artifact_defaults.sh:16` sets
  `TEKHTON_DIR` and every artifact path derives from it (M84
  migration).
- **300-line ceiling on `stages/coder_build_fix.sh`.** The new file
  must stay under the limit. Five helpers plus a top-level loop
  function is feasible; do not put the prompt template render inline
  (use the existing `render_prompt "build_fix"` indirection).
- **Progress signal compares last 20 non-blank lines.** The exact
  count is part of the unit test fixture. Changing the window size
  flips edge-case classifications and breaks the truth-table test.
- **Pre-flight backwards-compat: `has_only_noncode_errors` is M127's
  responsibility.** Do not call it from inside the loop; M127's single-
  attempt short-circuit fires *before* the loop entry. Additional
  non-code dominant routing is handled by M130 at recovery dispatch.
- **`BUILD_FIX_TOTAL_TURN_CAP` interacts with adaptive budgets.** When
  `cap - used` becomes smaller than 8, the next attempt would request
  a sub-floor budget. Treat that as "cap reached" and exit the loop;
  do not invoke an agent with budget < 8.

## Seeds Forward

- **M129 — Failure context schema v2.** M129 reads
  `LAST_FAILURE_CONTEXT.json` and explicitly states (Goal 2) that
  "coder build-gate/build-fix exit path (`stages/coder.sh`)" is
  immediate mandatory integration for primary/secondary cause vars.
  M128's exports of `SECONDARY_ERROR_*` (Goal 5) cover the secondary
  slot; primary slot is filled by M127's classifier translation in
  M129. If M128 lands first, leave the primary vars empty rather than
  guessing — M129's writer handles the empty case. If M129 lands
  first and provides `set_secondary_cause`, prefer that helper over
  raw exports.
- **M130 — Causal-context-aware recovery routing.** M130 reads
  `LAST_BUILD_CLASSIFICATION` to decide whether to route
  `retry_coder_build` (`code_dominant` / `mixed_uncertain` first
  attempt) or `save_exit` (`noncode_dominant`). Keep ownership clear:
  M130 owns non-code dominant recovery dispatch, while M128 owns
  in-loop budget and progress gates after a retry has been selected.
  M130's `_ORCH_MIXED_BUILD_RETRIED` gate is at outer-loop level, not
  per-attempt — do not try to coordinate them.
- **M132 — RUN_SUMMARY causal fidelity enrichment.** Hard contract.
  M132's `_collect_build_fix_stats_json` reads exactly the four env
  vars from Goal 7 with exactly the four `BUILD_FIX_OUTCOME` tokens.
  Keep the names, types, and vocabulary stable. Watchtower badges and
  dashboard run-row rendering depend on this.
- **`${BUILD_FIX_REPORT_FILE}` (new artifact).** Future milestones
  (notes pipeline, watchtower run detail) may want to surface the
  per-attempt history. Keep the schema simple — one section per
  attempt with the seven fields listed in Goal 4 — so downstream
  parsers stay trivial. If a future milestone needs structured access,
  emit a sibling JSON artifact rather than parsing the markdown.
- **Adaptive schedule generalization.** The 1.0× / 1.5× / 2.0×
  schedule is hardcoded. If a future milestone wants attempt-N
  budgets to be data-driven (e.g. learned from M46 metrics), the
  cleanest hook is `_compute_build_fix_budget` — keep it pure so it
  can be replaced without touching the loop body.
