#!/usr/bin/env bash
# scripts/orchestrate-parity-check.sh — m12 parity gate for the bash↔Go
# orchestrate seam.
#
# The Go classifier (`tekhton orchestrate classify`) and the bash classifier
# (`_classify_failure` in lib/orchestrate_classify.sh) must produce identical
# recovery actions for the same stage outcome. This script drives both with a
# 10-scenario matrix and fails CI if any scenario disagrees.
#
# Each scenario is a tuple: NAME | OUTCOME_JSON | GUARDS | EXPECTED_ACTION.
# The bash side is exercised by sourcing the recovery dispatch and setting
# the same globals the production loop sets after _run_pipeline_stages.
#
# The 10 scenarios below cover the matrix the m12 design names: happy path,
# transient retry, quota pause, fatal error, activity timeout, recovery-
# classified failure, milestone advance, resume from interrupted state,
# multi-attempt converge, plus the M130 amendment B branch. Three of those
# (quota pause, milestone advance, resume) intentionally short-circuit to
# `save_exit` because the bash front-end owns the side effects (state save,
# milestone DAG advance) — the parity check still asserts the recovery class.
#
# Usage:
#   scripts/orchestrate-parity-check.sh
#
# Exit codes:
#   0 = all scenarios match
#   1 = one or more scenarios disagreed (per-scenario report printed)
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$REPO_ROOT"

# --- Locate the tekhton binary ------------------------------------------------
BIN="${TEKHTON_BIN:-}"
if [[ -z "$BIN" ]]; then
    if command -v tekhton >/dev/null 2>&1; then
        BIN=$(command -v tekhton)
    elif [[ -x "${REPO_ROOT}/bin/tekhton" ]]; then
        BIN="${REPO_ROOT}/bin/tekhton"
    else
        echo "orchestrate-parity-check: tekhton binary not on PATH and not at ./bin/tekhton" >&2
        echo "Run: make build" >&2
        exit 2
    fi
fi
if [[ ! -x "$BIN" ]]; then
    echo "orchestrate-parity-check: $BIN not executable" >&2
    exit 2
fi

# --- Source the bash classifier -----------------------------------------------
# The bash dispatcher reads AGENT_ERROR_*, VERDICT, _ORCH_PRIMARY_*,
# _ORCH_SECONDARY_*, and _ORCH_*_RETRIED globals. We stub log/warn/error and
# set the globals per scenario.
# shellcheck disable=SC2317  # stubs are invoked by sourced production code
log()                          { :; }
# shellcheck disable=SC2317
warn()                         { :; }
# shellcheck disable=SC2317
error()                        { :; }
# shellcheck disable=SC2317
success()                      { :; }
# shellcheck disable=SC2317
header()                       { :; }
# shellcheck disable=SC2317
log_verbose()                  { :; }
# shellcheck disable=SC2317
emit_event()                   { :; }
# shellcheck disable=SC2317
_load_failure_cause_context()  { :; }
# shellcheck disable=SC2317
_causal_env_retry_allowed()    { return 0; }
# shellcheck disable=SC2317
format_failure_cause_summary() { :; }
# shellcheck disable=SC2317
reset_failure_cause_context()  { :; }
# shellcheck disable=SC2317
_print_recovery_block()        { :; }

# Set the env so that classifier sees expected defaults. The classifier reads
# these via parameter expansion in the sourced file — shellcheck can't track
# the cross-file usage.
# shellcheck disable=SC2034
BUILD_FIX_CLASSIFICATION_REQUIRED=true
# shellcheck disable=SC2034
UI_GATE_ENV_RETRY_ENABLED=true

# Source recovery dispatch directly. The dispatch script also tries to source
# orchestrate_cause.sh and orchestrate_diagnose.sh.
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/orchestrate_classify.sh"

# Re-stub AFTER sourcing — the causal helper file redefines
# _load_failure_cause_context and would otherwise clobber the per-scenario
# globals we set below. Same for _causal_env_retry_allowed.
_load_failure_cause_context() { :; }
_causal_env_retry_allowed()    { return 0; }

# --- Scenario harness ---------------------------------------------------------
PASS=0
FAIL=0
FAILURES=""

run_scenario() {
    local name="$1" outcome_json="$2" guards="$3" want="$4"

    # Derive bash globals from outcome_json + guards. Each is consumed by the
    # sourced classifier; shellcheck can't see the cross-file read.
    # shellcheck disable=SC2034
    AGENT_ERROR_CATEGORY=$(_jq_field "$outcome_json" error_category)
    # shellcheck disable=SC2034
    AGENT_ERROR_SUBCATEGORY=$(_jq_field "$outcome_json" error_subcategory)
    # shellcheck disable=SC2034
    VERDICT=$(_jq_field "$outcome_json" verdict)
    # shellcheck disable=SC2034
    _ORCH_PRIMARY_CAT=$(_jq_field "$outcome_json" primary_cat)
    # shellcheck disable=SC2034
    _ORCH_PRIMARY_SUB=$(_jq_field "$outcome_json" primary_sub)
    # shellcheck disable=SC2034
    LAST_BUILD_CLASSIFICATION=$(_jq_field "$outcome_json" build_classification)
    local _build_present
    _build_present=$(_jq_field "$outcome_json" build_errors_present)

    # Reset persistent guards from prior scenario.
    _ORCH_ENV_GATE_RETRIED=0
    _ORCH_MIXED_BUILD_RETRIED=0
    case "$guards" in
        env_gate_retried)    _ORCH_ENV_GATE_RETRIED=1 ;;
        mixed_build_retried) _ORCH_MIXED_BUILD_RETRIED=1 ;;
    esac

    # Bash side: set BUILD_ERRORS_FILE existence based on the outcome flag.
    BUILD_ERRORS_FILE=$(mktemp)
    if [[ "$_build_present" = "true" ]]; then
        printf 'simulated build error\n' > "$BUILD_ERRORS_FILE"
    fi

    local bash_out
    bash_out=$(_classify_failure)
    rm -f "$BUILD_ERRORS_FILE"

    # Go side: shell to the binary's classify subcommand.
    local go_args=(orchestrate classify)
    case "$guards" in
        env_gate_retried)    go_args+=(--env-gate-retried) ;;
        mixed_build_retried) go_args+=(--mixed-build-retried) ;;
    esac
    local go_out
    go_out=$("$BIN" "${go_args[@]}" <<<"$outcome_json" | tail -n1 | tr -d '\n\r ')

    if [[ "$bash_out" = "$go_out" ]] && [[ "$bash_out" = "$want" ]]; then
        PASS=$(( PASS + 1 ))
        printf '  PASS: %s → %s\n' "$name" "$want"
    else
        FAIL=$(( FAIL + 1 ))
        local msg="  FAIL: ${name} — bash='${bash_out}' go='${go_out}' want='${want}'"
        printf '%s\n' "$msg"
        FAILURES+="${msg}"$'\n'
    fi
}

# Tiny pure-bash JSON field extractor (top-level scalars only).
# The agent_shim _shim_field is not callable here; this scope reuses the same
# shape but is intentionally simpler — scenarios use single-line JSON.
_jq_field() {
    local s="$1" k="$2"
    # Match "key":"value" first.
    local v
    v=$(printf '%s' "$s" | sed -nE "s/.*\"${k}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/p" | head -n1)
    if [[ -n "$v" ]]; then printf '%s' "$v"; return; fi
    # Then "key":bool/number.
    v=$(printf '%s' "$s" | sed -nE "s/.*\"${k}\"[[:space:]]*:[[:space:]]*([a-zA-Z0-9_-]+).*/\\1/p" | head -n1)
    printf '%s' "$v"
}

# --- The 10-scenario matrix ---------------------------------------------------

# 1. Happy path — no error, no verdict, no build errors → save_exit.
#    (The bash loop's success path doesn't reach _classify_failure; the
#    parity assertion here is "neither side recovers a misclassified
#    success as anything else.")
run_scenario "happy_path_unrecoverable_when_classified" \
    '{"build_errors_present":false}' \
    "" "save_exit"

# 2. Transient retry — code-dominant build errors → retry_coder_build.
run_scenario "transient_retry_code_dominant_build" \
    '{"build_errors_present":true,"build_classification":"code_dominant"}' \
    "" "retry_coder_build"

# 3. Quota pause — UPSTREAM after retry envelope exhaust → save_exit.
#    (The retry envelope itself runs inside the supervisor — quota pauses
#    don't surface to the orchestrator unless they outlast the supervisor's
#    retry budget. By that point the only recovery is save_exit.)
run_scenario "quota_pause_after_retry_exhaust" \
    '{"error_category":"UPSTREAM","error_subcategory":"api_rate_limit"}' \
    "" "save_exit"

# 4. Fatal error — PIPELINE internal → save_exit.
run_scenario "fatal_error_pipeline_internal" \
    '{"error_category":"PIPELINE","error_subcategory":"internal"}' \
    "" "save_exit"

# 5. Activity timeout — AGENT_SCOPE/activity_timeout → save_exit.
run_scenario "activity_timeout_save_exit" \
    '{"error_category":"AGENT_SCOPE","error_subcategory":"activity_timeout"}' \
    "" "save_exit"

# 6. Recovery-classified failure — AGENT_SCOPE/null_run → split.
run_scenario "recovery_classified_null_run_split" \
    '{"error_category":"AGENT_SCOPE","error_subcategory":"null_run"}' \
    "" "split"

# 7. Milestone advance — successful CHANGES_REQUIRED → bump_review.
#    (The bash front-end runs the actual auto-advance after RunAttempt
#    returns success. CHANGES_REQUIRED at the loop boundary triggers a
#    review-cycle bump retry first.)
run_scenario "milestone_changes_required_bump_review" \
    '{"verdict":"CHANGES_REQUIRED"}' \
    "" "bump_review"

# 8. Resume from interrupted state — REPLAN_REQUIRED → save_exit.
#    (Resume is signaled by the bash front-end reading PIPELINE_STATE; the
#    orchestrator never iterates past REPLAN_REQUIRED — wrong scope.)
run_scenario "resume_replan_required_save_exit" \
    '{"verdict":"REPLAN_REQUIRED"}' \
    "" "save_exit"

# 9. Multi-attempt converge — mixed-build first attempt → retry_coder_build.
run_scenario "multi_attempt_mixed_build_first" \
    '{"build_errors_present":true,"build_classification":"mixed_uncertain"}' \
    "" "retry_coder_build"

# 10. M130 amend B — max_turns + env primary → retry_ui_gate_env.
run_scenario "m130_amend_b_max_turns_env_primary" \
    '{"error_category":"AGENT_SCOPE","error_subcategory":"max_turns","primary_cat":"ENVIRONMENT","primary_sub":"test_infra"}' \
    "" "retry_ui_gate_env"

# --- Report -------------------------------------------------------------------
printf '\norchestrate-parity-check: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    printf '\nFailures:\n%s' "$FAILURES" >&2
    exit 1
fi
exit 0
