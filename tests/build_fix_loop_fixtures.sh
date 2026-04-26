#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tests/build_fix_loop_fixtures.sh — Shared test fixtures for the M128
# build-fix loop test suite.
#
# Sourced by tests/test_build_fix_loop.sh (and any future M128 integration
# tests). NOT auto-run by run_tests.sh — the runner only discovers files
# matching the test_*.sh prefix.
#
# Provides:
#   - stub functions (render_prompt, _wrap_file_content, _safe_read_file,
#     filter_code_errors, classify_routing_decision,
#     classify_build_errors_with_stats, append_human_action,
#     write_pipeline_state, _build_resume_flag, run_agent, run_build_gate)
#   - GATE_CALLS / GATE_MODE controllable state for run_build_gate
#   - reset_state(): per-test reset
#   - run_loop_capture(): subshell wrapper that captures the four Goal-7
#     env vars + WROTE_STATE_NOTES on every exit path (success or exit 1)
#   - field(): single-line record field extractor
#
# All stubs honor the same conventions as the production code so the
# loop's branching logic exercises real paths.
# =============================================================================

# stub: render_prompt — empty string is fine (the stub run_agent ignores it)
render_prompt() { echo ""; }

# stub: _wrap_file_content — pass-through
_wrap_file_content() { printf '%s\n' "${2:-}"; }

# stub: _safe_read_file — read raw file content if present
_safe_read_file() {
    local path="$1"
    if [[ -f "$path" ]]; then
        cat "$path"
    fi
}

# stub: filter_code_errors — pass-through
filter_code_errors() { cat; }

# stub: classify_routing_decision — controllable via STUB_ROUTING
classify_routing_decision() {
    local token="${STUB_ROUTING:-code_dominant}"
    export LAST_BUILD_CLASSIFICATION="$token"
    echo "$token"
}

# stub: classify_build_errors_with_stats — empty (no diagnosis emission)
classify_build_errors_with_stats() { :; }

# stub: append_human_action — silent
append_human_action() { :; }

# stub: write_pipeline_state — capture extra_notes for assertions
WROTE_STATE_NOTES=""
write_pipeline_state() {
    WROTE_STATE_NOTES="${5:-}"
    echo "STATE_NOTES: ${WROTE_STATE_NOTES}" >> "${TMPDIR_TOP}/state_log.txt"
}

# stub: _build_resume_flag — fixed string
_build_resume_flag() { echo "--start-at coder"; }

# stub: run_agent — set LAST_AGENT_* without doing work
run_agent() {
    LAST_AGENT_EXIT_CODE=0
    LAST_AGENT_TURNS="${3:-10}"
    export LAST_AGENT_EXIT_CODE LAST_AGENT_TURNS
    export LAST_AGENT_NULL_RUN=false
}

# Gate stub state — modes:
#   retry_pass  — fail attempt 1, pass attempt 2
#   decreasing  — fail every attempt; strictly decreasing error counts
#   identical   — fail every attempt with identical error file (no progress)
#   always_fail — fail every attempt with frozen single-line errors
GATE_CALLS=0
GATE_MODE="always_fail"
ERR_LINES_PER_ATTEMPT=10

run_build_gate() {
    GATE_CALLS=$((GATE_CALLS + 1))
    case "$GATE_MODE" in
        retry_pass)
            if (( GATE_CALLS >= 2 )); then return 0; fi
            printf 'error 1\nerror 2\n' > "${BUILD_RAW_ERRORS_FILE}"
            return 1
            ;;
        decreasing)
            local n=$(( ERR_LINES_PER_ATTEMPT - GATE_CALLS ))
            (( n < 1 )) && n=1
            : > "${BUILD_RAW_ERRORS_FILE}"
            local i
            for (( i=0; i<n; i++ )); do
                echo "error line $i" >> "${BUILD_RAW_ERRORS_FILE}"
            done
            return 1
            ;;
        identical)
            cat > "${BUILD_RAW_ERRORS_FILE}" <<EOF
error a
error b
error c
EOF
            return 1
            ;;
        always_fail|*)
            echo "error frozen" > "${BUILD_RAW_ERRORS_FILE}"
            return 1
            ;;
    esac
}

# reset_state — clear per-test state and re-export defaults.
reset_state() {
    GATE_CALLS=0
    GATE_MODE="always_fail"
    ERR_LINES_PER_ATTEMPT=10
    STUB_ROUTING="code_dominant"
    WROTE_STATE_NOTES=""
    rm -f "${BUILD_RAW_ERRORS_FILE}" "${BUILD_FIX_REPORT_FILE}" \
        "${BUILD_ROUTING_DIAGNOSIS_FILE}"
    unset BUILD_FIX_OUTCOME BUILD_FIX_ATTEMPTS \
        BUILD_FIX_TURN_BUDGET_USED BUILD_FIX_PROGRESS_GATE_FAILURES \
        SECONDARY_ERROR_CATEGORY SECONDARY_ERROR_SUBCATEGORY \
        SECONDARY_ERROR_SIGNAL SECONDARY_ERROR_SOURCE
    export BUILD_FIX_ENABLED=true
    export BUILD_FIX_MAX_ATTEMPTS=3
    export BUILD_FIX_BASE_TURN_DIVISOR=3
    export BUILD_FIX_MAX_TURN_MULTIPLIER=100
    export BUILD_FIX_REQUIRE_PROGRESS=true
    export BUILD_FIX_TOTAL_TURN_CAP=120
    export EFFECTIVE_CODER_MAX_TURNS=80
}

# run_loop_capture — invoke run_build_fix_loop in a subshell with an
# overridden exit() that records the four Goal-7 env vars + state notes
# to a sidecar file (FD 5) before propagating the exit. Echoes the
# capture record (single line, semicolon-delimited k=v) to stdout.
run_loop_capture() {
    local capture_file="${TMPDIR_TOP}/loop_capture.txt"
    : > "$capture_file"
    (
        exec 5>>"$capture_file"
        exit() {
            printf 'OUTCOME=%s;ATTEMPTS=%s;USED=%s;GATES=%s;SEC_CAT=%s;SEC_SUB=%s;NOTES=%s\n' \
                "${BUILD_FIX_OUTCOME:-?}" "${BUILD_FIX_ATTEMPTS:-?}" \
                "${BUILD_FIX_TURN_BUDGET_USED:-?}" \
                "${BUILD_FIX_PROGRESS_GATE_FAILURES:-?}" \
                "${SECONDARY_ERROR_CATEGORY:-}" \
                "${SECONDARY_ERROR_SUBCATEGORY:-}" \
                "${WROTE_STATE_NOTES:-}" >&5
            builtin exit "${1:-0}"
        }
        run_build_fix_loop >/dev/null 2>&1
        # Reached only on the success path
        printf 'OUTCOME=%s;ATTEMPTS=%s;USED=%s;GATES=%s;SEC_CAT=%s;SEC_SUB=%s;NOTES=%s\n' \
            "${BUILD_FIX_OUTCOME:-?}" "${BUILD_FIX_ATTEMPTS:-?}" \
            "${BUILD_FIX_TURN_BUDGET_USED:-?}" \
            "${BUILD_FIX_PROGRESS_GATE_FAILURES:-?}" \
            "${SECONDARY_ERROR_CATEGORY:-}" \
            "${SECONDARY_ERROR_SUBCATEGORY:-}" \
            "${WROTE_STATE_NOTES:-}" >&5
    ) || true
    cat "$capture_file"
}

# field — extract a key from the run_loop_capture record (k=v;k=v;...).
field() {
    local key="$1" record="$2"
    echo "$record" | tr ';' '\n' | grep -E "^${key}=" | head -1 | cut -d= -f2-
}
