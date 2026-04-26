# M130 - Causal-Context-Aware Recovery Routing

<!-- milestone-meta
id: "130"
status: "pending"
-->

## Overview

The m126–m129 series produces progressively richer failure intelligence:

| Milestone | What it adds |
|-----------|-------------|
| m126 | Deterministic UI gate execution; interactive-reporter timeout detection |
| m127 | Confidence-based log classification; distinguishes code vs environment signals |
| m128 | Bounded build-fix loop; progress-gated retry |
| m129 | Schema v2 `LAST_FAILURE_CONTEXT.json`; explicit `primary_cause` / `secondary_cause` objects |

None of that intelligence yet reaches the top-level recovery decision
tree. `_classify_failure` in `lib/orchestrate_recovery.sh` branches
only on the flat `AGENT_ERROR_CATEGORY` / `AGENT_ERROR_SUBCATEGORY`
pair. Gaps:

1. **`ENVIRONMENT` always routes `save_exit`.**  
   After m126/m129, an `ENVIRONMENT/test_infra` failure with signal
   `ui_timeout_interactive_report` is a *deterministically recoverable*
   condition: re-run the gate with the non-interactive env profile.
   The current router discards that knowledge and exits.

2. **`AGENT_SCOPE/max_turns` always routes `split`.**  
   When m129 shows primary cause is `ENVIRONMENT/test_infra` and
   secondary is `AGENT_SCOPE/max_turns`, the max_turns event is a
   *symptom*, not the root cause. Splitting the milestone hands a larger
   context window to the same unresolvable gate condition — still no fix.
   The correct action is to re-run the gate with environment remediation
   applied first.

3. **Build-gate failures bypass the causal schema entirely.**  
   The existing `retry_coder_build` branch fires whenever
   `BUILD_ERRORS_FILE` is non-empty, regardless of whether the
   classification system has high or low confidence. A
   `mixed_uncertain` classification from m127 should not trigger the
   same aggressive retry as a `code_dominant` one.

4. **`_print_recovery_block` cannot produce cause-specific guidance.**  
   It only branches on `outcome` (max_attempts, timeout, etc.) and
   prints generic `--diagnose` as the escalation path. With primary/
   secondary cause available, it can print the actual cause in plain
   English and suggest the most targeted follow-up.

M130 upgrades `_classify_failure` and `_print_recovery_block` to
consume the v2 failure context schema and produce cause-specific
routing decisions. One new recovery *action* is added —
`retry_ui_gate_env` — but it is implemented as a thin variant of the
existing `retry_coder_build` pattern (export env, re-loop), not as a
new orchestration mechanism. The goal is to route *existing* actions
more accurately and stop actions that cannot help.

## Where the relevant code lives (verified at write time)

- `_classify_failure` and `_print_recovery_block` live in
  `lib/orchestrate_recovery.sh` (currently 242 lines — see "300-line
  ceiling" in Watch For).
- The recovery-action `case` dispatcher that consumes
  `_classify_failure`'s return is in
  `lib/orchestrate_loop.sh:_handle_pipeline_failure` (lines ~187–253),
  **not** in `lib/orchestrate.sh:run_complete_loop`. `run_complete_loop`
  delegates to `_handle_pipeline_failure` via the
  `_handle_pipeline_failure "$_iter_turns" "$_files_changed"` call at
  `lib/orchestrate.sh:251`.
- The persistent retry guard pattern this milestone follows is
  `_ORCH_BUILD_RETRIED` — declared at `lib/orchestrate.sh:57`, reset
  once at `run_complete_loop` start (`lib/orchestrate.sh:94`), set true
  in the `retry_coder_build` case branch
  (`lib/orchestrate_loop.sh:221`). Mirror that lifecycle for
  `_ORCH_ENV_GATE_RETRIED` and `_ORCH_MIXED_BUILD_RETRIED`. Do **not**
  reset them per-iteration — that breaks the retry-once semantic.
- `_print_recovery_block`'s only caller in the failure path is
  `lib/orchestrate_helpers.sh:_save_orchestration_state` (line ~231).
  That's where cause_summary must be assembled and passed.
- The m126 `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1` Priority 0
  framework-detection rule (m126 "Seeds Forward") is the mechanism by
  which `retry_ui_gate_env` actually re-runs the gate with hardened
  env. If m126 ships without that hook, this milestone must add the
  one-liner check in `lib/gates_ui.sh:_ui_detect_framework` before the
  new action becomes useful — see "Watch For" below.

## Design

### Goal 1 — Add a context loader for failure cause schema v2

Add a new helper at the top of `lib/orchestrate_recovery.sh`:

```bash
# _load_failure_cause_context
# Reads LAST_FAILURE_CONTEXT.json (schema v1 or v2) and populates:
#   _ORCH_PRIMARY_CAT, _ORCH_PRIMARY_SUB, _ORCH_PRIMARY_SIGNAL,
#   _ORCH_SECONDARY_CAT, _ORCH_SECONDARY_SUB, _ORCH_SECONDARY_SIGNAL,
#   _ORCH_SCHEMA_VERSION (1 or 2)
#
# Degrades gracefully when the file is absent or has v1 shape:
#   - v1 shape: populates _ORCH_SECONDARY_* from top-level category/subcategory,
#     leaves _ORCH_PRIMARY_* empty.
#   - File absent: all vars empty, _ORCH_SCHEMA_VERSION=0.
#
# Must be called before _classify_failure. Safe to call multiple times
# (idempotent — reads file once, cached in module vars).
_load_failure_cause_context() {
    _ORCH_PRIMARY_CAT=""
    _ORCH_PRIMARY_SUB=""
    _ORCH_PRIMARY_SIGNAL=""
    _ORCH_SECONDARY_CAT=""
    _ORCH_SECONDARY_SUB=""
    _ORCH_SECONDARY_SIGNAL=""
    _ORCH_SCHEMA_VERSION=0

    local ctx_file="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"
    [[ -f "$ctx_file" ]] || return 0

    _ORCH_SCHEMA_VERSION=$(grep -oP '"schema_version"\s*:\s*\K[0-9]+' "$ctx_file" 2>/dev/null || echo "1")

    if [[ "$_ORCH_SCHEMA_VERSION" -ge 2 ]]; then
        # v2: read primary_cause and secondary_cause objects
        # Use a simple line-by-line scan; avoid jq dependency in orchestration path
        local in_primary=0 in_secondary=0
        while IFS= read -r line; do
            [[ "$line" =~ '"primary_cause"'   ]] && in_primary=1   && in_secondary=0 && continue
            [[ "$line" =~ '"secondary_cause"' ]] && in_secondary=1 && in_primary=0   && continue
            if [[ "$in_primary" -eq 1 ]]; then
                [[ "$line" =~ '"category"'    ]] && _ORCH_PRIMARY_CAT=$(grep -oP '"category"\s*:\s*"\K[^"]+' <<< "$line")
                [[ "$line" =~ '"subcategory"' ]] && _ORCH_PRIMARY_SUB=$(grep -oP '"subcategory"\s*:\s*"\K[^"]+' <<< "$line")
                [[ "$line" =~ '"signal"'      ]] && _ORCH_PRIMARY_SIGNAL=$(grep -oP '"signal"\s*:\s*"\K[^"]+' <<< "$line")
                [[ "$line" =~ "}" ]] && in_primary=0
            fi
            if [[ "$in_secondary" -eq 1 ]]; then
                [[ "$line" =~ '"category"'    ]] && _ORCH_SECONDARY_CAT=$(grep -oP '"category"\s*:\s*"\K[^"]+' <<< "$line")
                [[ "$line" =~ '"subcategory"' ]] && _ORCH_SECONDARY_SUB=$(grep -oP '"subcategory"\s*:\s*"\K[^"]+' <<< "$line")
                [[ "$line" =~ '"signal"'      ]] && _ORCH_SECONDARY_SIGNAL=$(grep -oP '"signal"\s*:\s*"\K[^"]+' <<< "$line")
                [[ "$line" =~ "}" ]] && in_secondary=0
            fi
        done < "$ctx_file"
    else
        # v1 compat: treat top-level category/subcategory as secondary (symptom-level)
        _ORCH_SECONDARY_CAT=$(grep -oP '"category"\s*:\s*"\K[^"]+' "$ctx_file" 2>/dev/null || true)
        _ORCH_SECONDARY_SUB=$(grep -oP '"subcategory"\s*:\s*"\K[^"]+' "$ctx_file" 2>/dev/null || true)
    fi
}
```

**Caching note:** `_load_failure_cause_context` zeroes the six cause
vars at the top of every call, then re-reads the file. It is **not**
idempotent across attempts in the strict sense — it always reflects
the current on-disk state of `LAST_FAILURE_CONTEXT.json`. This is
intentional: the file may be rewritten between iterations by m129's
`write_last_failure_context`, and the router needs the latest cause
data each time `_classify_failure` runs. Do not add a "first call
wins" cache.

**Test-mode override:** Honor an `ORCH_CONTEXT_FILE_OVERRIDE` env var
so the test harness can point the loader at a fixture without
manipulating `$PROJECT_DIR`. The existing line:

```bash
local ctx_file="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"
```

becomes:

```bash
local ctx_file="${ORCH_CONTEXT_FILE_OVERRIDE:-${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json}"
```

This is the contract `tests/test_orchestrate_recovery.sh` (Goal 6)
relies on.

The cause-var reset is owned by the loader. The persistent retry
guards (`_ORCH_ENV_GATE_RETRIED`, `_ORCH_MIXED_BUILD_RETRIED`) are
managed separately — see Goal 5.

### Goal 2 — Upgrade `_classify_failure` with causal-context branches

The existing flat decision tree in `_classify_failure` is preserved
intact **except** for four targeted amendments. Apply them as guarded
early-return clauses inserted *before* the existing branches:

#### Amendment A — Environment/test_infra re-route

Insert immediately before the `if [[ "$error_cat" = "ENVIRONMENT" ]]`
branch:

```bash
# Amendment A (M130): primary cause env/test_infra is recoverable by
# re-running with deterministic gate profile (M126). Do NOT save_exit.
if [[ "$_ORCH_PRIMARY_CAT" = "ENVIRONMENT" ]] &&
   [[ "$_ORCH_PRIMARY_SUB" = "test_infra"  ]] &&
   [[ "${_ORCH_ENV_GATE_RETRIED:-0}" -ne 1 ]]; then
    _ORCH_ENV_GATE_RETRIED=1
    echo "retry_ui_gate_env"
    return
fi
```

`_ORCH_ENV_GATE_RETRIED` is a module-level flag initialized to `0` at
run start. It prevents infinite loops: the second failure with the same
primary cause falls through to the existing `ENVIRONMENT → save_exit`
branch as before.

#### Amendment B — max_turns with env primary cause

Insert immediately before the `AGENT_SCOPE/max_turns → split` branch:

```bash
# Amendment B (M130): if primary cause is ENVIRONMENT (not agent failure)
# and secondary is max_turns, do not split — split cannot fix an env issue.
# Retry with env gate fix (once) then save_exit.
if [[ "$error_cat"           = "AGENT_SCOPE"    ]] &&
   [[ "$error_sub"           = "max_turns"      ]] &&
   [[ "$_ORCH_PRIMARY_CAT"   = "ENVIRONMENT"    ]] &&
   [[ "${_ORCH_ENV_GATE_RETRIED:-0}" -ne 1      ]]; then
    _ORCH_ENV_GATE_RETRIED=1
    echo "retry_ui_gate_env"
    return
fi
```

If `_ORCH_ENV_GATE_RETRIED` is already set (the env retry itself hit
max_turns), fall through to the existing `split` branch — something
deeper is wrong and split is then appropriate.

#### Amendment C — Build-gate retry only when classification is code-dominant

Replace the current unconditional `BUILD_ERRORS_FILE` check:

```bash
# Original (before M130):
# if [[ -f "${BUILD_ERRORS_FILE}" ]] && [[ -s "${BUILD_ERRORS_FILE}" ]]; then
#     echo "retry_coder_build"
#     return
# fi

# M130: only retry if classification confidence is code_dominant or unset.
# mixed_uncertain or noncode_dominant → save_exit (retrying won't help).
# Kill-switch: BUILD_FIX_CLASSIFICATION_REQUIRED=false bypasses the gating
# entirely and falls back to pre-M130 behavior.
if [[ -f "${BUILD_ERRORS_FILE}" ]] && [[ -s "${BUILD_ERRORS_FILE}" ]]; then
    if [[ "${BUILD_FIX_CLASSIFICATION_REQUIRED:-true}" != "true" ]]; then
        # Pre-M130 behavior: always retry on non-empty BUILD_ERRORS_FILE
        echo "retry_coder_build"
        return
    fi
    local build_confidence="${LAST_BUILD_CLASSIFICATION:-code_dominant}"
    case "$build_confidence" in
        code_dominant|unknown_only|"")
            # unknown_only: m127 explicitly chose to treat this as
            # code_dominant in the consumer (m130's router) — see m127
            # "Seeds Forward" — so unclassified errors still get one
            # build-fix attempt.
            echo "retry_coder_build"
            return
            ;;
        mixed_uncertain)
            # Retry once; coder will see the mixed signal in the error content
            if [[ "${_ORCH_MIXED_BUILD_RETRIED:-0}" -ne 1 ]]; then
                _ORCH_MIXED_BUILD_RETRIED=1
                echo "retry_coder_build"
                return
            fi
            echo "save_exit"
            return
            ;;
        noncode_dominant)
            # Non-code dominant signal: code change won't fix this
            echo "save_exit"
            return
            ;;
    esac
fi
```

`LAST_BUILD_CLASSIFICATION` is exported by the m127 confidence-based
classifier. When absent (pre-m127 deployment) the default `code_dominant`
preserves current behavior.

`BUILD_FIX_CLASSIFICATION_REQUIRED` is declared in `config_defaults.sh`
by m136 (defaulted to `true`). When m130 lands before m136, the
`${BUILD_FIX_CLASSIFICATION_REQUIRED:-true}` default in this branch
makes the knob effective even without `config_defaults.sh` registration —
m136 only adds the explicit declaration and a `--validate-config` check.

#### Amendment D — Call `_load_failure_cause_context` at function start

Add as the very first line of `_classify_failure`:

```bash
_load_failure_cause_context  # M130: populate _ORCH_PRIMARY_*/SECONDARY_* vars
```

### Goal 3 — Add `retry_ui_gate_env` as an actionable recovery path

`_classify_failure` can now return a new action string
`retry_ui_gate_env`. The **caller** is the `case "$recovery"`
dispatcher in `lib/orchestrate_loop.sh:_handle_pipeline_failure`
(lines ~202–252). Add the new case branch immediately above the
existing `retry_coder_build)` branch so the env-aware path is checked
first:

```bash
retry_ui_gate_env)
    # M130: retry from coder stage with TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1
    # so m126's framework-detection Priority 0 forces the hardened env profile
    # on the next gate run. Idempotency is enforced by _classify_failure via
    # the _ORCH_ENV_GATE_RETRIED guard — second env-class failure falls through
    # to save_exit there, not here.
    export TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1
    _ORCH_RECOVERY_ROUTE_TAKEN="retry_ui_gate_env"   # m132 read site
    warn "Retrying from coder stage with non-interactive UI gate env (M130)."
    START_AT="coder"
    return 0
    ;;
```

This deliberately mirrors the existing `retry_coder_build` shape
already in `lib/orchestrate_loop.sh:215-226`:

```bash
# Existing pattern — kept here for reference, not modified by this milestone
retry_coder_build)
    if [[ "${_ORCH_BUILD_RETRIED:-false}" = true ]]; then
        warn "Build fix already retried. Saving state and exiting."
        _save_orchestration_state "build_exhausted" "Build failure persists after retry"
        return 11
    fi
    _ORCH_BUILD_RETRIED=true
    warn "Retrying from coder stage with build errors context."
    START_AT="coder"
    return 0
    ;;
```

The dispatcher's job is to set up the next iteration; the next
iteration's `_run_pipeline_stages` re-enters the coder stage and the
build gate, where m126's deterministic env normalizer picks up
`TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1` from the environment. **Do
not** call `run_ui_test_gate` (or any other gate function) inline
from the dispatcher — that bypasses the iteration's
`record_pipeline_attempt`, progress detection, agent-call accounting,
and TUI stage transitions, all of which assume one-stage-call-per-iteration.

**M126 contract requirement.** This branch is only useful if m126's
`_ui_detect_framework` (or the equivalent normalizer entry point)
treats `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1` as a Priority 0 rule
that forces the hardened env profile regardless of detected framework.
m126's "Seeds Forward" already lists this as a recommended hook. If
m126 ships without it, m130 must add the four-line check in
`lib/gates_ui.sh:_ui_detect_framework` before the dispatcher branch
is meaningful — see "Watch For".

**No `_retry_ui_gate_env` helper.** Earlier drafts added a separate
function that ran the gate inline with a halved timeout. That has
been removed: it duplicated stage-management logic already provided
by the next iteration, and it leaked tight-timeout side effects onto
the parent `UI_TEST_TIMEOUT`. The simpler "set env, re-loop" pattern
matches every other recovery action in the dispatcher.

### Goal 4 — Enrich `_print_recovery_block` with causal-context messaging

The function already receives `outcome` and `detail`. Extend it to
also accept an optional fifth argument `cause_summary` (plain-text
one-liner generated from primary/secondary cause vars):

```bash
_print_recovery_block() {
    local outcome="${1:-unknown}"
    local detail="${2:-}"
    local resume_cmd="${3:-}"
    local task="${4:-}"
    local cause_summary="${5:-}"   # NEW: M130 causal context line
    ...
```

Callers already pass 4 args; the fifth is optional and defaults to
empty, so existing call sites are unaffected.

When `cause_summary` is non-empty, insert it into the `WHAT HAPPENED`
block immediately after `what_happened`:

```bash
if [[ -n "$cause_summary" ]]; then
    echo "  Root cause: ${cause_summary}"
fi
```

Generate `cause_summary` at the call site. The only caller of
`_print_recovery_block` is
`lib/orchestrate_helpers.sh:_save_orchestration_state` (around line
231). Insert the assembly immediately before the existing
`_print_recovery_block` invocation:

```bash
# In lib/orchestrate_helpers.sh:_save_orchestration_state, just before
# _print_recovery_block "$outcome" "$detail" "$resume_cmd" "$task":

_load_failure_cause_context  # M130: refresh _ORCH_PRIMARY_*/SECONDARY_* from disk
local _cause_summary=""
if [[ -n "$_ORCH_PRIMARY_CAT" ]]; then
    _cause_summary="${_ORCH_PRIMARY_CAT}/${_ORCH_PRIMARY_SUB}"
    [[ -n "$_ORCH_PRIMARY_SIGNAL" ]] && _cause_summary+=" (${_ORCH_PRIMARY_SIGNAL})"
    if [[ -n "$_ORCH_SECONDARY_CAT" ]]; then
        _cause_summary+="; secondary: ${_ORCH_SECONDARY_CAT}/${_ORCH_SECONDARY_SUB}"
    fi
fi
_print_recovery_block "$outcome" "$detail" "$resume_cmd" "$task" "$_cause_summary"
```

`_save_orchestration_state` already sources `orchestrate_recovery.sh`
transitively (it lives in the same file family), so `_load_failure_cause_context`
is in scope without additional sourcing changes.

### Goal 5 — Module-level var declarations and reset semantics

There are **two** lifetimes for the new module-level state, and they
need different reset hooks.

**Lifetime A — refreshed every call to `_classify_failure`:**

| Var | Why per-call |
|-----|--------------|
| `_ORCH_PRIMARY_CAT`, `_ORCH_PRIMARY_SUB`, `_ORCH_PRIMARY_SIGNAL` | Re-read from disk; the file may be rewritten between iterations |
| `_ORCH_SECONDARY_CAT`, `_ORCH_SECONDARY_SUB`, `_ORCH_SECONDARY_SIGNAL` | Same |
| `_ORCH_SCHEMA_VERSION` | Same |

These are zeroed at the top of `_load_failure_cause_context` (already
specified in Goal 1) and immediately repopulated from the file. No
external reset hook is needed.

**Lifetime B — persistent across iterations within one `run_complete_loop` call:**

| Var | Why persistent |
|-----|---------------|
| `_ORCH_ENV_GATE_RETRIED` | Enforces the "retry env gate at most once per `--complete` invocation" semantic |
| `_ORCH_MIXED_BUILD_RETRIED` | Enforces the "retry mixed_uncertain build at most once" semantic |
| `_ORCH_RECOVERY_ROUTE_TAKEN` | Captures the last action chosen for m132's RUN_SUMMARY enrichment |

These mirror the existing `_ORCH_BUILD_RETRIED` / `_ORCH_REVIEW_BUMPED`
lifecycle: declare at module scope, reset **once** at the top of
`run_complete_loop` (around `lib/orchestrate.sh:94` where
`_ORCH_BUILD_RETRIED=false` is reset), and **never** reset
per-iteration. A per-iteration reset would always make the guard `0`
when `_classify_failure` checks it, breaking the retry-once semantic.

Declarations at the top of `lib/orchestrate_recovery.sh` (alongside
the existing `_ORCH_*` vars):

```bash
# M130: causal-context module state
_ORCH_PRIMARY_CAT=""
_ORCH_PRIMARY_SUB=""
_ORCH_PRIMARY_SIGNAL=""
_ORCH_SECONDARY_CAT=""
_ORCH_SECONDARY_SUB=""
_ORCH_SECONDARY_SIGNAL=""
_ORCH_SCHEMA_VERSION=0
_ORCH_ENV_GATE_RETRIED=0
_ORCH_MIXED_BUILD_RETRIED=0
_ORCH_RECOVERY_ROUTE_TAKEN=""
```

Add `_reset_orch_recovery_state` that zeroes only the persistent
(Lifetime B) guards (the cause vars are owned by
`_load_failure_cause_context` and zeroed there):

```bash
# Reset the persistent retry guards. Called once per --complete
# invocation, NOT per iteration. The cause vars are reset by
# _load_failure_cause_context on every call.
_reset_orch_recovery_state() {
    _ORCH_ENV_GATE_RETRIED=0
    _ORCH_MIXED_BUILD_RETRIED=0
    _ORCH_RECOVERY_ROUTE_TAKEN=""
}
```

**Insertion point for the reset call:** in `lib/orchestrate.sh`,
inside `run_complete_loop`, immediately after the existing
`_ORCH_BUILD_RETRIED=false` line (line ~94). The neighborhood is the
canonical place for one-time per-invocation initialization.

If m132 lands first (it also adds `_ORCH_RECOVERY_ROUTE_TAKEN` per
its Goal 8), m130 keeps the var declaration here as authoritative —
m132 documents that it consumes the value m130 owns. Pick whichever
milestone lands first to physically add the declaration; the other
verifies and proceeds.

### Goal 6 — Tests: fixture-backed routing decision coverage

Add `tests/test_orchestrate_recovery.sh` with the following test cases:

#### T1 — env/test_infra primary → retry_ui_gate_env

```bash
# Fixture: LAST_FAILURE_CONTEXT.json v2 with primary=ENVIRONMENT/test_infra
# Inputs:  AGENT_ERROR_CATEGORY=ENVIRONMENT AGENT_ERROR_SUBCATEGORY=test_infra
# Expect:  _classify_failure → "retry_ui_gate_env"
```

#### T2 — second env failure → save_exit (not infinite loop)

```bash
# Same fixture + _ORCH_ENV_GATE_RETRIED=1
# Expect:  _classify_failure → "save_exit"
```

#### T3 — max_turns with env primary → retry_ui_gate_env, not split

```bash
# Fixture: v2, primary=ENVIRONMENT/test_infra, secondary=AGENT_SCOPE/max_turns
# Inputs:  AGENT_ERROR_CATEGORY=AGENT_SCOPE AGENT_ERROR_SUBCATEGORY=max_turns
# Expect:  _classify_failure → "retry_ui_gate_env"
```

#### T4 — max_turns with env primary, already retried → split

```bash
# Same + _ORCH_ENV_GATE_RETRIED=1
# Expect:  _classify_failure → "split"
```

#### T5 — build gate code_dominant → retry_coder_build

```bash
# LAST_BUILD_CLASSIFICATION=code_dominant + BUILD_ERRORS_FILE non-empty
# Expect:  _classify_failure → "retry_coder_build"
```

#### T6 — build gate noncode_dominant → save_exit

```bash
# LAST_BUILD_CLASSIFICATION=noncode_dominant + BUILD_ERRORS_FILE non-empty
# Expect:  _classify_failure → "save_exit"
```

#### T7 — build gate mixed_uncertain, first attempt → retry_coder_build

```bash
# LAST_BUILD_CLASSIFICATION=mixed_uncertain, _ORCH_MIXED_BUILD_RETRIED=0
# Expect:  _classify_failure → "retry_coder_build"
```

#### T8 — build gate mixed_uncertain, already retried → save_exit

```bash
# LAST_BUILD_CLASSIFICATION=mixed_uncertain, _ORCH_MIXED_BUILD_RETRIED=1
# Expect:  _classify_failure → "save_exit"
```

#### T8b — build gate unknown_only → retry_coder_build (treated as code)

```bash
# LAST_BUILD_CLASSIFICATION=unknown_only, BUILD_ERRORS_FILE non-empty
# Expect:  _classify_failure → "retry_coder_build"
# Rationale: m127 spec says unknown_only is treated as code_dominant
# for routing — unclassified errors still get one build-fix attempt.
```

#### T8c — kill switch: BUILD_FIX_CLASSIFICATION_REQUIRED=false → always retry

```bash
# LAST_BUILD_CLASSIFICATION=noncode_dominant + BUILD_FIX_CLASSIFICATION_REQUIRED=false
# Expect:  _classify_failure → "retry_coder_build"
# Rationale: pre-m130 fallback path; the m136 knob can disable Amendment C entirely.
```

#### T9 — v1 schema compat: flat ENVIRONMENT still routes save_exit

```bash
# Fixture: v1 LAST_FAILURE_CONTEXT.json (no schema_version, no primary_cause)
# Inputs:  AGENT_ERROR_CATEGORY=ENVIRONMENT AGENT_ERROR_SUBCATEGORY=disk_full
# Expect:  _classify_failure → "save_exit"
```

#### T10 — no failure context file: original decision tree unchanged

```bash
# No LAST_FAILURE_CONTEXT.json present
# Inputs:  AGENT_ERROR_CATEGORY=UPSTREAM
# Expect:  _classify_failure → "save_exit"
```

#### T11 — cause_summary in recovery block

```bash
# Call _print_recovery_block with cause_summary="ENVIRONMENT/test_infra (ui_timeout_interactive_report)"
# Expect:  output contains "Root cause: ENVIRONMENT/test_infra"
```

## Files Modified

| File | Change |
|------|--------|
| `lib/orchestrate_recovery.sh` | Add `_load_failure_cause_context`, `_reset_orch_recovery_state`; module state vars (Lifetime A + Lifetime B from Goal 5); amendments A–D in `_classify_failure`; enriched `_print_recovery_block` signature (5th optional arg). **Currently 242 lines; estimated +110-130 LOC will exceed the 300-line ceiling (CLAUDE.md non-negotiable rule 8).** Plan from the start to extract the new symbols (`_load_failure_cause_context`, `_reset_orch_recovery_state`, the four amendment helpers if any factor out cleanly, the module state vars block) into a new `lib/orchestrate_recovery_causal.sh` and source it from `orchestrate_recovery.sh`. Mirrors the established `_helpers.sh` / domain-split pattern used by `gates_ui` / `error_patterns` after their respective resilience-arc milestones. |
| `lib/orchestrate_loop.sh` | Add `retry_ui_gate_env` case branch in `_handle_pipeline_failure` immediately above the existing `retry_coder_build)` branch (lines ~215–226). Currently 253 lines; addition is ~12 LOC — comfortably under 300. |
| `lib/orchestrate.sh` | Call `_reset_orch_recovery_state` once at the top of `run_complete_loop`, immediately after the existing `_ORCH_BUILD_RETRIED=false` line (line ~94). Do **not** insert per-iteration. |
| `lib/orchestrate_helpers.sh` | In `_save_orchestration_state` (line ~231), assemble `_cause_summary` from loader output and pass as the new fifth argument to `_print_recovery_block`. |
| `tests/test_orchestrate_recovery.sh` | **New file.** Fixture-backed tests T1–T11 plus T8b/T8c covering all new routing branches. Tests use `ORCH_CONTEXT_FILE_OVERRIDE` to point the loader at fixture JSON. |
| `tests/run_tests.sh` | Register `test_orchestrate_recovery.sh` in the active test list (mirrors how other resilience-arc tests are added). |
| `docs/troubleshooting/recovery-routing.md` | **New file.** Document the causal-context routing table (primary cause → action mapping), the retry-once guards, and the `BUILD_FIX_CLASSIFICATION_REQUIRED` kill switch. |

## Implementation Notes

### Parser safety for LAST_FAILURE_CONTEXT.json

`_load_failure_cause_context` uses line-by-line `grep -oP` instead of
`jq` so orchestration code never takes on a runtime dependency on a
JSON tool that may not be available in target environments. The tradeoff
is the parser is sensitive to JSON pretty-print formatting. Mitigation:

- `write_last_failure_context` (m129) must guarantee one-key-per-line
  output for all primary/secondary cause fields (not minified). m129
  enshrines this in its "Pretty-print contract — NON-NEGOTIABLE"
  section, with `writes_pretty_printed_one_key_per_line` as the canary
  test.
- `_load_failure_cause_context` honors `ORCH_CONTEXT_FILE_OVERRIDE` (see
  Goal 1) so tests can point the loader at fixture JSON without
  manipulating `$PROJECT_DIR`.

### Loop safety for `retry_ui_gate_env`

The `_ORCH_ENV_GATE_RETRIED` guard is a module-level var, reset once
at the start of `run_complete_loop` (not per iteration — see Goal 5
for the why). This means:

- Within a single `--complete` invocation: at most one env-gate retry.
- On a fresh `--complete` resume (new shell, new `run_complete_loop`
  call): the guard starts at 0 again, so the retry is re-allowed.
  This is intentional — the prior run's env state is unknown; allowing
  one more retry costs one gate run and is better than permanently
  refusing it.

If permanent suppression is needed (user manually confirmed the gate is
not an interactive-report issue), the user can set
`TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0` in `pipeline.conf` to
short-circuit m126's normalizer, which prevents m130's env-gate retry
from ever doing anything useful and causes it to fall through to
`save_exit` on the second failure as normal. Alternatively
`BUILD_FIX_CLASSIFICATION_REQUIRED=false` (see Amendment C) reverts
the build-side gating to pre-M130 behavior.

### `LAST_BUILD_CLASSIFICATION` export contract

`LAST_BUILD_CLASSIFICATION` is exported by the m127 classification
engine after each build-gate run. Its values are:

- `code_dominant` — majority of log lines matched known code-error patterns
- `noncode_dominant` — majority of log lines matched non-code patterns
- `mixed_uncertain` — neither category dominates
- `unknown_only` — no patterns matched at all (treated as `code_dominant`
  for routing purposes — unclassified errors should still be attempted)

When m127 is not yet deployed, this var will be absent; the
`${LAST_BUILD_CLASSIFICATION:-code_dominant}` default preserves the
pre-m127 retry behavior so m130 can be deployed independently.

## Acceptance Criteria

- [ ] `_load_failure_cause_context` correctly populates `_ORCH_PRIMARY_*` and `_ORCH_SECONDARY_*` from v2 schema JSON.
- [ ] `_load_failure_cause_context` degrades safely with v1 schema (no crash, secondary vars populated from top-level fields).
- [ ] `_load_failure_cause_context` is a no-op (all vars empty) when `LAST_FAILURE_CONTEXT.json` is absent.
- [ ] `_classify_failure` returns `retry_ui_gate_env` when primary cause is `ENVIRONMENT/test_infra` and env gate has not yet been retried.
- [ ] `_classify_failure` returns `save_exit` (not `retry_ui_gate_env`) on second environment failure.
- [ ] `_classify_failure` returns `retry_ui_gate_env` (not `split`) when `AGENT_SCOPE/max_turns` and primary cause is `ENVIRONMENT/test_infra`.
- [ ] `_classify_failure` returns `retry_coder_build` for `code_dominant`, `unknown_only`, or `mixed_uncertain` (first time) classifications.
- [ ] `_classify_failure` returns `save_exit` for `noncode_dominant` build errors.
- [ ] `BUILD_FIX_CLASSIFICATION_REQUIRED=false` reverts Amendment C to pre-M130 behavior (always `retry_coder_build` on non-empty `BUILD_ERRORS_FILE`).
- [ ] `_print_recovery_block` prints "Root cause: ..." when fifth arg is non-empty.
- [ ] All test cases in `test_orchestrate_recovery.sh` pass (T1–T11 plus T8b unknown_only and T8c kill-switch).
- [ ] `tests/run_tests.sh` registers `test_orchestrate_recovery.sh`.
- [ ] No regression on pre-existing routing cases (T9 and T10 specifically confirm v1 and absent-context paths).
- [ ] `_reset_orch_recovery_state` is called exactly once per `run_complete_loop` invocation (at the top), not per iteration. Verified by inspection at `lib/orchestrate.sh:~94`.
- [ ] `lib/orchestrate_recovery.sh` ends ≤ 300 lines after the changes (CLAUDE.md non-negotiable rule 8). If the file would exceed 300, the extraction described in "Files Modified" has been performed and `lib/orchestrate_recovery_causal.sh` is in place and sourced.
- [ ] `shellcheck` clean for every modified shell file (`lib/orchestrate_recovery.sh`, `lib/orchestrate_recovery_causal.sh` if extracted, `lib/orchestrate_loop.sh`, `lib/orchestrate.sh`, `lib/orchestrate_helpers.sh`).

## Watch For

- **Recovery dispatcher lives in `orchestrate_loop.sh`, not
  `orchestrate.sh`.** The `case "$recovery"` block this milestone
  extends is in `_handle_pipeline_failure`
  (`lib/orchestrate_loop.sh:202-252`). `run_complete_loop`
  (`orchestrate.sh:79-264`) only delegates to it. Putting the new
  case in the wrong file looks correct in isolation but never fires.
- **`_reset_orch_recovery_state` is per-invocation, not per-iteration.**
  The retry-once guards (`_ORCH_ENV_GATE_RETRIED`,
  `_ORCH_MIXED_BUILD_RETRIED`) need to persist across iterations so
  `_classify_failure` can see the prior attempt happened. Resetting
  per-iteration always makes them `0` and breaks the retry-once
  semantic. This mirrors how `_ORCH_BUILD_RETRIED` is handled today
  (`lib/orchestrate.sh:94`). The cause vars are owned by
  `_load_failure_cause_context` and refreshed every call there —
  don't reset those externally either.
- **Pretty-print contract is load-bearing.** `_load_failure_cause_context`
  parses `LAST_FAILURE_CONTEXT.json` with `grep -oP` line scans, not
  `jq`. m129's `writes_pretty_printed_one_key_per_line` test is the
  canary; if the writer ever emits minified or single-line nested
  objects, m130 silently mis-classifies every routing decision. Do
  not add `jq` as a runtime dependency to bypass this — orchestration
  code paths must work in environments without `jq`.
- **`grep -oP` requires GNU grep with PCRE.** macOS default `grep`
  does not support `-P`. The whole resilience arc (m126/m127/m129/m130/m132/m133)
  assumes GNU grep is present. If a CI lane targets BSD grep, that's
  out of scope for this milestone, but the failure mode is silent
  empty matches — not loud errors — so flag it during review of any
  arc-related test failures.
- **`retry_ui_gate_env` requires the m126 Priority 0 hook.** The new
  dispatcher branch exports `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1`
  and re-loops. m126's `_ui_detect_framework` must treat that env var
  as the highest-priority "force hardened env" rule (m126 "Seeds
  Forward" lists this as recommended; if not yet implemented, m130
  must add the four-line check in `lib/gates_ui.sh:_ui_detect_framework`
  before merging). Without that hook, the env retry exports the var
  but the gate ignores it — the second iteration then fails the same
  way and the `_ORCH_ENV_GATE_RETRIED` guard correctly routes to
  `save_exit`, but the recovery never had a chance to work.
- **`LAST_BUILD_CLASSIFICATION` may not be exported pre-m127.** The
  Amendment C default (`${LAST_BUILD_CLASSIFICATION:-code_dominant}`)
  preserves pre-m127 behavior, so m130 can be deployed before m127
  lands. But if m127 ships in the same release, verify the
  classifier exports the var on **every** classify path — m127's
  "Watch For" already calls this out. The default makes silent
  omissions invisible rather than loud errors.
- **300-line ceiling on `lib/orchestrate_recovery.sh`.** Currently
  242 lines; the additions are ~110-130 LOC. The extraction to
  `lib/orchestrate_recovery_causal.sh` listed in "Files Modified" is
  mandatory, not optional, just to land cleanly under CLAUDE.md
  non-negotiable rule 8. Run `wc -l lib/orchestrate_recovery*.sh`
  before committing.
- **Don't conflate cause vars with retry guards.** `_ORCH_PRIMARY_*`
  and `_ORCH_SECONDARY_*` are *snapshots of disk state* — read by
  `_load_failure_cause_context` from the JSON file. The retry guards
  (`_ORCH_ENV_GATE_RETRIED` etc.) are *router state* — written by
  `_classify_failure` itself. Conflating their lifetimes (e.g. a
  single reset that touches both) introduces hard-to-trace
  cross-attempt bugs. m134's S4.x integration scenarios will catch
  this, but failing locally first is cheaper.
- **`unknown_only` is a `code_dominant` synonym in the router.** m127
  exports `unknown_only` for "no patterns matched at all"; the m127
  spec explicitly says the consumer (m130) decides how to treat it.
  Amendment C collapses it to `code_dominant` so unclassified errors
  still get one build-fix attempt. Don't remove `unknown_only` from
  the case branch — pre-m127 callers won't emit it, but post-m127
  callers will.
- **`_print_recovery_block` 5th arg is optional and additive.** The
  signature change must keep all four existing positional args
  unchanged. Existing callers pass exactly four args; the fifth
  defaults to empty and the "Root cause:" line is suppressed when
  empty. Don't reorder args, and don't make the fifth required —
  that would break every other call site in the file family.

## Seeds Forward

This milestone closes the inner loop of the resilience arc — the
router that consumes m129's schema and produces actions consumed by
m132/m133/m134. Downstream milestones depend on the contracts pinned
here:

- **m132 — RUN_SUMMARY Causal Fidelity Enrichment.** Hard contract:
  `_collect_recovery_routing_json` reads `_ORCH_RECOVERY_ROUTE_TAKEN`,
  `_ORCH_ENV_GATE_RETRIED`, `_ORCH_MIXED_BUILD_RETRIED`, and
  `_ORCH_SCHEMA_VERSION` directly. Do not rename these vars after this
  milestone lands. m132's Goal 8 also adds `_ORCH_RECOVERY_ROUTE_TAKEN`
  declarations — whichever milestone lands first owns the canonical
  declaration; the other verifies and proceeds. → Keep var names
  stable; they are the public interface to the finalize layer.

- **m133 — Diagnose Rule Enrichment.** `_rule_max_turns_env_root`
  (m133's renamed `_rule_max_turns` extension) reads the same
  `LAST_FAILURE_CONTEXT.json` via the m129 schema, then cross-checks
  `RUN_SUMMARY.json` `recovery_routing.route_taken == "retry_ui_gate_env"`
  for confidence boosting. The exact string `retry_ui_gate_env` must
  not change — m133 will grep for it byte-for-byte. → Keep action
  string vocabulary frozen.

- **m134 — Resilience Arc Integration Test Suite.** Scenario group 4
  (S4.x — "Failure context write → recovery routing") exercises
  `_load_failure_cause_context` directly, then drives `_classify_failure`
  through every Amendment A–C path. The test fixture JSON is the same
  byte-for-byte shape m129's `test_failure_context_schema.sh` writes;
  m134 hard-codes it. → Don't change the parser line-state-machine
  (in/out brace tracking) without coordinating fixture updates with
  m134.

- **m135 — Resilience Arc Artifact Lifecycle.** m130 itself produces
  no new artifacts (it consumes `LAST_FAILURE_CONTEXT.json`, doesn't
  write it), so m135 does not need to add cleanup hooks for this
  milestone. But m135 does cover `LAST_FAILURE_CONTEXT.json`
  cleanup-on-success — which removes the file m130's loader reads.
  m130's "absent file → empty cause vars → unchanged routing"
  fallback (Acceptance Criterion 3) is exactly what makes m135's
  cleanup safe. → Keep the absent-file degrade path working; m135
  relies on it.

- **m136 — Resilience Arc Config Defaults & Validation.** Declares
  `BUILD_FIX_CLASSIFICATION_REQUIRED:=true` in `config_defaults.sh`
  and adds a `--validate-config` check for it. m130 reads the var
  with a `:-true` default in Amendment C, so m136 is purely additive
  — it formalizes the declaration and adds validation, but m130 works
  without it. → Don't add the declaration to `config_defaults.sh`
  yourself in m130; leave that to m136 to keep the layering clean.

- **Watchtower run-detail badges.** m132 introduces
  `[env-gate-retry]` and `[preflight-patch]` badges driven off
  `recovery_routing.route_taken == "retry_ui_gate_env"`. The badge
  string is m132's call, but the underlying token is m130's. → If a
  future redesign collapses or renames `retry_ui_gate_env`, update
  m132 in the same change.

- **Future: env-class taxonomy beyond `test_infra`.** Amendment A
  fires only on `ENVIRONMENT/test_infra`. Other env subcategories
  (`disk_full`, `network_outage`, `cred_missing`) still route
  `save_exit` as before. If future work adds recoverable env classes
  (e.g. transient network → wait + retry), it can layer in additional
  amendments at the same insertion point without re-architecting the
  router. The `_ORCH_PRIMARY_SUB` discrimination is the natural
  hook. → Pattern is established; keep new env-class amendments as
  guarded early-returns rather than rebuilding the decision tree.
