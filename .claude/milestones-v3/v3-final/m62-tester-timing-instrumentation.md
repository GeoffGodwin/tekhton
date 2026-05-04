# Milestone 62: Tester & Build Gate Timing Instrumentation
<!-- milestone-meta
id: "62"
status: "done"
-->

## Overview

The tester stage averages 19 minutes — longer than the coder (17 min) — but all
of that time is reported as a single `tester_agent` phase. There is no visibility
into how time splits between test writing, test execution, and failure debugging.
Without this breakdown, optimization efforts are guesswork.

This milestone adds timing visibility by two mechanisms:
1. **Agent self-reporting:** Instruct the tester agent to log TEST_CMD timing in
   a structured section of TESTER_REPORT.md, then parse it post-hoc.
2. **Build gate phase surfacing:** Expose existing `_phase_start`/`_phase_end`
   data for individual build gate phases in TIMING_REPORT.md.

Depends on M56 for stable pipeline baseline.

**Design rationale:** Claude CLI's `-p --output-format json` returns a single
result JSON, not per-tool-call timing breakdown. We cannot extract TEST_CMD
timing from agent logs externally. Instead, the tester prompt instructs the agent
to self-report timing data in a parseable format, and the pipeline extracts it
from TESTER_REPORT.md after the agent completes.

## Scope

### 1. Tester Agent Self-Reporting

**File:** `prompts/tester.prompt.md`

Add instructions to the tester prompt:

```markdown
## Timing Tracking
When you run {{TEST_CMD}}, note the wall-clock duration. At the end of your
TESTER_REPORT.md, include a section:

## Timing
- Test executions: N
- Approximate total test execution time: Xs
- Test files written: N
```

This is approximate (agents estimate, don't have precise clocks) but provides
directional signal that's better than zero visibility.

### 2. TESTER_REPORT.md Timing Extraction

**File:** `stages/tester.sh`

After the tester agent completes, parse TESTER_REPORT.md for the `## Timing`
section. Extract:
- `tester_test_execution_count` — number of TEST_CMD invocations
- `tester_test_execution_approx_s` — agent-reported test execution time
- `tester_writing_approx_s` — remainder (total agent time minus reported
  execution time)

Use defensive parsing: if section is missing or unparseable, set all values to
`-1` (unknown) and fall back to single-phase reporting.

Store in `_TESTER_TIMING_*` global variables for downstream consumption.

### 3. Build Gate Phase Surfacing

**File:** `lib/timing.sh`

The build gate already uses `_phase_start`/`_phase_end` for its sub-phases
(`build_gate_compile`, `build_gate_analyze`, `build_gate_constraints`). These
are recorded in `_PHASE_TIMINGS` but not displayed in TIMING_REPORT.md.

Add display name mappings for build gate phases:
```bash
build_gate_compile    → "  ↳ Build (compile)"
build_gate_analyze    → "  ↳ Build (analyze)"
build_gate_constraints → "  ↳ Build (constraints)"
```

When rendering TIMING_REPORT.md, detect phases that start with a common prefix
(e.g., `build_gate_*`) and render them as indented sub-rows under the parent.

**Implementation constraint:** Do NOT introduce a formal phase hierarchy or
nesting data structure. Use naming convention only (`parent_child` prefix
pattern). This keeps the timing system flat and simple.

### 4. TIMING_REPORT.md Sub-Phase Display

**File:** `lib/timing.sh`

Modify `_hook_emit_timing_report()` to handle sub-phases:
- After rendering a parent phase row, check for `_PHASE_TIMINGS` keys that
  start with `${parent}_` prefix
- Render sub-phases as indented rows with `↳` prefix
- Sub-phase percentages are computed against the **parent duration**, not
  total run time (this differs from top-level phases)
- If tester self-reported timing is available, render as sub-rows:
  ```
  | Tester (agent)       | 19m 12s | 45% |
  |   ↳ Test execution   | ~10m    | ~52% of tester |
  |   ↳ Test writing     | ~9m     | ~48% of tester |
  ```

The `~` prefix indicates agent-estimated (not precise) values.

### 5. RUN_SUMMARY.json Enhancement

**File:** `lib/finalize_summary.sh`

Add optional sub-fields to the tester stage entry:
```json
{
  "tester": {
    "turns": 45,
    "duration_s": 1152,
    "budget": 100,
    "test_execution_approx_s": -1,
    "test_execution_count": -1,
    "test_writing_approx_s": -1
  }
}
```

Values of `-1` mean "not available" (agent didn't report, or parsing failed).
Downstream consumers must handle this.

Extend the `stages_json` builder at `finalize_summary.sh:148-164` to
conditionally include tester sub-fields when `_TESTER_TIMING_*` globals are set.

### 6. Continuation Handling

**File:** `stages/tester.sh`

When tester continuations occur (`tester.sh:270-287`), each continuation is a
new agent invocation. The self-reported timing from each invocation should be
**accumulated** (not replaced). After each continuation:
- Parse TESTER_REPORT.md for timing section
- Add to running totals in `_TESTER_TIMING_*` globals

## Migration Impact

No new config keys. Timing data is purely additive to existing reports. The
`~` prefix in TIMING_REPORT.md clearly signals estimated vs. measured values.

## Acceptance Criteria

- Tester prompt includes timing self-report instructions
- TESTER_REPORT.md parsing extracts timing when section present
- Missing timing section produces graceful fallback (no crash, values = -1)
- Build gate sub-phases visible in TIMING_REPORT.md
- Sub-phase percentages computed against parent duration (not total)
- RUN_SUMMARY.json includes tester timing fields (or -1 when unavailable)
- Continuation runs accumulate timing across invocations
- All existing tests pass
- Timing extraction overhead < 100ms (simple text parsing, not log scanning)

Tests:
- Parse logic extracts timing from sample TESTER_REPORT.md with `## Timing` section
- Missing `## Timing` section produces `-1` values (no crash)
- Malformed timing values (non-numeric) produce `-1` (defensive parsing)
- Build gate phases appear as indented sub-rows in TIMING_REPORT.md
- Sub-phase percentages sum to ~100% of parent (within rounding)
- Continuation accumulation adds timing across multiple TESTER_REPORT.md parses

Watch For:
- Agent timing estimates are approximate. The `~` prefix in reports and the
  `_approx_s` suffix in JSON signal this clearly. Do NOT present agent-estimated
  times as precise measurements.
- The `## Timing` section in TESTER_REPORT.md must be at the END of the file
  to avoid interfering with existing verdict/bug parsing (which reads from top).
- Build gate phase names (`build_gate_compile`, etc.) must match exactly what
  `lib/gates.sh` uses in its `_phase_start` calls. Verify against actual code.
- Do NOT add sub-phase timing to the metrics JSONL record (`metrics.sh`). Keep
  it in RUN_SUMMARY.json only. Metrics JSONL is for adaptive calibration and
  doesn't need sub-phase granularity.

Seeds Forward:
- Writing vs. execution split informs whether to optimize test startup time
  or test authoring prompts
- Build gate phase visibility helps identify slow compilation or analysis steps
