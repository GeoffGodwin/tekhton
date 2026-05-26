#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_audit_helpers.sh — Pre-audit file collection and context assembly
#
# Sourced by tekhton.sh — do not run directly.
# Expects: common.sh sourced first.
#
# Provides:
#   _collect_audit_context    — Gather test files, implementation files, deletes
#   _discover_all_test_files  — List all project test files for standalone mode
#   _build_test_audit_context — Render TEST_AUDIT_CONTEXT for the agent prompt
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

    # Extract test files from "${TESTER_REPORT_FILE}" (checked items = written/modified)
    if [[ -f "${TESTER_REPORT_FILE:-.tekhton/TESTER_REPORT.md}" ]]; then
        # shellcheck disable=SC2016  # Backtick is literal in grep pattern
        _AUDIT_TEST_FILES=$(grep -oP '^\- \[x\] `\K[^`]+' "${TESTER_REPORT_FILE:-.tekhton/TESTER_REPORT.md}" 2>/dev/null || true)
    fi

    # Extract implementation files from "${CODER_SUMMARY_FILE}"
    if [[ -f "${CODER_SUMMARY_FILE:-.tekhton/CODER_SUMMARY.md}" ]]; then
        # shellcheck disable=SC2016  # Backtick is literal in grep pattern
        _AUDIT_IMPL_FILES=$(grep -oP '`\K[^`]+(?=`)' "${CODER_SUMMARY_FILE:-.tekhton/CODER_SUMMARY.md}" 2>/dev/null \
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

# --- Audit context assembly --------------------------------------------------

# _build_test_audit_context
# Assembles TEST_AUDIT_CONTEXT and CODER_DELETED_FILES from the audit globals.
# Renders modified-this-run and freshness-sample (M89) test files in separate
# labeled sections so the audit agent can apply scope-alignment scrutiny to
# sampled files without assuming recent coder changes caused any issues.
_build_test_audit_context() {
    local _ctx="## Test Files Under Audit (modified this run)
"
    if [[ -n "${_AUDIT_TEST_FILES:-}" ]]; then
        # shellcheck disable=SC2001  # sed needed for multiline prefix
        _ctx="${_ctx}$(echo "$_AUDIT_TEST_FILES" | sed 's/^/- /')
"
    else
        _ctx="${_ctx}- (none)
"
    fi

    if [[ -n "${_AUDIT_SAMPLE_FILES:-}" ]]; then
        # shellcheck disable=SC2001  # sed needed for multiline prefix
        _ctx="${_ctx}
## Test Files Under Audit (freshness sample — may be stale)
$(echo "$_AUDIT_SAMPLE_FILES" | sed 's/^/- /')
"
    fi

    # shellcheck disable=SC2001  # sed needed for multiline prefix
    _ctx="${_ctx}
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

    export TEST_AUDIT_CONTEXT="$_ctx"
    export CODER_DELETED_FILES="${_AUDIT_DELETED_FILES:-}"
}
