#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# validate_config.sh — Config health check (Milestone 83)
#
# Sourced by tekhton.sh — do not run directly.
# Depends on: common.sh (_is_utf8_terminal, log, warn, error)
#             milestone_dag.sh (has_milestone_manifest, load_manifest, validate_manifest)
#             config_defaults.sh (all config variables loaded)
# Provides: validate_config(), validate_config_summary()
# =============================================================================

# --- Symbol selection (respects NO_COLOR and terminal capabilities) ----------

_vc_sym_pass=""
_vc_sym_warn=""
_vc_sym_fail=""

_vc_init_symbols() {
    if [[ "${NO_COLOR:-}" == "1" ]]; then
        _vc_sym_pass="+"; _vc_sym_warn="!"; _vc_sym_fail="x"
    elif _is_utf8_terminal; then
        _vc_sym_pass="✓"; _vc_sym_warn="⚠"; _vc_sym_fail="✗"
    else
        _vc_sym_pass="+"; _vc_sym_warn="!"; _vc_sym_fail="x"
    fi
}

# --- Individual check helpers ------------------------------------------------

_vc_pass() { echo "  ${GREEN}${_vc_sym_pass}${NC} $*"; }
_vc_warn() { echo "  ${YELLOW}${_vc_sym_warn}${NC} $*"; }
_vc_fail() { echo "  ${RED}${_vc_sym_fail}${NC} $*"; }

# --- Placeholder / no-op pattern matching ------------------------------------

_vc_is_placeholder() {
    local val="$1"
    [[ -z "$val" ]] && return 0
    echo "$val" | grep -qiE '^\(fill in|^TODO|^CHANGEME|^FIXME' && return 0
    return 1
}

_vc_is_noop_cmd() {
    local val="$1"
    [[ -z "$val" ]] && return 0
    echo "$val" | grep -qE '^(echo |true$|:( .*)?$|exit 0$)' && return 0
    return 1
}

_vc_is_valid_model() {
    local val="$1"
    echo "$val" | grep -qE '^claude-(opus|sonnet|haiku)-' && return 0
    return 1
}

# --- Main validation function ------------------------------------------------

# validate_config — Runs all config health checks and prints structured output.
# Returns 0 on all-pass or warnings-only, 1 on errors.
validate_config() {
    _vc_init_symbols

    local passes=0 warnings=0 errors=0

    echo "Config validation: ${PROJECT_NAME:-unknown}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check 1: PROJECT_NAME present and non-empty
    if [[ -n "${PROJECT_NAME:-}" ]]; then
        _vc_pass "PROJECT_NAME set (${PROJECT_NAME})"
        passes=$((passes + 1))
    else
        _vc_fail "PROJECT_NAME is empty — set in pipeline.conf"
        errors=$((errors + 1))
    fi

    # Check 2: PROJECT_DESCRIPTION not placeholder
    if _vc_is_placeholder "${PROJECT_DESCRIPTION:-}"; then
        _vc_warn "PROJECT_DESCRIPTION is placeholder — edit pipeline.conf"
        warnings=$((warnings + 1))
    else
        _vc_pass "PROJECT_DESCRIPTION set"
        passes=$((passes + 1))
    fi

    # Check 3: TEST_CMD not a no-op
    if _vc_is_noop_cmd "${TEST_CMD:-}"; then
        _vc_warn "TEST_CMD is no-op or empty — set a real test command"
        warnings=$((warnings + 1))
    else
        _vc_pass "TEST_CMD configured (${TEST_CMD})"
        passes=$((passes + 1))
    fi

    # Check 4: ANALYZE_CMD not a no-op
    if _vc_is_noop_cmd "${ANALYZE_CMD:-}"; then
        _vc_warn "ANALYZE_CMD is no-op or empty — set a real analyze command"
        warnings=$((warnings + 1))
    else
        _vc_pass "ANALYZE_CMD configured (${ANALYZE_CMD})"
        passes=$((passes + 1))
    fi

    # Check 5: ARCHITECTURE_FILE exists on disk (if set)
    if [[ -n "${ARCHITECTURE_FILE:-}" ]]; then
        if [[ -f "${PROJECT_DIR}/${ARCHITECTURE_FILE}" ]]; then
            _vc_pass "ARCHITECTURE_FILE exists (${ARCHITECTURE_FILE})"
            passes=$((passes + 1))
        else
            _vc_warn "ARCHITECTURE_FILE=\"${ARCHITECTURE_FILE}\" — file not found on disk"
            warnings=$((warnings + 1))
        fi
    else
        _vc_pass "ARCHITECTURE_FILE not set (optional)"
        passes=$((passes + 1))
    fi

    # Check 6: DESIGN_FILE exists on disk (if set)
    if [[ -n "${DESIGN_FILE:-}" ]]; then
        if [[ -f "${PROJECT_DIR}/${DESIGN_FILE}" ]]; then
            _vc_pass "DESIGN_FILE exists (${DESIGN_FILE})"
            passes=$((passes + 1))
        else
            _vc_warn "DESIGN_FILE=\"${DESIGN_FILE}\" — file not found on disk"
            warnings=$((warnings + 1))
        fi
    else
        _vc_pass "DESIGN_FILE not set (optional)"
        passes=$((passes + 1))
    fi

    # Check 7: Agent role files exist
    _vc_check_role_files

    # Check 8: Milestone manifest valid (if exists)
    _vc_check_manifest

    # Check 9: Model names recognized
    _vc_check_models

    # Check 10: TEKHTON_CONFIG_VERSION present
    if [[ -n "${TEKHTON_CONFIG_VERSION:-}" ]]; then
        _vc_pass "TEKHTON_CONFIG_VERSION set (${TEKHTON_CONFIG_VERSION})"
        passes=$((passes + 1))
    else
        _vc_warn "TEKHTON_CONFIG_VERSION absent — run tekhton --migrate --status"
        warnings=$((warnings + 1))
    fi

    # Check 11: No stale PIPELINE_STATE.md
    if [[ -f "${PIPELINE_STATE_FILE:-}" ]]; then
        _vc_warn "PIPELINE_STATE.md exists — a previous run may need resuming"
        warnings=$((warnings + 1))
    else
        _vc_pass "No stale pipeline state"
        passes=$((passes + 1))
    fi

    echo ""
    echo "${passes} passed, ${warnings} warnings, ${errors} errors"

    # Store totals for summary access
    _VC_PASSES=$passes
    _VC_WARNINGS=$warnings
    _VC_ERRORS=$errors

    [[ "$errors" -eq 0 ]]
}

# _vc_check_role_files — Checks that agent role files exist.
_vc_check_role_files() {
    local found=0 total=0
    local role_var role_path
    for role_var in CODER_ROLE_FILE REVIEWER_ROLE_FILE TESTER_ROLE_FILE JR_CODER_ROLE_FILE; do
        total=$((total + 1))
        role_path="${!role_var:-}"
        [[ -z "$role_path" ]] && continue
        [[ "$role_path" != /* ]] && role_path="${PROJECT_DIR}/${role_path}"
        [[ -f "$role_path" ]] && found=$((found + 1))
    done

    if [[ "$found" -eq "$total" ]]; then
        _vc_pass "Agent role files present (${found}/${total})"
        passes=$((passes + 1))
    else
        _vc_fail "Agent role files missing (${found}/${total} found)"
        errors=$((errors + 1))
    fi
}

# _vc_check_manifest — Validates milestone manifest if present.
_vc_check_manifest() {
    if ! has_milestone_manifest 2>/dev/null; then
        _vc_pass "No milestone manifest (optional)"
        passes=$((passes + 1))
        return
    fi

    if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
        load_manifest 2>/dev/null || true
    fi

    if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
        _vc_fail "Milestone manifest exists but failed to load"
        errors=$((errors + 1))
        return
    fi

    local m_total="${#_DAG_IDS[@]}"
    if validate_manifest 2>/dev/null; then
        _vc_pass "Milestone manifest valid (${m_total} milestones, 0 errors)"
        passes=$((passes + 1))
    else
        _vc_fail "Milestone manifest has validation errors"
        errors=$((errors + 1))
    fi
}

# _vc_check_models — Validates that model names follow recognized patterns.
_vc_check_models() {
    local all_valid=true
    local checked_count=0
    local model_var model_val
    for model_var in CLAUDE_STANDARD_MODEL CLAUDE_CODER_MODEL \
                     CLAUDE_JR_CODER_MODEL CLAUDE_REVIEWER_MODEL \
                     CLAUDE_TESTER_MODEL CLAUDE_SCOUT_MODEL; do
        model_val="${!model_var:-}"
        [[ -z "$model_val" ]] && continue
        checked_count=$((checked_count + 1))
        if ! _vc_is_valid_model "$model_val"; then
            _vc_warn "${model_var}=\"${model_val}\" — unrecognized model name"
            warnings=$((warnings + 1))
            all_valid=false
        fi
    done
    if [[ "$checked_count" -gt 0 ]] && [[ "$all_valid" == "true" ]]; then
        _vc_pass "Model names recognized ($checked_count checked)"
        passes=$((passes + 1))
    fi
}

# --- Summary-only mode (for first-run hint) ----------------------------------

# validate_config_summary — Runs validation silently and returns a one-line summary.
# Sets _VC_PASSES, _VC_WARNINGS, _VC_ERRORS.
# Returns 0 on all-pass or warnings-only, 1 on errors.
validate_config_summary() {
    validate_config >/dev/null 2>&1
    # _VC_PASSES, _VC_WARNINGS, _VC_ERRORS are set by validate_config
}
