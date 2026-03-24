#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_audit.sh — Test integrity audit orchestration
#
# Sourced by tekhton.sh — do not run directly.
# Expects: prompts.sh, agent.sh, common.sh sourced first.
# Expects: TASK, LOG_FILE, PROJECT_DIR, TEST_AUDIT_* config vars set.
#
# Provides:
#   run_test_audit            — Main entry: collect context, run audit, route verdict
#   run_standalone_test_audit — Full audit of ALL test files (--audit-tests)
#   _collect_audit_context    — Gather test files, implementation files, mappings
#   _detect_orphaned_tests    — Shell-based orphan detection (no agent needed)
#   _detect_test_weakening    — Shell-based weakening detection via git diff
#   _parse_audit_verdict      — Extract verdict from TEST_AUDIT_REPORT.md
#   _route_audit_verdict      — Handle PASS/CONCERNS/NEEDS_WORK verdicts
# =============================================================================

# --- Pre-audit file collection ------------------------------------------------

# _collect_audit_context
# Gathers test files written/modified by the tester, implementation files changed
# by the coder, and builds a mapping between them.
# Sets globals: _AUDIT_TEST_FILES, _AUDIT_IMPL_FILES, _AUDIT_DELETED_FILES
_collect_audit_context() {
    _AUDIT_TEST_FILES=""
    _AUDIT_IMPL_FILES=""
    _AUDIT_DELETED_FILES=""

    # Extract test files from TESTER_REPORT.md (checked items = written/modified)
    if [[ -f "TESTER_REPORT.md" ]]; then
        # shellcheck disable=SC2016  # Backtick is literal in grep pattern
        _AUDIT_TEST_FILES=$(grep -oP '^\- \[x\] `\K[^`]+' TESTER_REPORT.md 2>/dev/null || true)
    fi

    # Extract implementation files from CODER_SUMMARY.md
    if [[ -f "CODER_SUMMARY.md" ]]; then
        # shellcheck disable=SC2016  # Backtick is literal in grep pattern
        _AUDIT_IMPL_FILES=$(grep -oP '`\K[^`]+(?=`)' CODER_SUMMARY.md 2>/dev/null \
            | grep -vE 'test|spec|Test|Spec' || true)
    fi

    # Detect deleted files from git diff (files deleted in this run)
    if git rev-parse --git-dir &>/dev/null; then
        _AUDIT_DELETED_FILES=$(git diff --name-status HEAD 2>/dev/null \
            | awk '$1 == "D" { print $2 }' || true)
        # Also check staged deletes
        local _staged_deletes
        _staged_deletes=$(git diff --cached --name-status 2>/dev/null \
            | awk '$1 == "D" { print $2 }' || true)
        if [[ -n "$_staged_deletes" ]]; then
            _AUDIT_DELETED_FILES="${_AUDIT_DELETED_FILES}
${_staged_deletes}"
        fi
    fi

    export _AUDIT_TEST_FILES _AUDIT_IMPL_FILES _AUDIT_DELETED_FILES
}

# _discover_all_test_files
# Discovers ALL test files in the project for --audit-tests standalone mode.
# Uses common test directory/file naming conventions.
# Returns: newline-separated list of test file paths
_discover_all_test_files() {
    local test_files=""

    if ! git rev-parse --git-dir &>/dev/null; then
        warn "[test-audit] Not a git repo — cannot discover test files."
        return
    fi

    # Use git ls-files to respect .gitignore
    test_files=$(git ls-files 2>/dev/null | grep -iE \
        '(^tests?/|/__tests__/|_test\.|\.test\.|\.spec\.|_spec\.|test_)' || true)

    echo "$test_files"
}

# --- Orphan detection (pure shell) -------------------------------------------

# _detect_orphaned_tests [test_files] [deleted_files]
# For each test file, extract import/require statements and check if they
# reference deleted modules. Also checks for renamed/moved files.
# Args override globals for testability. Defaults: _AUDIT_TEST_FILES, _AUDIT_DELETED_FILES
# Sets: _AUDIT_ORPHAN_FINDINGS (multiline, one finding per line)
# shellcheck disable=SC2120  # Args are optional overrides; callers use globals
_detect_orphaned_tests() {
    _AUDIT_ORPHAN_FINDINGS=""
    local test_files="${1:-${_AUDIT_TEST_FILES:-}}"
    local deleted_files="${2:-${_AUDIT_DELETED_FILES:-}}"

    [[ -z "$test_files" ]] && return
    [[ -z "$deleted_files" ]] && return

    while IFS= read -r test_file; do
        [[ -z "$test_file" ]] && continue
        [[ ! -f "$test_file" ]] && continue

        # Extract import targets (Python, JS/TS, Go patterns)
        local imports=""
        # Python: from X import / import X
        imports=$(grep -oP '(?:from\s+|import\s+)[\w.]+' "$test_file" 2>/dev/null || true)
        # JS/TS: require('X') / import ... from 'X'
        local js_imports
        js_imports=$(grep -oP "(?:require\s*\(\s*['\"]|from\s+['\"])([^'\"]+)" "$test_file" 2>/dev/null || true)
        if [[ -n "$js_imports" ]]; then
            imports="${imports}
${js_imports}"
        fi

        # Check each deleted file against imports
        while IFS= read -r deleted; do
            [[ -z "$deleted" ]] && continue
            local deleted_basename
            deleted_basename=$(basename "$deleted")
            local deleted_noext="${deleted_basename%.*}"

            # Check if the test file references the deleted module
            if echo "$imports" | grep -qF "$deleted_noext" 2>/dev/null; then
                _AUDIT_ORPHAN_FINDINGS="${_AUDIT_ORPHAN_FINDINGS}
ORPHAN: ${test_file} imports deleted module '${deleted}'"
            fi
        done <<< "$deleted_files"
    done <<< "$test_files"

    # Trim leading newline
    _AUDIT_ORPHAN_FINDINGS="${_AUDIT_ORPHAN_FINDINGS#$'\n'}"
    export _AUDIT_ORPHAN_FINDINGS
}

# --- Weakening detection (pure shell on git diff) ----------------------------

# _detect_test_weakening
# For each MODIFIED (not newly created) test file, analyze the diff for:
#   - Removed assertions
#   - Broadened assertions (specific → generic)
#   - Removed test functions
# Reads: _AUDIT_TEST_FILES
# Sets: _AUDIT_WEAKENING_FINDINGS (multiline, one finding per line)
_detect_test_weakening() {
    _AUDIT_WEAKENING_FINDINGS=""

    [[ -z "${_AUDIT_TEST_FILES:-}" ]] && return

    if ! git rev-parse --git-dir &>/dev/null; then
        return
    fi

    while IFS= read -r test_file; do
        [[ -z "$test_file" ]] && continue
        [[ ! -f "$test_file" ]] && continue

        # Skip newly created files (no weakening possible)
        if ! git show "HEAD:${test_file}" &>/dev/null; then
            continue
        fi

        local diff_output
        diff_output=$(git diff HEAD -- "$test_file" 2>/dev/null || true)
        [[ -z "$diff_output" ]] && continue

        # Count removed vs added assertion lines
        local removed_asserts=0
        local added_asserts=0
        removed_asserts=$(echo "$diff_output" \
            | grep -cE '^\-.*\b(assert|expect|should|assertEqual|assertEquals|assertThat|assertTrue|assertFalse|toBe|toEqual|toMatch|toThrow)\b' 2>/dev/null || echo "0")
        added_asserts=$(echo "$diff_output" \
            | grep -cE '^\+.*\b(assert|expect|should|assertEqual|assertEquals|assertThat|assertTrue|assertFalse|toBe|toEqual|toMatch|toThrow)\b' 2>/dev/null || echo "0")

        removed_asserts="${removed_asserts//[!0-9]/}"
        added_asserts="${added_asserts//[!0-9]/}"
        : "${removed_asserts:=0}"
        : "${added_asserts:=0}"

        # Net assertion loss is suspicious
        if [[ "$removed_asserts" -gt "$added_asserts" ]]; then
            local net_loss=$((removed_asserts - added_asserts))
            _AUDIT_WEAKENING_FINDINGS="${_AUDIT_WEAKENING_FINDINGS}
WEAKENING: ${test_file} — net loss of ${net_loss} assertion(s) (removed ${removed_asserts}, added ${added_asserts})"
        fi

        # Detect specific→generic assertion pattern changes
        local broadened=""
        broadened=$(echo "$diff_output" \
            | grep -cE '^\+.*(assertTrue\s*\(|assertGreater|assertLess|toBeGreater|toBeLess|toBeTruthy|toBeFalsy)' 2>/dev/null || echo "0")
        broadened="${broadened//[!0-9]/}"
        : "${broadened:=0}"
        local specific_removed
        specific_removed=$(echo "$diff_output" \
            | grep -cE '^\-.*(assertEqual|assertEquals|toBe\(|toEqual\(|toStrictEqual)' 2>/dev/null || echo "0")
        specific_removed="${specific_removed//[!0-9]/}"
        : "${specific_removed:=0}"

        if [[ "$specific_removed" -gt 0 ]] && [[ "$broadened" -gt 0 ]]; then
            _AUDIT_WEAKENING_FINDINGS="${_AUDIT_WEAKENING_FINDINGS}
WEAKENING: ${test_file} — ${specific_removed} specific assertion(s) replaced with ${broadened} broader assertion(s)"
        fi

        # Detect removed test functions
        local removed_tests=0
        removed_tests=$(echo "$diff_output" \
            | grep -cE '^\-\s*(def test_|it\(|test\(|func Test|describe\()' 2>/dev/null || echo "0")
        removed_tests="${removed_tests//[!0-9]/}"
        : "${removed_tests:=0}"

        if [[ "$removed_tests" -gt 0 ]]; then
            _AUDIT_WEAKENING_FINDINGS="${_AUDIT_WEAKENING_FINDINGS}
WEAKENING: ${test_file} — ${removed_tests} test function(s) removed"
        fi
    done <<< "$_AUDIT_TEST_FILES"

    # Trim leading newline
    _AUDIT_WEAKENING_FINDINGS="${_AUDIT_WEAKENING_FINDINGS#$'\n'}"
    export _AUDIT_WEAKENING_FINDINGS
}

# --- Verdict parsing and routing ---------------------------------------------

# _parse_audit_verdict
# Extracts the verdict from TEST_AUDIT_REPORT.md.
# Returns: PASS, CONCERNS, or NEEDS_WORK (defaults to PASS if unparseable)
_parse_audit_verdict() {
    local report_file="${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}"
    if [[ ! -f "$report_file" ]]; then
        echo "PASS"
        return
    fi

    local verdict
    verdict=$(grep -oiE 'Verdict:\s*(NEEDS_WORK|PASS|CONCERNS)' "$report_file" 2>/dev/null \
        | head -1 | sed 's/.*:\s*//' | tr '[:lower:]' '[:upper:]' || true)

    case "$verdict" in
        NEEDS_WORK) echo "NEEDS_WORK" ;;
        CONCERNS)   echo "CONCERNS" ;;
        *)          echo "PASS" ;;
    esac
}

# _route_audit_verdict VERDICT
# Routes based on audit verdict:
#   PASS       → continue (no action)
#   CONCERNS   → log findings to NON_BLOCKING_LOG.md, continue
#   NEEDS_WORK → tester rework (bounded by TEST_AUDIT_MAX_REWORK_CYCLES)
_route_audit_verdict() {
    local verdict="$1"
    local report_file="${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}"

    case "$verdict" in
        PASS)
            success "Test audit passed — all tests meet integrity standards."
            return 0
            ;;
        CONCERNS)
            warn "Test audit raised concerns — logging to NON_BLOCKING_LOG.md."
            if [[ -f "$report_file" ]]; then
                local findings
                findings=$(grep -E '^\s*####\s+(INTEGRITY|SCOPE|COVERAGE|WEAKENING|NAMING)' "$report_file" 2>/dev/null || true)
                if [[ -n "$findings" ]] && command -v _ensure_nonblocking_log &>/dev/null; then
                    _ensure_nonblocking_log
                    local nb_file="${NON_BLOCKING_LOG_FILE:-NON_BLOCKING_LOG.md}"
                    {
                        echo ""
                        echo "### Test Audit Concerns ($(date +%Y-%m-%d))"
                        echo "$findings"
                    } >> "$nb_file"
                fi
            fi
            return 0
            ;;
        NEEDS_WORK)
            warn "Test audit verdict: NEEDS_WORK — routing to tester for rework."
            return 1
            ;;
    esac
}

# --- Main audit function (pipeline integration) ------------------------------

# run_test_audit
# Called after tester completes within the test stage.
# 1. Collects audit context (test files, impl files, deleted files)
# 2. Runs shell-based orphan and weakening detection
# 3. Invokes reviewer agent with test_audit prompt
# 4. Parses verdict and routes accordingly
# Returns: 0 on PASS/CONCERNS, 1 on NEEDS_WORK (triggers rework)
run_test_audit() {
    if [[ "${TEST_AUDIT_ENABLED:-true}" != "true" ]]; then
        log "Test audit disabled (TEST_AUDIT_ENABLED=false). Skipping."
        return 0
    fi

    header "Test Integrity Audit"

    # Step 1: Collect context
    _collect_audit_context

    # Skip audit if no test files were written
    if [[ -z "$_AUDIT_TEST_FILES" ]]; then
        log "No test files written this run — skipping audit."
        return 0
    fi

    log "Auditing $(echo "$_AUDIT_TEST_FILES" | grep -c '.' || echo 0) test file(s)..."

    # Step 2: Shell-based detection (instant, no agent needed)
    if [[ "${TEST_AUDIT_ORPHAN_DETECTION:-true}" == "true" ]]; then
        _detect_orphaned_tests
    fi
    if [[ "${TEST_AUDIT_WEAKENING_DETECTION:-true}" == "true" ]]; then
        _detect_test_weakening
    fi

    # Log shell findings
    if [[ -n "${_AUDIT_ORPHAN_FINDINGS:-}" ]]; then
        log "Orphan detection found issues:"
        echo "$_AUDIT_ORPHAN_FINDINGS" | while IFS= read -r line; do
            [[ -n "$line" ]] && warn "  $line"
        done
    fi
    if [[ -n "${_AUDIT_WEAKENING_FINDINGS:-}" ]]; then
        log "Weakening detection found issues:"
        echo "$_AUDIT_WEAKENING_FINDINGS" | while IFS= read -r line; do
            [[ -n "$line" ]] && warn "  $line"
        done
    fi

    # Step 3: Build audit context for the agent prompt
    export TEST_AUDIT_CONTEXT=""
    local _ctx=""
    # shellcheck disable=SC2001  # sed needed for multiline prefix addition
    _ctx="## Test Files Under Audit
$(echo "$_AUDIT_TEST_FILES" | sed 's/^/- /')

## Implementation Files Changed
$(echo "${_AUDIT_IMPL_FILES:-none}" | sed 's/^/- /')
"

    if [[ -n "${_AUDIT_ORPHAN_FINDINGS:-}" ]]; then
        _ctx="${_ctx}
## Shell-Detected Orphans (pre-verified)
${_AUDIT_ORPHAN_FINDINGS}
"
    fi

    if [[ -n "${_AUDIT_WEAKENING_FINDINGS:-}" ]]; then
        _ctx="${_ctx}
## Shell-Detected Weakening (pre-verified)
${_AUDIT_WEAKENING_FINDINGS}
"
    fi

    TEST_AUDIT_CONTEXT="$_ctx"
    export CODER_DELETED_FILES="${_AUDIT_DELETED_FILES:-}"

    # Step 4: Invoke audit agent
    local audit_prompt
    audit_prompt=$(render_prompt "test_audit")

    log "Invoking test audit agent (max ${TEST_AUDIT_MAX_TURNS:-8} turns)..."
    run_agent \
        "Test Audit" \
        "${CLAUDE_REVIEWER_MODEL}" \
        "${TEST_AUDIT_MAX_TURNS:-8}" \
        "$audit_prompt" \
        "$LOG_FILE" \
        "${AGENT_TOOLS_REVIEWER:-Read Glob Grep}"

    # Step 5: Parse verdict and route
    local verdict
    verdict=$(_parse_audit_verdict)
    log "Test audit verdict: ${verdict}"

    # Emit causal event
    if command -v emit_event &>/dev/null; then
        emit_event "test_audit" "tester" "verdict=${verdict}" "" "" \
            "{\"verdict\":\"${verdict}\",\"orphans\":\"${_AUDIT_ORPHAN_FINDINGS:+found}\",\"weakening\":\"${_AUDIT_WEAKENING_FINDINGS:+found}\"}" \
            2>/dev/null || true
    fi

    if ! _route_audit_verdict "$verdict"; then
        # NEEDS_WORK — attempt rework
        local rework_cycles=0
        local max_rework="${TEST_AUDIT_MAX_REWORK_CYCLES:-1}"

        while [[ "$rework_cycles" -lt "$max_rework" ]]; do
            rework_cycles=$((rework_cycles + 1))
            log "Test audit rework cycle ${rework_cycles}/${max_rework}..."

            export TEST_AUDIT_FINDINGS=""
            if [[ -f "${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}" ]]; then
                TEST_AUDIT_FINDINGS=$(_safe_read_file "${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}" "TEST_AUDIT_REPORT")
            fi

            local rework_prompt
            rework_prompt=$(render_prompt "test_audit_rework")

            run_agent \
                "Tester (audit rework ${rework_cycles})" \
                "${CLAUDE_TESTER_MODEL}" \
                "${ADJUSTED_TESTER_TURNS:-$TESTER_MAX_TURNS}" \
                "$rework_prompt" \
                "$LOG_FILE" \
                "${AGENT_TOOLS_TESTER:-Read Glob Grep Write Edit Bash}"

            # Re-run audit after rework
            _collect_audit_context
            if [[ "${TEST_AUDIT_ORPHAN_DETECTION:-true}" == "true" ]]; then
                _detect_orphaned_tests
            fi
            if [[ "${TEST_AUDIT_WEAKENING_DETECTION:-true}" == "true" ]]; then
                _detect_test_weakening
            fi

            # Rebuild context
            # shellcheck disable=SC2001  # sed needed for multiline prefix addition
            TEST_AUDIT_CONTEXT="## Test Files Under Audit
$(echo "$_AUDIT_TEST_FILES" | sed 's/^/- /')

## Implementation Files Changed
$(echo "${_AUDIT_IMPL_FILES:-none}" | sed 's/^/- /')
"
            if [[ -n "${_AUDIT_ORPHAN_FINDINGS:-}" ]]; then
                TEST_AUDIT_CONTEXT="${TEST_AUDIT_CONTEXT}
## Shell-Detected Orphans (pre-verified)
${_AUDIT_ORPHAN_FINDINGS}
"
            fi
            if [[ -n "${_AUDIT_WEAKENING_FINDINGS:-}" ]]; then
                TEST_AUDIT_CONTEXT="${TEST_AUDIT_CONTEXT}
## Shell-Detected Weakening (pre-verified)
${_AUDIT_WEAKENING_FINDINGS}
"
            fi
            CODER_DELETED_FILES="${_AUDIT_DELETED_FILES:-}"

            audit_prompt=$(render_prompt "test_audit")
            run_agent \
                "Test Audit (re-check ${rework_cycles})" \
                "${CLAUDE_REVIEWER_MODEL}" \
                "${TEST_AUDIT_MAX_TURNS:-8}" \
                "$audit_prompt" \
                "$LOG_FILE" \
                "${AGENT_TOOLS_REVIEWER:-Read Glob Grep}"

            verdict=$(_parse_audit_verdict)
            log "Test audit re-check verdict: ${verdict}"

            if [[ "$verdict" != "NEEDS_WORK" ]]; then
                _route_audit_verdict "$verdict"
                return 0
            fi
        done

        # Exhausted rework cycles
        warn "Test audit NEEDS_WORK after ${max_rework} rework cycle(s). Escalating to human."
        warn "Review TEST_AUDIT_REPORT.md and fix tests manually."
        return 0  # Don't block pipeline — log and proceed
    fi

    return 0
}

# --- Standalone audit (--audit-tests) ----------------------------------------

# run_standalone_test_audit
# Scans ALL test files in the project (not just current diff).
# Used as a one-time bootstrap command for projects adopting M20.
run_standalone_test_audit() {
    header "Tekhton — Standalone Test Audit"

    local all_test_files
    all_test_files=$(_discover_all_test_files)

    if [[ -z "$all_test_files" ]]; then
        log "No test files found in project."
        return 0
    fi

    local file_count
    file_count=$(echo "$all_test_files" | grep -c '.' || echo "0")
    log "Discovered ${file_count} test file(s) for audit."

    # Set globals for audit context
    _AUDIT_TEST_FILES="$all_test_files"
    _AUDIT_IMPL_FILES=""
    _AUDIT_DELETED_FILES=""
    _AUDIT_ORPHAN_FINDINGS=""
    _AUDIT_WEAKENING_FINDINGS=""

    # Build context for full-suite audit
    local _standalone_ctx
    # shellcheck disable=SC2001  # sed needed for multiline prefix
    _standalone_ctx="## Test Files Under Audit (full suite)
$(echo "$all_test_files" | sed 's/^/- /')

## Mode: Standalone full-suite audit (--audit-tests)
All test files are included regardless of current diff.
"
    export TEST_AUDIT_CONTEXT="$_standalone_ctx"
    export CODER_DELETED_FILES=""

    # Invoke audit agent
    local audit_prompt
    audit_prompt=$(render_prompt "test_audit")

    log "Invoking test audit agent (max ${TEST_AUDIT_MAX_TURNS:-8} turns)..."
    run_agent \
        "Test Audit (standalone)" \
        "${CLAUDE_REVIEWER_MODEL}" \
        "${TEST_AUDIT_MAX_TURNS:-8}" \
        "$audit_prompt" \
        "${LOG_DIR:-/tmp}/$(date +%Y%m%d_%H%M%S)_test-audit.log" \
        "${AGENT_TOOLS_REVIEWER:-Read Glob Grep}"

    # Parse and display verdict
    local verdict
    verdict=$(_parse_audit_verdict)

    echo
    echo "════════════════════════════════════════"
    echo "  Test Audit Results"
    echo "════════════════════════════════════════"
    echo "  Files audited: ${file_count}"
    echo "  Verdict:       ${verdict}"
    if [[ -f "${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}" ]]; then
        echo "  Report:        ${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}"
        echo
        # Show findings summary
        local high_count
        high_count=$(grep -c 'Severity: HIGH' "${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}" 2>/dev/null || echo "0")
        local medium_count
        medium_count=$(grep -c 'Severity: MEDIUM' "${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}" 2>/dev/null || echo "0")
        echo "  HIGH findings:   ${high_count}"
        echo "  MEDIUM findings: ${medium_count}"
    fi
    echo "════════════════════════════════════════"
}
