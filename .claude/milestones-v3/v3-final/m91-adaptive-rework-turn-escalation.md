# Milestone 91: Adaptive Rework Turn Escalation
<!-- milestone-meta
id: "91"
status: "done"
-->

## Overview

When a coder, tester, or fix agent hits `max_turns` and the orchestrator
retries, it invokes the agent again with the *same* turn limit — guaranteeing the
same failure. The only recourse today is to manually edit `pipeline.conf` or wait
for the human to notice.

This milestone adds turn escalation: each consecutive `AGENT_SCOPE/max_turns`
failure on the same stage within a `--complete` run multiplies the effective
turn budget by `REWORK_TURN_ESCALATION_FACTOR` (default: 1.5), capped at
`CODER_MAX_TURNS_CAP`. After a successful stage run the escalation counter
resets. No manual `pipeline.conf` edits needed.

## Design Decisions

### 1. Single multiplier, tracked in the orchestrator

`lib/orchestrate.sh` already tracks `_ORCH_ATTEMPT` (consecutive failures).
A parallel counter `_ORCH_CONSECUTIVE_MAX_TURNS` increments only when the
classified failure is `AGENT_SCOPE/max_turns` and resets on any success.

The effective turn cap is computed once before each stage invocation and
exported as `EFFECTIVE_CODER_MAX_TURNS`, `EFFECTIVE_JR_CODER_MAX_TURNS`, etc.
Stages read `${EFFECTIVE_CODER_MAX_TURNS:-$CODER_MAX_TURNS}`.

### 2. Stage-scoped, not global

The counter tracks per stage (`coder`, `tester`, `build_fix`, `final_fix`).
A max_turns on the coder shouldn't escalate the tester's budget. Track with
`_ORCH_MAX_TURNS_STAGE` so a counter reset fires when the failed stage changes.

### 3. No escalation outside --complete

`_ORCH_CONSECUTIVE_MAX_TURNS` is only meaningful in the `run_complete_loop`
path. Single-run invocations (no `--complete`) are unaffected.

### 4. Escalation is surfaced in logs and PIPELINE_STATE

When escalation fires, a `warn` line explains: `[orchestrate] max_turns hit 2
consecutive times for coder — escalating to 120 turns for next attempt.`
`PIPELINE_STATE.md` includes the multiplied value in its Notes field.

### 5. Cap prevents runaway

`REWORK_TURN_MAX_CAP` (default: `CODER_MAX_TURNS_CAP` = 200) is a hard ceiling.
If escalated budget would exceed it, it's clamped. Further max_turns failures
at the cap log a warning and recommend `--split-milestone`.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Shell files modified | 3 | `lib/orchestrate.sh`, `lib/orchestrate_helpers.sh`, `lib/config_defaults.sh` |
| Shell files modified | 2 | `stages/coder.sh`, `stages/tester.sh` |
| Shell tests added | 1 | `tests/test_adaptive_turn_escalation.sh` |

## Implementation Plan

### Step 1 — lib/config_defaults.sh: new keys

```bash
: "${REWORK_TURN_ESCALATION_FACTOR:=1.5}"   # multiplier per consecutive max_turns
: "${REWORK_TURN_MAX_CAP:=${CODER_MAX_TURNS_CAP}}"  # ceiling for escalated budgets
: "${REWORK_TURN_ESCALATION_ENABLED:=true}" # toggle (false = old behavior)
```

### Step 2 — lib/orchestrate.sh: counter tracking

Add two variables at the top of `run_complete_loop`:
```bash
_ORCH_CONSECUTIVE_MAX_TURNS=0
_ORCH_MAX_TURNS_STAGE=""
```

After each pipeline attempt (before deciding whether to retry), check the
last error classification:
```bash
if [[ "$AGENT_ERROR_CATEGORY" = "AGENT_SCOPE" ]] && \
   [[ "$AGENT_ERROR_SUBCATEGORY" = "max_turns" ]] && \
   [[ "${REWORK_TURN_ESCALATION_ENABLED:-true}" = "true" ]]; then
    if [[ "$START_AT" = "$_ORCH_MAX_TURNS_STAGE" ]]; then
        _ORCH_CONSECUTIVE_MAX_TURNS=$(( _ORCH_CONSECUTIVE_MAX_TURNS + 1 ))
    else
        _ORCH_CONSECUTIVE_MAX_TURNS=1
        _ORCH_MAX_TURNS_STAGE="$START_AT"
    fi
    _apply_turn_escalation "$_ORCH_CONSECUTIVE_MAX_TURNS"
else
    # Success or different failure: reset
    _ORCH_CONSECUTIVE_MAX_TURNS=0
    _ORCH_MAX_TURNS_STAGE=""
fi
```

### Step 3 — lib/orchestrate_helpers.sh: _apply_turn_escalation()

```bash
_apply_turn_escalation() {
    local count="$1"
    local factor="${REWORK_TURN_ESCALATION_FACTOR:-1.5}"
    local cap="${REWORK_TURN_MAX_CAP:-${CODER_MAX_TURNS_CAP:-200}}"

    # integer multiply using awk (avoids bc dependency)
    local multiplied
    multiplied=$(awk "BEGIN { printf \"%d\", int(${CODER_MAX_TURNS} * (1 + ($factor * $count))) }")
    EFFECTIVE_CODER_MAX_TURNS=$(( multiplied > cap ? cap : multiplied ))

    multiplied=$(awk "BEGIN { printf \"%d\", int(${JR_CODER_MAX_TURNS} * (1 + ($factor * $count))) }")
    EFFECTIVE_JR_CODER_MAX_TURNS=$(( multiplied > cap ? cap : multiplied ))

    export EFFECTIVE_CODER_MAX_TURNS EFFECTIVE_JR_CODER_MAX_TURNS
    warn "[orchestrate] max_turns hit ${count}x for ${_ORCH_MAX_TURNS_STAGE} — escalating to ${EFFECTIVE_CODER_MAX_TURNS} turns."
}
```

### Step 4 — stages/coder.sh and stages/tester.sh: consume EFFECTIVE_*

Replace hard references to `$CODER_MAX_TURNS` in `run_agent` calls with
`${EFFECTIVE_CODER_MAX_TURNS:-$CODER_MAX_TURNS}`. Same for JR_CODER and fix
agent turn limits that use arithmetic on `CODER_MAX_TURNS`.

### Step 5 — Shell tests

`tests/test_adaptive_turn_escalation.sh`:
- `test_counter_increments_on_max_turns` — set `AGENT_SCOPE/max_turns`, call update logic, assert counter = 1
- `test_counter_resets_on_success` — counter at 2, success → assert counter = 0
- `test_counter_resets_on_stage_change` — counter at 2 for coder, failure on tester → assert counter = 1 for tester
- `test_escalated_cap` — escalated value above cap → clamped to cap
- `test_disabled_flag` — `REWORK_TURN_ESCALATION_ENABLED=false` → EFFECTIVE_CODER_MAX_TURNS not set

## Files Touched

### Modified
- `lib/orchestrate.sh` — counter tracking + reset logic in `run_complete_loop`
- `lib/orchestrate_helpers.sh` — `_apply_turn_escalation()`
- `lib/config_defaults.sh` — three new keys
- `stages/coder.sh` — consume `EFFECTIVE_CODER_MAX_TURNS`
- `stages/tester.sh` — consume `EFFECTIVE_CODER_MAX_TURNS` / `EFFECTIVE_JR_CODER_MAX_TURNS`

### Added
- `tests/test_adaptive_turn_escalation.sh`

## Acceptance Criteria

- [ ] After 1 consecutive `AGENT_SCOPE/max_turns` on coder, `EFFECTIVE_CODER_MAX_TURNS` is set to `floor(CODER_MAX_TURNS * (1 + REWORK_TURN_ESCALATION_FACTOR))`
- [ ] After 2 consecutive, it multiplies again (compounding)
- [ ] Counter resets to 0 after any successful pipeline run
- [ ] Counter resets to 1 (not 0) when the failing stage changes
- [ ] Escalated value is never above `REWORK_TURN_MAX_CAP`
- [ ] `REWORK_TURN_ESCALATION_ENABLED=false` leaves `EFFECTIVE_CODER_MAX_TURNS` unset (stages use base value)
- [ ] A `warn` line is emitted for every escalation, naming the stage and new limit
- [ ] `bash tests/test_adaptive_turn_escalation.sh` passes
- [ ] `shellcheck lib/orchestrate.sh lib/orchestrate_helpers.sh stages/coder.sh stages/tester.sh` reports zero warnings
- [ ] No behavior change on single-run (no `--complete`) invocations

## Watch For

- `awk` not available in some minimal environments — guard with `command -v awk`
  and fall back to integer shell arithmetic (multiply by 10, divide, to avoid
  fractional values).
- `EFFECTIVE_CODER_MAX_TURNS` must be unset (not set to base value) at run start,
  so that the first attempt always uses the configured `CODER_MAX_TURNS` even
  if the variable was exported from a parent shell.
- The escalation is per `--complete` run, not per Tekhton invocation. It does
  not persist across invocations (no state file).

## Seeds Forward

- M92 (pristine test state) spawns a pre-coder fix agent that benefits from
  this escalation: if the fix agent hits max_turns too, it escalates automatically.
- Future: persist escalation state across invocations so that a resumed run
  starts with the last effective budget.
