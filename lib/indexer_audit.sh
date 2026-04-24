#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# indexer_audit.sh — Startup grammar audit for the tree-sitter indexer (M123)
#
# Sourced by tekhton.sh after indexer.sh — do not run directly.
# Provides: _indexer_run_startup_audit()
#
# The audit invokes audit_grammars() from tree_sitter_languages, classifies
# each declared extension as LOADED / MISSING / MISMATCH, and emits messages:
#   - LOADED   → silent
#   - MISSING  → log_verbose (grammar not installed; benign)
#   - MISMATCH → warn (module imported but no language factory; M122-class bug)
#
# Gated by INDEXER_STARTUP_AUDIT (default: true).
#
# Dependencies: common.sh (warn, log_verbose)
# =============================================================================

# Run the grammar audit against the indexer venv. No-op if the audit is
# disabled or the subprocess fails. Never causes check_indexer_available
# to return non-zero — the audit is purely diagnostic.
# Args:
#   $1 — venv python path
#   $2 — tools directory (parent of tree_sitter_languages.py)
_indexer_run_startup_audit() {
    local venv_python="$1"
    local tools_dir="$2"

    if [[ "${INDEXER_STARTUP_AUDIT:-true}" != "true" ]]; then
        return 0
    fi

    if [[ -z "$venv_python" ]] || { [[ ! -x "$venv_python" ]] && [[ ! -f "$venv_python" ]]; }; then
        return 0
    fi
    if [[ -z "$tools_dir" ]] || [[ ! -d "$tools_dir" ]]; then
        return 0
    fi

    local classification
    classification=$("$venv_python" "$tools_dir/repo_map.py" --audit-grammars-tsv 2>/dev/null) || {
        log_verbose "[indexer] Grammar audit subprocess failed; skipping."
        return 0
    }

    if [[ -z "$classification" ]]; then
        log_verbose "[indexer] Grammar audit produced no output; skipping."
        return 0
    fi

    local status f2 f3 f4 f5
    while IFS=$'\t' read -r status f2 f3 f4 f5; do
        case "$status" in
            SUMMARY)
                log_verbose "[indexer] Grammars: ${f2}/${f5} loaded (${f3} missing, ${f4} API mismatch)"
                ;;
            MISMATCH)
                warn "[indexer] Grammar API mismatch: ${f2} (${f3}) imported but no language factory found (${f5}). Run 'tekhton --setup-indexer' to reinstall, or report this as a bug."
                ;;
            MISSING)
                log_verbose "[indexer] Grammar module missing: ${f2} (${f3} not installed)"
                ;;
            LOADED|"") : ;;
        esac
    done <<<"$classification"

    return 0
}
