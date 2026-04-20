#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# init_wizard.sh — Feature wizard for --init (M109)
#
# Detects Python 3.8+ and asks the user three guided questions about
# Python-dependent features (TUI, repo maps, Serena LSP). Exports answers as
# _WIZARD_* environment variables consumed by _emit_section_features() and
# the post-init venv setup trigger in init.sh.
#
# Sourced by init.sh — do not run directly.
# Depends on: common.sh (log, warn), prompts_interactive.sh (prompt_confirm,
# _can_prompt).
# =============================================================================

# Minimum Python version for enhanced features (matches tools/setup_indexer.sh).
_WIZARD_MIN_PYTHON_MAJOR=3
_WIZARD_MIN_PYTHON_MINOR=8

# _wizard_find_python3 — Locates Python 3.8+ on PATH.
# Prints the python executable name (e.g. "python3") to stdout on success.
# Returns 1 if no acceptable interpreter is found.
_wizard_find_python3() {
    local cmd ver major minor
    for cmd in python3 python; do
        command -v "$cmd" >/dev/null 2>&1 || continue
        ver=$("$cmd" -c \
            "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" \
            2>/dev/null) || continue
        major="${ver%%.*}"
        minor="${ver#*.}"
        [[ "$major" =~ ^[0-9]+$ ]] || continue
        [[ "$minor" =~ ^[0-9]+$ ]] || continue
        if (( major > _WIZARD_MIN_PYTHON_MAJOR \
                || (major == _WIZARD_MIN_PYTHON_MAJOR \
                    && minor >= _WIZARD_MIN_PYTHON_MINOR) )); then
            echo "$cmd"
            return 0
        fi
    done
    return 1
}

# _wizard_emit_no_python_advisory — Prints the Python-not-found message to stderr.
_wizard_emit_no_python_advisory() {
    {
        echo
        echo "  ℹ Python 3.8+ was not found on PATH."
        echo
        echo "    Enhanced features require Python and are not available right now:"
        echo "      • Rich TUI — interactive live dashboard during pipeline runs"
        echo "      • Tree-sitter repo maps — intelligent code context via PageRank"
        echo "      • Serena LSP — language-server-powered code intelligence"
        echo
        echo "    Install Python 3.8+ and run 'tekhton --setup-indexer' to enable them later."
        echo "    See: docs/getting-started/installation.md"
        echo
    } >&2
}

# _wizard_reset_state — Clears any prior _WIZARD_* values so repeated calls
# (notably from tests) start from a known blank slate.
_wizard_reset_state() {
    unset _WIZARD_TUI_ENABLED \
          _WIZARD_REPO_MAP_ENABLED \
          _WIZARD_SERENA_ENABLED \
          _WIZARD_NEEDS_VENV \
          _WIZARD_PYTHON_FOUND
}

# run_feature_wizard — Orchestrates the feature wizard.
# Args: $1 = reinit_mode ("reinit" to skip — see §6 of M109 design)
# Side effects: exports _WIZARD_* environment variables for downstream
# config emission and venv setup. No-op on reinit.
run_feature_wizard() {
    local reinit_mode="${1:-}"
    if [[ "$reinit_mode" == "reinit" ]]; then
        return 0
    fi

    _wizard_reset_state

    # Non-interactive path: enable features (when Python is present) but
    # never trigger venv setup — see §7 of the M109 design for rationale.
    if [[ "${TEKHTON_NON_INTERACTIVE:-}" == "true" ]] || ! _can_prompt; then
        if _wizard_find_python3 >/dev/null 2>&1; then
            export _WIZARD_TUI_ENABLED="auto"
            export _WIZARD_REPO_MAP_ENABLED="true"
            export _WIZARD_SERENA_ENABLED="true"
            export _WIZARD_PYTHON_FOUND="true"
        else
            export _WIZARD_PYTHON_FOUND="false"
        fi
        return 0
    fi

    # Interactive path
    local python_cmd=""
    if ! python_cmd=$(_wizard_find_python3); then
        export _WIZARD_PYTHON_FOUND="false"
        _wizard_emit_no_python_advisory
        return 0
    fi

    export _WIZARD_PYTHON_FOUND="true"

    local python_version=""
    python_version=$("$python_cmd" -c \
        "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')" \
        2>/dev/null) || python_version=""

    {
        echo
        if [[ -n "$python_version" ]]; then
            echo "  ✓ Python ${python_version} found — enhanced features available."
        else
            echo "  ✓ Python 3 found — enhanced features available."
        fi
        echo
    } >&2

    if prompt_confirm "  Enable Rich TUI? (recommended)" "y"; then
        export _WIZARD_TUI_ENABLED="true"
    fi
    if prompt_confirm "  Enable tree-sitter repo maps? (recommended)" "y"; then
        export _WIZARD_REPO_MAP_ENABLED="true"
    fi
    if prompt_confirm "  Enable Serena LSP intelligence? (recommended)" "y"; then
        export _WIZARD_SERENA_ENABLED="true"
    fi

    if [[ "${_WIZARD_TUI_ENABLED:-}" == "true" ]] \
            || [[ "${_WIZARD_REPO_MAP_ENABLED:-}" == "true" ]] \
            || [[ "${_WIZARD_SERENA_ENABLED:-}" == "true" ]]; then
        export _WIZARD_NEEDS_VENV="true"
    fi
}

# _wizard_attention_lines — Emits init banner attention bullets reflecting
# Python feature wizard outcome. One line per bullet (or empty if wizard
# never ran). Args: $1 = bullet glyph.
_wizard_attention_lines() {
    local bullet="$1"
    case "${_WIZARD_PYTHON_FOUND:-}" in
        true)
            local features=()
            [[ "${_WIZARD_TUI_ENABLED:-}" == "true" ]] && features+=("TUI")
            [[ "${_WIZARD_TUI_ENABLED:-}" == "auto" ]] && features+=("TUI")
            [[ "${_WIZARD_REPO_MAP_ENABLED:-}" == "true" ]] && features+=("repo maps")
            [[ "${_WIZARD_SERENA_ENABLED:-}" == "true" ]] && features+=("Serena")
            if [[ "${#features[@]}" -gt 0 ]]; then
                local joined="${features[0]}"
                local i
                for (( i = 1; i < ${#features[@]}; i++ )); do
                    joined="${joined}, ${features[$i]}"
                done
                echo "    ${bullet} Enhanced features enabled: ${joined}"
            fi
            ;;
        false)
            echo "    ${bullet} Install Python 3.8+ to enable enhanced features (TUI, repo maps, Serena)"
            ;;
    esac
}

# _wizard_run_setup_script — Runs a setup script with summarized or verbose output.
# Args: $1 = label (e.g. "Python environment"),
#       $2 = script path, $3 = log file, $4... = script args
# Returns 0 on success, 1 on failure.
_wizard_run_setup_script() {
    local label="$1"
    local script="$2"
    local log_file="$3"
    shift 3
    if [[ "${VERBOSE_OUTPUT:-false}" == "true" ]]; then
        bash "$script" "$@"
        return $?
    fi
    if bash "$script" "$@" > "$log_file" 2>&1; then
        success "${label} ready"
        return 0
    fi
    warn "${label} setup failed (see ${log_file#"${PWD}/"})"
    return 1
}

# _run_wizard_venv_setup — Runs setup_indexer.sh (and optionally setup_serena.sh)
# when the user enabled any Python feature. Failure does not abort init —
# config remains valid and features degrade at runtime.
# Args: $1 = project_dir, $2 = tekhton_home, $3 = conf_dir
_run_wizard_venv_setup() {
    [[ "${_WIZARD_NEEDS_VENV:-}" == "true" ]] || return 0

    local project_dir="$1"
    local tekhton_home="$2"
    local conf_dir="$3"

    log "Setting up Python environment for enhanced features..."
    mkdir -p "${conf_dir}/logs" 2>/dev/null || true
    local setup_script="${tekhton_home}/tools/setup_indexer.sh"
    local venv_dir="${REPO_MAP_VENV_DIR:-.claude/indexer-venv}"
    local indexer_log="${conf_dir}/logs/indexer_setup.log"

    if [[ ! -f "$setup_script" ]]; then
        warn "setup_indexer.sh not found — run 'tekhton --setup-indexer' after init"
        return 0
    fi

    if ! _wizard_run_setup_script "Python environment" \
            "$setup_script" "$indexer_log" "$project_dir" "$venv_dir"; then
        warn "You can retry later with: tekhton --setup-indexer"
    fi

    if [[ "${_WIZARD_SERENA_ENABLED:-}" == "true" ]]; then
        local serena_script="${tekhton_home}/tools/setup_serena.sh"
        local serena_path="${SERENA_PATH:-.claude/serena}"
        if [[ -f "$serena_script" ]]; then
            if ! _wizard_run_setup_script "Serena LSP" \
                    "$serena_script" "$indexer_log" "$project_dir" "$serena_path"; then
                warn "You can retry later with: tekhton --setup-indexer --with-lsp"
            fi
        fi
    fi

    _INIT_FILES_WRITTEN+=(".claude/indexer-venv/|Python environment for enhanced features")
}
