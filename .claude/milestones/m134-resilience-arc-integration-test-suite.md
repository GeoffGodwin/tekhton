# M134 - Resilience Arc Integration Test Suite & Cross-Cutting Regression Harness

<!-- milestone-meta
id: "134"
status: "done"
-->

## Overview

Milestones m126–m133 form an eight-milestone resilience arc. Each
milestone has its own unit tests that validate individual functions
in isolation, but no test currently exercises the full chain as a system:

```
preflight scan → gate env normalization → timeout detection →
log classification → build-fix loop → failure context write →
recovery routing → RUN_SUMMARY enrichment → --diagnose output
```

This matters because cross-cutting integration bugs — bugs that only
manifest when two or more arc components interact — cannot be caught by
unit tests. Concrete examples of bugs that existing tests would miss:

- m131 sets `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1` but m126's
  `_ui_deterministic_env_list` is never called because the env var
  name was mistyped in one of them.
- m129 writes `primary_cause.signal` as `ui_timeout_interactive_report`
  but m133's `_rule_ui_gate_interactive_reporter` reads `signal` from
  the wrong JSON object and always misses it.
- m132's `_collect_causal_context_json` reads `primary_cause.category`
  correctly but m130's `_ORCH_RECOVERY_ROUTE_TAKEN` was never assigned
  because the var name in `orchestrate.sh` does not match the one
  declared in `orchestrate_recovery.sh`.
- m127's `LAST_BUILD_CLASSIFICATION=noncode_dominant` is exported but
  m130's `Amendment C` reads `${LAST_BUILD_CLASSIFICATION}` with a
  default of `code_dominant` because the export happened in a subshell.

M134 creates `tests/test_resilience_arc_integration.sh` — a
scenario-driven integration test file that exercises each of the eight
cross-cutting paths using fully controlled fixtures (no live agent, no
real Playwright, no real build tools). It is the regression harness
for the entire resilience arc.

## Design

### Test infrastructure pattern (follow existing convention)

All tests follow the pattern established in `test_quota.sh`,
`test_diagnose_recovery_command.sh`, and similar files:

```bash
#!/usr/bin/env bash
set -euo pipefail
TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

# source minimal common.sh stubs, then arc modules under test
```

Each scenario function:
1. Creates a fresh sub-directory under `$TMPDIR` as `PROJECT_DIR`.
2. Writes the fixture files needed (config, state, logs, etc.).
3. Sets env vars to the scenario's starting conditions.
4. Calls the function(s) under test.
5. Asserts expected state, outputs, or file contents.
6. Cleans up by unsetting scenario-local env vars.

`pass`/`fail` helpers follow the exact same pattern as all other test
files — no new test framework, no third-party tools.

### Scenario group 1 — Preflight → Gate first-run determinism (m131 + m126)

#### S1.1 — Preflight detects html reporter; gate gets non-interactive env on first run

```
Setup:
  - playwright.config.ts: reporter: 'html'
  - UI_TEST_CMD="npx playwright test"
  - PREFLIGHT_UI_CONFIG_AUTO_FIX=false (detection only)

Actions:
  1. Run _preflight_check_ui_test_config
  2. Assert PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
  3. Call _ui_deterministic_env_list (m126 helper)
  4. Assert output contains "PLAYWRIGHT_HTML_OPEN=never"
  5. Assert output contains "CI=1"
  6. Assert PREFLIGHT_UI_REPORTER_PATCHED stays 0 (auto-fix disabled)

Expected result:
  - Gate first-run env includes non-interactive vars
  - No config file modification
```

#### S1.2 — Preflight auto-patches html reporter; gate sees CI-guarded config

```
Setup:
  - playwright.config.ts: reporter: 'html'
  - PREFLIGHT_UI_CONFIG_AUTO_FIX=true

Actions:
  1. Run _preflight_check_ui_test_config
  2. Assert playwright.config.ts no longer contains reporter: 'html'
  3. Assert playwright.config.ts contains process.env.CI ? 'dot' : 'html'
  4. Assert PREFLIGHT_UI_REPORTER_PATCHED=1
  5. Assert backup exists in .claude/preflight_bak/

Expected result:
  - Source file patched in-place
  - PREFLIGHT_UI_REPORTER_PATCHED=1 propagated to gate normalizer
```

#### S1.3 — No playwright.config → preflight silent; command-based detection still hardens the gate

```
Setup:
  - No playwright.config.* in PROJECT_DIR
  - UI_TEST_CMD="npx playwright test"

Actions:
  1. Run _preflight_check_ui_test_config
  2. Assert PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED is unset or 0
  3. Call _ui_deterministic_env_list
  4. Assert output includes "PLAYWRIGHT_HTML_OPEN=never"
  5. Assert output does NOT include "CI=1" (no preflight signal / hardened escalation)

Expected result:
  - Preflight stays silent because there is no config file to audit
  - Gate still applies the normal Playwright deterministic env because
    `UI_TEST_CMD` itself identifies the framework (m126 Goal 1)
```

### Scenario group 2 — Gate timeout → interactive signature detection → hardened retry (m126)

#### S2.1 — Gate times out with interactive reporter output; hardened retry applied

```
Setup:
  - Mock UI_TEST_CMD that:
      * exits 124 (timeout)
      * writes "Serving HTML report at http://localhost:9323. Press Ctrl+C to quit."
        to its stdout
  - PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=0 (no preflight signal)

Actions:
  1. Run _run_ui_test_phase "coder"
  2. Assert `_ui_timeout_signature 124 "$captured_output"` returns `interactive_report`
  3. Assert second gate run uses env with PLAYWRIGHT_HTML_OPEN=never
  4. If the hardened rerun still fails, assert the terminal diagnosis block
     records `Timeout class: interactive_report`
  5. Assert the failure path is classified as the interactive-reporter case,
     not the generic-timeout case

Expected result:
  - Interactive reporter detected from output
  - Hardened retry attempted with correct env
  - Terminal diagnosis remains `interactive_report`, not `generic_timeout`
```

#### S2.2 — Gate times out without interactive signature → regular timeout path

```
Setup:
  - Mock UI_TEST_CMD that exits 124 with no interactive reporter output

Actions:
  1. Run _run_ui_test_phase "coder"
  2. Assert `_ui_timeout_signature 124 "$captured_output"` returns `generic_timeout`
  3. Assert no hardened retry attempted (standard exit)
  4. If terminal diagnosis is written, assert it records `Timeout class: generic_timeout`
```

### Scenario group 3 — Log classification → build-fix routing (m127 + m128)

#### S3.1 — code_dominant classification → build-fix loop runs

```
Setup:
  - ${BUILD_RAW_ERRORS_FILE} containing TypeScript type errors
    (lines matching known code-error patterns from m53 registry)

Actions:
  1. Run `classify_routing_decision` on the raw `${BUILD_RAW_ERRORS_FILE}` content
  2. Assert LAST_BUILD_CLASSIFICATION="code_dominant"
  3. Call build-fix loop entry point with BUILD_FIX_MAX_ATTEMPTS=2
  4. Assert loop runs up to max_attempts
  5. Assert BUILD_FIX_ATTEMPTS exported and equals actual loop count

Expected result:
  - code_dominant signal gates loop entry correctly
  - Attempt counter matches expectations
```

#### S3.2 — noncode_dominant classification → build-fix loop skipped

```
Setup:
  - ${BUILD_RAW_ERRORS_FILE} containing only explicit non-code matches
    (e.g., `Error: connect ECONNREFUSED 127.0.0.1:3000`,
    `browserType.launch: Executable doesn't exist`) plus optional ignorable noise lines

Actions:
  1. Run `classify_routing_decision` on the raw `${BUILD_RAW_ERRORS_FILE}` content
  2. Assert LAST_BUILD_CLASSIFICATION="noncode_dominant"
  3. Verify build-fix loop returns immediately with BUILD_FIX_ATTEMPTS=0

Expected result:
  - Explicit non-code signal prevents futile build-fix attempts
```

#### S3.3 — mixed_uncertain classification → one retry allowed, then stops

```
Setup:
  - ${BUILD_RAW_ERRORS_FILE} with both explicit code-error matches and
    explicit non-code matches; once both classes are present,
    m127 should route `mixed_uncertain`

Actions:
  1. Run `classify_routing_decision` on the raw `${BUILD_RAW_ERRORS_FILE}` content
  2. Assert LAST_BUILD_CLASSIFICATION="mixed_uncertain"
  3. Confirm first build-fix attempt is allowed
  4. Set _ORCH_MIXED_BUILD_RETRIED=1 and call _classify_failure
  5. Assert result is "save_exit" (no second mixed retry)
```

### Scenario group 4 — Failure context write → recovery routing (m129 + m130)

#### S4.1 — ENVIRONMENT/test_infra primary → retry_ui_gate_env routed

```
Setup:
  - AGENT_ERROR_CATEGORY=ENVIRONMENT
  - AGENT_ERROR_SUBCATEGORY=test_infra
  - PRIMARY_ERROR_CATEGORY=ENVIRONMENT
  - PRIMARY_ERROR_SUBCATEGORY=test_infra
  - PRIMARY_ERROR_SIGNAL=ui_timeout_interactive_report

Actions:
  1. Call write_last_failure_context (m129 writer)
  2. Assert LAST_FAILURE_CONTEXT.json exists and schema_version=2
  3. Assert primary_cause.category="ENVIRONMENT" in the file
  4. Call _load_failure_cause_context (m130 reader)
  5. Assert _ORCH_PRIMARY_CAT="ENVIRONMENT"
  6. Call _classify_failure
  7. Assert return value is "retry_ui_gate_env"

Expected result:
  - Full write→read→route chain works end-to-end
  - The route correctly identifies the env retry path
```

#### S4.2 — AGENT_SCOPE/max_turns with env primary → retry_ui_gate_env, not split

```
Setup:
  - AGENT_ERROR_CATEGORY=AGENT_SCOPE
  - AGENT_ERROR_SUBCATEGORY=max_turns
  - PRIMARY_ERROR_CATEGORY=ENVIRONMENT (set by stage before writing context)
  - SECONDARY_ERROR_CATEGORY=AGENT_SCOPE
  - _ORCH_ENV_GATE_RETRIED=0

Actions:
  1. Call write_last_failure_context
  2. Assert schema_version=2, secondary_cause.subcategory="max_turns"
  3. Call _classify_failure
  4. Assert return value is "retry_ui_gate_env" (NOT "split")

Expected result:
  - max_turns secondary symptom does not trigger split
  - Env root cause correctly dominates routing
```

#### S4.3 — Second env failure → save_exit (loop guard works)

```
Setup:
  - Same as S4.1 but _ORCH_ENV_GATE_RETRIED=1 (already tried once)

Actions:
  1. Call _classify_failure
  2. Assert return value is "save_exit"

Expected result:
  - _ORCH_ENV_GATE_RETRIED guard prevents infinite retry loop
```

#### S4.4 — v1 schema compat: flat ENVIRONMENT → save_exit (pre-m129 run)

```
Setup:
  - Write LAST_FAILURE_CONTEXT.json with v1 shape:
    {"classification":"ENVIRONMENT","category":"ENVIRONMENT","subcategory":"disk_full"}
  - AGENT_ERROR_CATEGORY=ENVIRONMENT

Actions:
  1. Call _load_failure_cause_context
  2. Assert _ORCH_PRIMARY_CAT="" (no primary_cause in v1)
  3. Call _classify_failure
  4. Assert return value is "save_exit" (existing behavior preserved)
```

### Scenario group 5 — RUN_SUMMARY enrichment (m132)

#### S5.1 — Full enrichment: all four new fields present on failure run

```
Setup:
  - BUILD_FIX_ATTEMPTS=2 BUILD_FIX_OUTCOME=exhausted
  - _ORCH_PRIMARY_CAT=ENVIRONMENT _ORCH_PRIMARY_SUB=test_infra
  - _ORCH_RECOVERY_ROUTE_TAKEN=retry_ui_gate_env
  - PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1 PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE=PW-1
  - Write minimal LAST_FAILURE_CONTEXT.json v2 fixture

Actions:
  1. Run _hook_emit_run_summary 1
  2. Parse the output RUN_SUMMARY.json

Assertions:
  - "causal_context" key present and primary_category="ENVIRONMENT"
  - "build_fix_stats" key present and outcome="exhausted" and attempts=2
  - "recovery_routing" key present and route_taken="retry_ui_gate_env"
  - "preflight_ui" key present and interactive_config_detected=true
  - "error_classes_encountered" contains "root:ENVIRONMENT/test_infra"
  - "recovery_actions_taken" contains "retry_ui_gate_env"
```

#### S5.2 — Success run: four new fields present with zero/null variants

```
Setup:
  - All BUILD_FIX_* and _ORCH_* vars unset or at default

Actions:
  1. Run _hook_emit_run_summary 0

Assertions:
  - causal_context.schema_version=0
  - build_fix_stats.outcome="not_run" and enabled=false
  - recovery_routing.route_taken="save_exit" (default)
  - preflight_ui.interactive_config_detected=false
  - JSON is valid (no truncated fields, no syntax errors from absent vars)
```

### Scenario group 6 — `--diagnose` end-to-end classification (m133)

#### S6.1 — Full bifl-tracker scenario: correct diagnosis from state files

This is the "golden path" scenario — the exact failure pattern from the
bifl-tracker M03 run that motivated the entire arc.

```
Setup (replicate bifl-tracker M03 state):
  - LAST_FAILURE_CONTEXT.json v2:
      primary_cause: {category: ENVIRONMENT, subcategory: test_infra,
                      signal: ui_timeout_interactive_report}
      secondary_cause: {category: AGENT_SCOPE, subcategory: max_turns}
      classification: UI_INTERACTIVE_REPORTER
  - PIPELINE_STATE.md:
      Exit Stage: coder
      Exit Reason: complete_loop_max_attempts
      Notes: "Primary cause: ENVIRONMENT/test_infra ..."
  - Log file containing: "Serving HTML report at http://localhost:9323."
  - playwright.config.ts: reporter: 'html'
  - ${BUILD_RAW_ERRORS_FILE}: non-empty (some TypeScript errors from the run)

Actions:
  1. Run _read_diagnostic_context
  2. Run classify_failure_diag (full rule chain)

Assertions:
  - DIAG_CLASSIFICATION = "UI_GATE_INTERACTIVE_REPORTER" (not MAX_TURNS_EXHAUSTED)
  - DIAG_CONFIDENCE = "high"
  - DIAG_SUGGESTIONS contains "reporter: 'html'"
  - DIAG_SUGGESTIONS contains "reporter: process.env.CI ? 'dot' : 'html'"
  - DIAG_SUGGESTIONS does NOT contain "CODER_MAX_TURNS" (wrong advice suppressed)
  - DIAG_SUGGESTIONS does NOT contain "Split the milestone" (wrong advice suppressed)
```

#### S6.2 — Build-fix exhausted scenario: BUILD_FIX_EXHAUSTED fires, not BUILD_FAILURE

```
Setup:
  - ${BUILD_FIX_REPORT_FILE}: outcome: exhausted, attempts: 3
  - ${BUILD_RAW_ERRORS_FILE}: non-empty
  - No interactive reporter signals

Actions:
  1. Run classify_failure_diag

Assertions:
  - DIAG_CLASSIFICATION = "BUILD_FIX_EXHAUSTED"
  - DIAG_SUGGESTIONS contains "BUILD_FIX_MAX_ATTEMPTS"
  - _rule_build_failure did NOT fire first (ordering maintained)
```

#### S6.3 — max_turns with env primary: MAX_TURNS_ENV_ROOT fires

```
Setup:
  - LAST_FAILURE_CONTEXT.json v2 with primary=ENVIRONMENT/test_infra,
    secondary=AGENT_SCOPE/max_turns
  - PIPELINE_STATE.md Exit Reason: complete_loop_max_attempts
  - No ${BUILD_FIX_REPORT_FILE}, no interactive reporter log evidence

Actions:
  1. Run classify_failure_diag

Assertions:
  - DIAG_CLASSIFICATION = "MAX_TURNS_ENV_ROOT"
  - DIAG_SUGGESTIONS contains "primary cause"
  - DIAG_SUGGESTIONS does NOT contain "CODER_MAX_TURNS="
```

#### S6.4 — v1 schema with max_turns: original MAX_TURNS_EXHAUSTED preserved

```
Setup:
  - LAST_FAILURE_CONTEXT.json v1:
    {"classification":"MAX_TURNS_EXHAUSTED","category":"AGENT_SCOPE","subcategory":"max_turns"}
  - No ${BUILD_FIX_REPORT_FILE}

Actions:
  1. Run classify_failure_diag

Assertions:
  - DIAG_CLASSIFICATION = "MAX_TURNS_EXHAUSTED"
  - DIAG_SUGGESTIONS contains "CODER_MAX_TURNS"
  - Backward compatibility with pre-m129 runs confirmed
```

### Scenario group 7 — State reset between iterations (no cross-contamination)

#### S7.1 — _reset_orch_recovery_state zeroes persistent retry guards only

```
Setup:
  - Set all _ORCH_* vars to non-default values (from a previous iteration)

Actions:
  1. Call _reset_orch_recovery_state
  2. Assert _ORCH_ENV_GATE_RETRIED=0
  3. Assert _ORCH_MIXED_BUILD_RETRIED=0
  4. Assert _ORCH_RECOVERY_ROUTE_TAKEN=""
  5. Assert _ORCH_PRIMARY_CAT is unchanged (cause vars are loader-owned)
  6. Assert _ORCH_SCHEMA_VERSION is unchanged (loader-owned)
```

#### S7.2 — PREFLIGHT_UI_* vars persist within run, reset at new-run boundary

```
Setup:
  - PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1 from first attempt

Actions:
  1. Simulate a later run_complete_loop iteration without re-running preflight
  2. Assert PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED remains 1 for this run
  3. Start a fresh run boundary and assert `_preflight_check_ui_test_config`
     resets the contract vars before emitting new findings

Note: PREFLIGHT_* vars are set by preflight which runs ONCE per run, not per
iteration. They must NOT be reset between loop iterations — only at run start.
This test documents and asserts that behavior explicitly.
```

## Files Modified

| File | Change |
|------|--------|
| `tests/test_resilience_arc_integration.sh` | **New file.** All scenario groups S1.1–S7.2 (approx. 20 scenario tests) with fixture helpers and the `pass`/`fail` accounting pattern. |
| `tests/run_tests.sh` | **No change required.** Runner auto-discovers `tests/test_*.sh`; `test_resilience_arc_integration.sh` is picked up automatically by filename convention. |

No production code changes in this milestone. Test-only.

## Implementation Notes

### Fixture helper design

Each scenario group gets a dedicated fixture setup helper to avoid
repetitive boilerplate:

```bash
# _setup_bifl_tracker_m03_fixture  PROJECT_DIR
# Writes the minimal set of files that reproduce the bifl-tracker M03 state.
# Used by S6.1 and any subsequent regression tests.
_setup_bifl_tracker_m03_fixture() {
    local dir="$1"
    mkdir -p "${dir}/.claude/logs" "${dir}/.tekhton"

    # LAST_FAILURE_CONTEXT.json — v2 schema
    cat > "${dir}/.claude/LAST_FAILURE_CONTEXT.json" << 'EOF'
{
  "schema_version": 2,
  "classification": "UI_INTERACTIVE_REPORTER",
  "stage": "coder",
  "outcome": "failure",
  "task": "M03",
  "consecutive_count": 1,
  "primary_cause": {
    "category": "ENVIRONMENT",
    "subcategory": "test_infra",
    "signal": "ui_timeout_interactive_report",
    "source": "build_gate"
  },
  "secondary_cause": {
    "category": "AGENT_SCOPE",
    "subcategory": "max_turns",
    "signal": "build_fix_budget_exhausted",
    "source": "coder_build_fix"
  }
}
EOF
    # PIPELINE_STATE.md
    cat > "${dir}/.claude/PIPELINE_STATE.md" << 'EOF'
## Exit Stage
coder
## Exit Reason
complete_loop_max_attempts
## Task
M03
## Notes
Primary cause: ENVIRONMENT/test_infra (ui_timeout_interactive_report)
Secondary cause: AGENT_SCOPE/max_turns (build_fix_budget_exhausted)
EOF
    # Log with interactive reporter evidence
    mkdir -p "${dir}/.claude/logs"
    echo "Serving HTML report at http://localhost:9323. Press Ctrl+C to quit." \
        > "${dir}/.claude/logs/20260425_182710_m03.log"

    # playwright.config.ts
    cat > "${dir}/playwright.config.ts" << 'EOF'
import { defineConfig } from '@playwright/test';
export default defineConfig({
  reporter: 'html',
  testDir: './tests',
});
EOF
    # BUILD_RAW_ERRORS_FILE (non-empty, contains TS errors)
    local raw_errors_file="${dir}/${BUILD_RAW_ERRORS_FILE:-.tekhton/BUILD_RAW_ERRORS.txt}"
    mkdir -p "$(dirname "${raw_errors_file}")"
    cat > "${raw_errors_file}" << 'EOF'
src/app/page.tsx(12,5): error TS2304: Cannot find name 'undefined'.
src/lib/db.ts(8,3): error TS2339: Property 'query' does not exist.
EOF
}
```

Each scenario's `PROJECT_DIR` is a sub-directory of `$TMPDIR` so
parallel test isolation is possible and the global `trap 'rm -rf ...'`
handles all cleanup.

### Sourcing strategy for arc modules

Not all arc modules will exist before their milestones are implemented.
Use conditional sourcing so the test file itself can be added to the
repo now and expands as milestones land:

```bash
# Source arc modules — skip with a warn if not yet implemented
_arc_source() {
    local lib_file="${TEKHTON_HOME}/lib/$1"
    if [[ -f "$lib_file" ]]; then
        source "$lib_file"
    else
        echo "  SKIP (not yet implemented): lib/$1"
    fi
}

_arc_source "gates_ui.sh"               # m126
_arc_source "orchestrate_recovery.sh"   # m130 (already exists; gains new functions)
_arc_source "preflight_checks.sh"       # m131 (already exists; gains new function)
_arc_source "finalize_summary.sh"       # m132 (already exists; gains new fields)
_arc_source "diagnose_rules.sh"         # m133 (already exists; gains new rules)
```

When a module file exists but the specific function doesn't yet (because
the milestone is pending), individual test assertions are guarded with:

```bash
if declare -f _preflight_check_ui_test_config &>/dev/null; then
    # run the test
    ...
else
    echo "  SKIP S1.1: _preflight_check_ui_test_config not yet implemented (m131)"
fi
```

This means the test file is useful immediately: it documents exactly
which functions are expected from each milestone and reports `SKIP`
until they exist, then automatically activates when the milestone lands.

### Mock command pattern

For scenarios that need to simulate `UI_TEST_CMD` behavior, create a
temporary mock script in `$TMPDIR`:

```bash
# Create a mock UI_TEST_CMD that exits 124 with interactive reporter output
cat > "${TMPDIR}/mock_playwright.sh" << 'EOF'
#!/usr/bin/env bash
echo "Running 3 tests..."
echo "Serving HTML report at http://localhost:9323. Press Ctrl+C to quit."
exit 124
EOF
chmod +x "${TMPDIR}/mock_playwright.sh"
UI_TEST_CMD="${TMPDIR}/mock_playwright.sh"
export UI_TEST_CMD
```

### Test count and pass rate requirement

Target: all implemented scenarios pass on `main`. All unimplemented
scenarios (milestone pending) show `SKIP`. No `FAIL` entries on a clean
implementation.

The test runner at the bottom follows the standard pattern:

```bash
echo
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
```

## Acceptance Criteria

- [ ] `tests/test_resilience_arc_integration.sh` exists and runs without error from the Tekhton test suite.
- [ ] All implemented scenario assertions pass (no `FAIL` on a completed arc implementation).
- [ ] Unimplemented scenario assertions show `SKIP` rather than `FAIL` (milestone-pending guard).
- [ ] S6.1 ("bifl-tracker M03 golden path") produces `UI_GATE_INTERACTIVE_REPORTER` with no "CODER_MAX_TURNS" advice.
- [ ] S4.1–S4.4 validate the full write→read→route chain for failure context schema.
- [ ] S5.1 validates all four new RUN_SUMMARY.json fields are present and correctly populated.
- [ ] S7.1 confirms `_reset_orch_recovery_state` zeroes the persistent retry guards without clobbering loader-owned cause vars.
- [ ] S7.2 asserts the PREFLIGHT_* contract explicitly: no reset between iterations, reset at new-run boundary.
- [ ] `_setup_bifl_tracker_m03_fixture` is reusable — used by at least two scenarios.
- [ ] `test_resilience_arc_integration.sh` is auto-discovered by `./tests/run_tests.sh` via the existing `test_*.sh` glob.
- [ ] `shellcheck` clean for the new test file.

## Watch For

- Keep assertions behavior-first, not implementation-fragile. Prefer checking routed outcomes and emitted classifications over internal variable names unless the variable itself is the contract.
- Use artifact path vars (`BUILD_RAW_ERRORS_FILE`, `BUILD_ERRORS_FILE`, `BUILD_FIX_REPORT_FILE`) in fixtures and assertions; do not hardcode `.tekhton/...` or root-level filenames.
- Avoid shell options that break sourced library contracts. Test files can use `set -euo pipefail`, but helper stubs should avoid masking real failures from arc functions.
- Preserve one-run vs one-iteration semantics. Persistent `_ORCH_*` retry guards reset at new-run boundary; loader-owned cause vars refresh when `_load_failure_cause_context` runs; `PREFLIGHT_*` reset at preflight start for each run.
- Keep diagnose assertions resilient to wording drift. Assert required tokens/classifications, not full sentence equality in suggestions.
- Guard scenarios by function presence only where needed. Over-guarding can hide regressions once the full arc is implemented.

## Seeds Forward

- **m135 (artifact lifecycle):** Integration fixtures should remain compatible after success-path cleanup. Failure-path scenarios must continue to set required artifacts explicitly so tests do not rely on stale files.
- **m136 (config defaults + validation):** Add at least one scenario that runs with defaults only (no explicit arc vars), confirming integration behavior with declared defaults.
- **m137 (v3.2 migration):** Include a migrated-project fixture path (legacy `pipeline.conf` upgraded) to ensure arc integration tests still pass with migration-produced config shape.
- **m138 (runtime CI auto-detection):** Extend S1/S2 with CI-runtime cases where non-interactive behavior is auto-enabled without explicit `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1`.
- **Future diagnose/dashboard work:** Treat M134 scenario IDs (`S1.1`…`S7.2`) as stable references for regression tracking in future arc milestones and health reports.
