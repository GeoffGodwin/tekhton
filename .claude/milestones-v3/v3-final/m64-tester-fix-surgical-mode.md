# Milestone 64: Tester Fix — Surgical Mode
<!-- milestone-meta
id: "64"
status: "done"
-->

## Overview

When `TESTER_FIX_ENABLED=true` and the tester stage detects test failures, it
spawns a **complete recursive pipeline run** — coder, reviewer, tester, all
stages. For a single failing test, this can add 40+ minutes to the run. The
recursive approach was designed for cases where implementation bugs cause test
failures, but most tester-stage failures are simpler: wrong assertions, missing
imports, stale mocks, or constructor signature mismatches.

This milestone replaces the full-pipeline recursion with a lightweight surgical
fix agent that operates within the tester stage itself, similar to how the coder's
build-fix retry works within the coder stage (`coder.sh:1084-1110`).

Depends on M63 (Test Baseline Hygiene) so the fix agent has accurate baseline
data and doesn't waste effort on pre-existing failures.

## Current State (What Exists Today)

The following code is in place and must be **replaced**, not extended:

- `stages/tester.sh:226-259` — Recursive pipeline invocation via
  `bash "${TEKHTON_HOME}/tekhton.sh" "$_fix_task"`. This spawns a full coder →
  reviewer → tester cycle. Remove entirely.
- `TEKHTON_FIX_DEPTH` env var — Used as recursion guard for the recursive
  approach. No longer needed with inline fix.
- `lib/config_defaults.sh:323-326` — Config keys exist:
  - `TESTER_FIX_ENABLED=false` (keep as-is)
  - `TESTER_FIX_MAX_DEPTH=1` (repurpose: now means inline fix attempts)
  - `TESTER_FIX_OUTPUT_LIMIT=4000` (keep as-is)
  - `TESTER_FIX_MAX_TURNS` — **MISSING, must be added**

**Reference implementation:** `coder.sh:1084-1110` (inline build-fix pattern):
```bash
BUILD_FIX_PROMPT=$(render_prompt "build_fix")
run_agent "Coder (build fix)" "$CLAUDE_CODER_MODEL" \
    "$((CODER_MAX_TURNS / 3))" "$BUILD_FIX_PROMPT" "$LOG_FILE" \
    "$AGENT_TOOLS_BUILD_FIX"
```

## Scope

### 1. Add TESTER_FIX_MAX_TURNS Config Key

**File:** `lib/config_defaults.sh`

Add after the existing TESTER_FIX keys (line 326):
```bash
: "${TESTER_FIX_MAX_TURNS:=$((CODER_MAX_TURNS / 3))}"
```

Also add clamp (like FINAL_FIX at line 469):
```bash
_clamp_config_value TESTER_FIX_MAX_TURNS 100
```

Update comment on line 325 from "Max recursive fix attempts (recursion guard)"
to "Max inline fix attempts per tester stage".

### 2. Create Tester Fix Prompt

**File:** `prompts/tester_fix.prompt.md` (new)

Model on `prompts/build_fix.prompt.md` — focused, short, no architecture bloat.

```markdown
# Tester Fix Agent

You are fixing test failures. The tests below are failing after a tester
agent wrote or modified them.

## Failing Test Output
{{TESTER_FIX_OUTPUT}}

## Test Files
{{TESTER_FIX_TEST_FILES}}

## Source Files (from CODER_SUMMARY.md)
{{TESTER_FIX_SOURCE_FILES}}

{{IF:TEST_BASELINE_SUMMARY}}
## Pre-Existing Failures (DO NOT fix these)
{{TEST_BASELINE_SUMMARY}}
{{ENDIF:TEST_BASELINE_SUMMARY}}

{{IF:SERENA_ACTIVE}}
## LSP Tools Available
You have LSP tools via MCP: `find_symbol`, `find_referencing_symbols`,
`get_symbol_definition`. Use these to verify signatures before fixing tests.
{{ENDIF:SERENA_ACTIVE}}

## Rules
1. Fix the TEST code, not the implementation.
2. If the implementation is genuinely wrong (tests are correct but code is
   buggy), document the bug in TESTER_REPORT.md under "## Bugs Found" and
   do NOT attempt to fix the implementation.
3. Do NOT modify files outside the test directory unless the test imports
   or fixtures require it.
4. Run {{TEST_CMD}} to verify your fixes.
5. Update TESTER_REPORT.md with what you fixed.
```

### 3. Inline Tester Fix Agent

**File:** `stages/tester.sh`

Replace lines 226-259 (recursive pipeline invocation) with inline fix agent.
Follow the `coder.sh:1084-1110` pattern exactly:

```bash
if [[ "${TESTER_FIX_ENABLED:-false}" == "true" ]]; then
    local _fix_depth=0
    local _max_depth="${TESTER_FIX_MAX_DEPTH:-1}"

    while [[ "$_fix_depth" -lt "$_max_depth" ]]; do
        _fix_depth=$((_fix_depth + 1))

        # Extract failing test output
        local _failure_output _output_limit
        _output_limit="${TESTER_FIX_OUTPUT_LIMIT:-4000}"
        _failure_output=$(grep -E '(FAIL|ERROR|error|failure|assert)' \
            "$LOG_FILE" | tail -c "$_output_limit" || true)
        if [[ -z "$_failure_output" ]]; then
            _failure_output=$(tail -100 "$LOG_FILE" | tail -c "$_output_limit")
        fi

        # Baseline-aware gating (requires M63)
        if [[ "${TEST_BASELINE_ENABLED:-false}" == "true" ]] && has_test_baseline; then
            local _comparison
            _comparison=$(compare_test_with_baseline "$_failure_output" "$_test_exit")
            if [[ "$_comparison" == "pre_existing" ]]; then
                log "All test failures are pre-existing — skipping tester fix."
                break
            fi
        fi

        # Build scoped context
        export TESTER_FIX_OUTPUT="$_failure_output"
        export TESTER_FIX_TEST_FILES=""  # Extract from test output paths
        export TESTER_FIX_SOURCE_FILES="" # Extract from CODER_SUMMARY.md

        # Extract file paths from CODER_SUMMARY.md
        if [ -f "CODER_SUMMARY.md" ]; then
            TESTER_FIX_SOURCE_FILES=$(extract_files_from_coder_summary 2>/dev/null || true)
        fi

        # Render scoped prompt and run inline agent
        _phase_start "tester_fix"
        local _fix_prompt
        _fix_prompt=$(render_prompt "tester_fix")
        run_agent "Tester (fix)" "$CLAUDE_CODER_MODEL" \
            "${TESTER_FIX_MAX_TURNS}" "$_fix_prompt" "$LOG_FILE" \
            "$AGENT_TOOLS_BUILD_FIX"
        _phase_end "tester_fix"

        # Log fix attempt in causal log
        emit_causal_event "tester_fix_attempt" "attempt_${_fix_depth}" \
            "exit=${LAST_AGENT_EXIT_CODE} turns=${LAST_AGENT_TURNS}"

        # Re-run tests to verify fix
        # (Use the pipeline's test gate, not a separate invocation)
        break  # Single attempt by default; loop only if MAX_DEPTH > 1
    done
fi
```

### 4. Remove Recursive Pipeline Spawn

**File:** `stages/tester.sh`

Delete entirely:
- The `TEKHTON_FIX_DEPTH` environment variable check
- The `bash "${TEKHTON_HOME}/tekhton.sh" "$_fix_task"` invocation
- The `SKIP_FINAL_CHECKS=true` / `clear_pipeline_state` success handling

The inline fix agent replaces all of this. After fix, normal pipeline flow
continues (test gate will be re-evaluated by the orchestration layer).

### 5. Smart Test Output Truncation

**File:** `stages/tester.sh` (or `lib/agent_helpers.sh`)

Replace the current naive `grep + tail -c` truncation with smarter extraction:
- Split test output by failure markers (FAIL, ERROR, etc.)
- For each failure block, keep first 5 and last 5 lines
- Cap total at `TESTER_FIX_OUTPUT_LIMIT` chars
- Preserve actual error messages over stack traces

This is a helper function, not a separate file:
```bash
_smart_truncate_test_output() {
    local output="$1" limit="${2:-4000}"
    # ... implementation ...
}
```

## Migration Impact

| Key | Default | Change |
|-----|---------|--------|
| `TESTER_FIX_ENABLED` | `false` | No change — still opt-in |
| `TESTER_FIX_MAX_DEPTH` | `1` | Now means inline fix attempts, not pipeline recursions |
| `TESTER_FIX_MAX_TURNS` | `CODER_MAX_TURNS / 3` | **New key** — turn budget per fix attempt |
| `TESTER_FIX_OUTPUT_LIMIT` | `4000` | No change |

The `TEKHTON_FIX_DEPTH` environment variable is no longer set or checked.
Existing pipeline.conf files with `TESTER_FIX_MAX_DEPTH` continue to work
(same key, new semantics: inline attempts instead of recursive depth).

## Acceptance Criteria

- Tester fix uses inline agent, NOT recursive pipeline spawn
- No reference to `tekhton.sh` recursive invocation remains in tester.sh
- Fix agent receives focused context (test output + files only, no architecture)
- Pre-existing failures are filtered out before fix attempt (requires M63)
- Fix agent has Serena/repo map access when available (via prompt conditionals)
- `TESTER_FIX_ENABLED=false` skips fix entirely
- `TESTER_FIX_MAX_DEPTH=0` disables fix attempts
- Fix agent time is tracked as `tester_fix` sub-phase in timing report
- All existing tests pass
- Fix attempts are logged in causal event log
- `TESTER_FIX_MAX_TURNS` config key exists with clamp

Tests:
- Fix agent spawns with correct scoped context (no architecture/design bloat)
- Pre-existing failure filtering skips fix when all failures are baseline
- Mixed failures correctly filter to only new failures
- `TESTER_FIX_ENABLED=false` skips fix entirely (no agent spawned)
- `TESTER_FIX_MAX_DEPTH=0` skips fix entirely
- Turn budget respected (agent gets TESTER_FIX_MAX_TURNS, not TESTER_MAX_TURNS)
- Phase timing wraps fix agent (`_phase_start "tester_fix"` / `_phase_end`)
- Causal event emitted with attempt number and exit code
- Smart truncation preserves error messages over stack traces

Watch For:
- The fix agent MUST NOT modify implementation code. The prompt is explicit
  about this boundary. If the fix agent modifies non-test files, those changes
  haven't been validated by the reviewer. The prompt must be very clear.
- Some test failures genuinely require implementation fixes (real bugs found by
  tests). The fix agent should document these in Bugs Found rather than attempting
  a fix it's not scoped for.
- The `TESTER_FIX_OUTPUT_LIMIT` cap must be sufficient to include the actual
  error messages, not just stack traces. The smart truncation helps here.
- Serena/repo map guidance references M65. If M65 hasn't run yet, the
  `{{IF:SERENA_ACTIVE}}` block simply won't render. No hard dependency.

Seeds Forward:
- Surgical fix data feeds into run metrics for fix success rate tracking
- Pattern of scoped fix agents could be reused for review rework
- Smart test output truncation is reusable by M62 timing extraction
