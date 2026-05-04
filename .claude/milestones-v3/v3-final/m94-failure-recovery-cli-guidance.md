# Milestone 94: Failure Recovery CLI Guidance & --diagnose Overhaul
<!-- milestone-meta
id: "94"
status: "done"
-->

## Overview

When Tekhton fails today, two things go wrong simultaneously:

1. **Silent exit.** The last lines printed are the agent's error, then a generic
   "State saved. Resume with: `tekhton --complete --milestone --start-at coder`."
   No explanation of what failed, no options, no context about whether that
   command will even work.

2. **`--diagnose` is only useful in success.** The rules require causal log
   events to classify failures. A run that fails before generating substantive
   events (e.g., max_turns on the first coder attempt) falls through to
   `_rule_unknown` with "No specific failure pattern identified." On the rare
   occasion a rule does fire, the suggestions are non-runnable fragments like
   "Run: tekhton --start-at review" — missing the task string, missing the
   correct `--start-at` option based on what artifacts are available.

This milestone fixes both by introducing a **two-tier recovery system**:

- **Tier 1 — Inline recovery block.** At every terminal exit path, print a
  formatted "WHAT HAPPENED / WHAT TO DO NEXT" block with exact runnable commands.
  Fires in-process, zero dependencies, always present.

- **Tier 2 — `--diagnose` overhaul.** Add a `_rule_max_turns` rule that fires
  from state files (no causal log required). Fix all suggestions to include
  runnable commands with variables substituted. Ensure `--diagnose` explicitly
  reads `LAST_FAILURE_CONTEXT.json` as a primary source, not a fallback.

## Design Decisions

### 1. Inline recovery block is in _save_orchestration_state

`_save_orchestration_state` is the single exit point for all orchestration
failures. It already prints `warn "State saved. Resume with: ..."`. This becomes
a structured multi-line block:

```
══════════════════════════════════════════════════════
  WHAT HAPPENED
══════════════════════════════════════════════════════
  The coder hit its turn limit 5 times in a row
  (AGENT_SCOPE/max_turns). Current budget: 80 turns.

══════════════════════════════════════════════════════
  WHAT TO DO NEXT
══════════════════════════════════════════════════════
  1. RESUME FROM TEST (REVIEWER_REPORT restored):
     tekhton --complete --milestone --start-at test "M88"

  2. RETRY WITH MORE TURNS:
     Set CODER_MAX_TURNS=120 in pipeline.conf, then:
     tekhton --complete --milestone "M88"

  3. DETAILED DIAGNOSIS:
     tekhton --diagnose
══════════════════════════════════════════════════════
```

The "WHAT HAPPENED" block is built from the same state that is saved to
`PIPELINE_STATE.md`. The "WHAT TO DO NEXT" block uses the same
`_choose_resume_start_at()` logic from M93.

### 2. _print_recovery_block() in lib/orchestrate_helpers.sh

A new function `_print_recovery_block()` takes:
- `outcome` — the exit reason string (`max_attempts`, `timeout`, etc.)
- `detail` — the human-readable detail from `_save_orchestration_state`
- `resume_flags` — the already-computed resume command flags
- `task` — `$TASK`

It prints the formatted block to stdout (not stderr so it's visible even when
stderr is suppressed).

### 3. --diagnose: add _rule_max_turns

A new rule that fires when:
- `PIPELINE_STATE.md` Exit Reason contains `complete_loop_max_attempts`, AND
- `LAST_FAILURE_CONTEXT.json` error category is `AGENT_SCOPE/max_turns` OR
- `PIPELINE_STATE.md` Notes contains "max_turns"

This rule should fire **before** `_rule_review_rejection_loop` since max_turns
is more specific. Suggestions generated include the exact resume command.

### 4. --diagnose: fix suggestion quality across all rules

Each `DIAG_SUGGESTIONS` array should include at least one runnable command:
```bash
DIAG_SUGGESTIONS=(
    "The coder hit its turn limit on ${cycle_count} consecutive attempts."
    "Likely cause: the milestone scope is too large for CODER_MAX_TURNS=${CODER_MAX_TURNS:-80}."
    "To resume (fast): tekhton --milestone --start-at test \"${_DIAG_PIPELINE_TASK}\""
    "To retry with more turns: edit pipeline.conf: CODER_MAX_TURNS=120"
    "To split the milestone: tekhton --milestone \"${_DIAG_PIPELINE_TASK}\" (will auto-split if enabled)"
)
```

The task variable `_DIAG_PIPELINE_TASK` is already populated in `_read_diagnostic_context`.
All rules must substitute it into command suggestions.

### 5. --diagnose: read LAST_FAILURE_CONTEXT.json first

Currently `LAST_FAILURE_CONTEXT.json` is a fallback if `RUN_SUMMARY.json`
didn't populate `_DIAG_PIPELINE_OUTCOME`. This should be reversed: read
`LAST_FAILURE_CONTEXT.json` eagerly (it's always written on failure), and use
`RUN_SUMMARY.json` for enrichment.

### 6. --diagnose: classify from state files, not just causal log

Rules that currently require N causal log events should have a fast-path check
on `PIPELINE_STATE.md` Exit Reason or `LAST_FAILURE_CONTEXT.json` classification.
This makes `--diagnose` useful even before any causal events are generated.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Shell files modified | 3 | `lib/orchestrate_helpers.sh`, `lib/diagnose_rules.sh`, `lib/diagnose.sh` |
| Shell tests modified | 1 | `tests/test_diagnose.sh` — add max_turns rule tests |
| Shell tests added | 1 | `tests/test_recovery_block.sh` |

## Implementation Plan

### Step 1 — lib/orchestrate_helpers.sh: _print_recovery_block()

```bash
_print_recovery_block() {
    local outcome="$1"
    local detail="$2"
    local resume_cmd="$3"  # full tekhton command to resume
    local task="$4"

    # Human-readable outcome
    local what_happened
    case "$outcome" in
        max_attempts)
            what_happened="Agent hit its turn limit on 5 consecutive attempts."
            what_happened="${what_happened} Current limit: ${EFFECTIVE_CODER_MAX_TURNS:-${CODER_MAX_TURNS:-80}} turns."
            ;;
        timeout)
            what_happened="Pipeline exceeded the autonomous timeout (${AUTONOMOUS_TIMEOUT:-7200}s)."
            ;;
        agent_cap)
            what_happened="Pipeline exceeded the max agent call cap."
            ;;
        pre_existing_failure)
            what_happened="Tests are failing before code changes. Pre-existing test failures detected."
            ;;
        *)
            what_happened="$detail"
            ;;
    esac

    local _sep="══════════════════════════════════════════════════"
    echo
    echo -e "${BOLD}${_sep}${NC}"
    echo -e "${BOLD}  WHAT HAPPENED${NC}"
    echo -e "${BOLD}${_sep}${NC}"
    echo "  ${what_happened}"
    echo
    echo -e "${BOLD}${_sep}${NC}"
    echo -e "${BOLD}  WHAT TO DO NEXT${NC}"
    echo -e "${BOLD}${_sep}${NC}"
    echo "  1. RESUME  →  ${resume_cmd}"

    # Context-specific additional options
    case "$outcome" in
        max_attempts)
            echo "  2. MORE TURNS  →  edit pipeline.conf: CODER_MAX_TURNS=$(( ${CODER_MAX_TURNS:-80} + 40 ))"
            echo "                    then: tekhton ${_base_flags:-} \"${task}\""
            ;;
    esac

    echo "  3. DIAGNOSE  →  tekhton --diagnose"
    echo -e "${BOLD}${_sep}${NC}"
    echo
}
```

Call `_print_recovery_block` at the end of `_save_orchestration_state`, after
`write_pipeline_state`, passing the computed `resume_flags` with task appended.

### Step 2 — lib/diagnose_rules.sh: _rule_max_turns()

```bash
_rule_max_turns() {
    local failure_ctx="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"

    # Fast-path: check LAST_FAILURE_CONTEXT.json
    local _cat="" _sub=""
    if [[ -f "$failure_ctx" ]]; then
        _cat=$(grep -oP '"category"\s*:\s*"\K[^"]+' "$failure_ctx" 2>/dev/null || true)
        _sub=$(grep -oP '"subcategory"\s*:\s*"\K[^"]+' "$failure_ctx" 2>/dev/null || true)
    fi

    # Also check pipeline state notes
    local _state_notes=""
    if [[ -f "$state_file" ]]; then
        _state_notes=$(awk '/^## Notes$/{f=1;next} /^## /{f=0} f' "$state_file" 2>/dev/null || true)
    fi

    if [[ "$_cat/$_sub" != "AGENT_SCOPE/max_turns" ]] && \
       ! grep -q "max_turns\|complete_loop_max_attempts" <<< "${_state_notes}" 2>/dev/null; then
        return 1
    fi

    local _stage="${_DIAG_PIPELINE_STAGE:-coder}"
    local _task="${_DIAG_PIPELINE_TASK:-}"
    local _limit="${CODER_MAX_TURNS:-80}"

    DIAG_CLASSIFICATION="MAX_TURNS_EXHAUSTED"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "The ${_stage} agent hit its turn limit (${_limit} turns) on consecutive attempts."
        "The task scope is likely too large for the current turn budget."
        "To resume (if reviewer previously ran):"
        "  tekhton --complete --milestone --start-at test \"${_task}\""
        "To retry with higher turn limit (edit pipeline.conf: CODER_MAX_TURNS=$((_limit + 40))):"
        "  tekhton --complete --milestone \"${_task}\""
        "To split the milestone into smaller chunks:"
        "  tekhton --complete --milestone \"${_task}\"  (auto-split if MILESTONE_SPLIT_ENABLED=true)"
    )
    return 0
}
```

Register `_rule_max_turns` first in `DIAGNOSE_RULES` array.

### Step 3 — lib/diagnose_rules.sh: fix REVIEW_REJECTION_LOOP suggestions

Replace the current vague suggestions with runnable commands including task variable. The `_DIAG_PIPELINE_TASK` variable is already populated — use it.

### Step 4 — lib/diagnose.sh: _read_diagnostic_context() priority fix

Swap the order: read `LAST_FAILURE_CONTEXT.json` eagerly before `RUN_SUMMARY.json`.
Add direct extraction of `classification` field from `LAST_FAILURE_CONTEXT.json`.

### Step 5 — Shell tests

`tests/test_recovery_block.sh`:
- `test_max_turns_block_format` — call `_print_recovery_block max_attempts "..." "cmd" "task"`, assert key sections present
- `test_review_rejection_resume_cmd_present` — block contains a tekhton command
`tests/test_diagnose.sh` additions:
- `test_max_turns_rule_fires_from_failure_ctx` — write LAST_FAILURE_CONTEXT.json with AGENT_SCOPE/max_turns, run classify, assert MAX_TURNS_EXHAUSTED
- `test_max_turns_rule_fires_from_state_notes` — write state file with max_turns note, assert same

## Files Touched

### Modified
- `lib/orchestrate_helpers.sh` — `_print_recovery_block()` + call in `_save_orchestration_state`
- `lib/diagnose_rules.sh` — `_rule_max_turns()`, fix all DIAG_SUGGESTIONS to include task variable and runnable commands, register `_rule_max_turns` first
- `lib/diagnose.sh` — `_read_diagnostic_context()` reads `LAST_FAILURE_CONTEXT.json` eagerly
- `tests/test_diagnose.sh` — new test cases

### Added
- `tests/test_recovery_block.sh`

## Acceptance Criteria

- [ ] When `_save_orchestration_state` fires, a "WHAT HAPPENED / WHAT TO DO NEXT" block is printed to stdout
- [ ] The block contains at least one complete, runnable `tekhton ...` command
- [ ] The runnable command matches the smart resume command from M93 (`--start-at test` when reviewer report exists)
- [ ] `tekhton --diagnose` after a `max_turns` failure returns classification `MAX_TURNS_EXHAUSTED` (not `UNKNOWN`)
- [ ] All `DIAG_SUGGESTIONS` arrays in rules include the `_DIAG_PIPELINE_TASK` variable in command suggestions
- [ ] `tekhton --diagnose` runs meaningfully even with an empty causal log, using `LAST_FAILURE_CONTEXT.json` and `PIPELINE_STATE.md` as the primary source
- [ ] `bash tests/test_recovery_block.sh` passes
- [ ] Modified `tests/test_diagnose.sh` passes
- [ ] `shellcheck lib/orchestrate_helpers.sh lib/diagnose_rules.sh lib/diagnose.sh` zero warnings
- [ ] No regression on `bash tests/run_tests.sh`

## Watch For

- Color codes (`${BOLD}`, `${NC}`) may not be set in all test contexts. Guard
  with `${BOLD:-}` so the block still prints without formatting in tests.
- The inline recovery block fires on every `_save_orchestration_state` call,
  including `timeout` and `agent_cap`. Ensure all `case "$outcome"` branches
  produce useful output, not blank `what_happened` strings.
- `_DIAG_PIPELINE_TASK` may be empty if the run failed before the state file
  was written. Fall back to `${TASK:-<task not recorded>}` in the diagnose rules.

## Seeds Forward

- M92's pre-run fix agent failures benefit directly: "Tests were failing before
  the coder ran. A fix agent was spawned but couldn't restore clean state. See
  `PRE_RUN_CLEAN_ENABLED` in pipeline.conf to disable."
- Future: add a `--diagnose --fix` flag that automatically applies the top
  suggestion (e.g., bumps `CODER_MAX_TURNS` in `pipeline.conf` and re-runs).
