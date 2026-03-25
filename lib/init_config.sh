#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# init_config.sh — Config generation helpers for Smart Init (Milestone 19)
#
# Sourced by init.sh — do not run directly.
# Depends on: common.sh (log, warn)
# =============================================================================

# Source sectioned config generator (Milestone 22)
_INIT_CONFIG_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib/init_config_sections.sh
source "${_INIT_CONFIG_DIR}/init_config_sections.sh"

# --- Config generation --------------------------------------------------------

# _generate_smart_config — Builds pipeline.conf from detection results.
# Args: $1 = project_dir, $2 = output_file,
#        $3 = languages, $4 = frameworks, $5 = commands, $6 = file_count
_generate_smart_config() {
    local project_dir="$1"
    local conf_file="$2"
    local languages="$3"
    local _frameworks="$4"
    local commands="$5"
    local file_count="${6:-0}"

    local project_name
    project_name=$(basename "$project_dir")

    # Extract detected commands by type (prefer highest confidence)
    local test_cmd analyze_cmd build_cmd
    local test_conf analyze_conf build_conf
    test_cmd=$(_best_command "$commands" "test")
    test_conf=$(_best_confidence "$commands" "test")
    analyze_cmd=$(_best_command "$commands" "analyze")
    analyze_conf=$(_best_confidence "$commands" "analyze")
    build_cmd=$(_best_command "$commands" "build")
    build_conf=$(_best_confidence "$commands" "build")

    # Detect required tools from languages
    local required_tools
    required_tools=$(_detect_required_tools "$languages")

    # Scale turns by project size
    local coder_turns jr_turns reviewer_turns tester_turns scout_turns
    local coder_model="claude-sonnet-4-6"
    if [[ "$file_count" -gt 200 ]]; then
        coder_turns=50; jr_turns=20; reviewer_turns=15; tester_turns=40; scout_turns=25
        coder_model="claude-opus-4-6"
    elif [[ "$file_count" -gt 50 ]]; then
        coder_turns=40; jr_turns=15; reviewer_turns=12; tester_turns=35; scout_turns=20
        coder_model="claude-opus-4-6"
    else
        coder_turns=35; jr_turns=15; reviewer_turns=10; tester_turns=30; scout_turns=20
    fi

    # Auto-detect DESIGN_FILE
    local design_file=""
    [[ -f "${project_dir}/DESIGN.md" ]] && design_file="DESIGN.md"

    # Milestone 12: Adjust model based on doc quality
    if [[ -n "${_INIT_DOC_QUALITY:-}" ]]; then
        local dq_score
        dq_score=$(echo "${_INIT_DOC_QUALITY}" | cut -d'|' -f1)
        # Low doc quality + large project → use opus for coder
        if [[ "${dq_score:-0}" -lt 30 ]] && [[ "$file_count" -gt 100 ]]; then
            coder_model="claude-opus-4-6"
        fi
        # High doc quality → sonnet sufficient
        if [[ "${dq_score:-0}" -gt 70 ]] && [[ "$coder_model" == "claude-opus-4-6" ]] && [[ "$file_count" -le 200 ]]; then
            coder_model="claude-sonnet-4-6"
        fi
    fi

    # Milestone 12: CI-detected command override
    if [[ -n "${_INIT_CI_CONFIG:-}" ]]; then
        local ci_test ci_build ci_lint
        ci_test=$(_extract_ci_command "${_INIT_CI_CONFIG}" "test")
        ci_build=$(_extract_ci_command "${_INIT_CI_CONFIG}" "build")
        ci_lint=$(_extract_ci_command "${_INIT_CI_CONFIG}" "lint")
        # CI overrides heuristic when heuristic confidence < high
        if [[ -n "$ci_test" ]] && [[ "$test_conf" != "high" ]]; then
            test_cmd="$ci_test"; test_conf="high"
        fi
        if [[ -n "$ci_build" ]] && [[ "$build_conf" != "high" ]]; then
            build_cmd="$ci_build"; build_conf="high"
        fi
        if [[ -n "$ci_lint" ]] && [[ "$analyze_conf" != "high" ]]; then
            analyze_cmd="$ci_lint"; analyze_conf="high"
        fi
    fi

    # Write config file (Milestone 22: sectioned format)
    generate_sectioned_config "$project_name" \
        "$test_cmd" "$test_conf" "$analyze_cmd" "$analyze_conf" \
        "$build_cmd" "$build_conf" "$coder_model" \
        "$coder_turns" "$jr_turns" "$reviewer_turns" \
        "$tester_turns" "$scout_turns" "$required_tools" \
        "$design_file" > "$conf_file"
}

# _extract_ci_command — Extracts a specific command type from CI detection output.
_extract_ci_command() {
    local ci_output="$1"
    local cmd_type="$2"
    local ci_sys build_cmd test_cmd lint_cmd
    while IFS='|' read -r ci_sys build_cmd test_cmd lint_cmd _rest; do
        [[ -z "$ci_sys" ]] && continue
        case "$cmd_type" in
            test)  [[ -n "$test_cmd" ]] && { echo "$test_cmd"; return 0; } ;;
            build) [[ -n "$build_cmd" ]] && { echo "$build_cmd"; return 0; } ;;
            lint)  [[ -n "$lint_cmd" ]] && { echo "$lint_cmd"; return 0; } ;;
        esac
    done <<< "$ci_output"
}

# --- Command extraction helpers -----------------------------------------------

# _best_command — Extracts the best command of a given type from detection output.
_best_command() {
    local commands="$1"
    local cmd_type="$2"
    [[ -z "$commands" ]] && return 0
    echo "$commands" | grep "^${cmd_type}|" | head -1 | cut -d'|' -f2 || true
}

# _best_confidence — Extracts the confidence of the best command of a given type.
_best_confidence() {
    local commands="$1"
    local cmd_type="$2"
    [[ -z "$commands" ]] && return 0
    echo "$commands" | grep "^${cmd_type}|" | head -1 | cut -d'|' -f4 || true
}

# --- Required tools detection -------------------------------------------------

_detect_required_tools() {
    local languages="$1"
    local tools="claude git"

    [[ -z "$languages" ]] && { echo "$tools"; return 0; }

    local lang
    while IFS='|' read -r lang _conf _manifest; do
        case "$lang" in
            typescript|javascript) tools="$tools node npm" ;;
            python)     tools="$tools python" ;;
            rust)       tools="$tools cargo" ;;
            go)         tools="$tools go" ;;
            ruby)       tools="$tools ruby" ;;
            dart)       tools="$tools dart" ;;
            java)       tools="$tools java" ;;
            kotlin)     tools="$tools java" ;;
            php)        tools="$tools php" ;;
            elixir)     tools="$tools elixir mix" ;;
            csharp)     tools="$tools dotnet" ;;
            swift)      tools="$tools swift" ;;
            haskell)    tools="$tools ghc" ;;
        esac
    done <<< "$languages"

    # Deduplicate
    echo "$tools" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# --- Reinit value preservation (Milestone 22) --------------------------------

# _preserve_user_config — Reads existing pipeline.conf and returns KEY=VALUE lines.
# Used by --reinit to preserve user-modified values after regenerating config.
# Args: $1 = existing config file path
# Output: lines of KEY=VALUE (only uncommented, active settings)
_preserve_user_config() {
    local conf_file="$1"
    [[ ! -f "$conf_file" ]] && return 0
    # Extract active KEY=VALUE lines (skip comments, empty lines, section headers)
    grep -E '^[A-Z_]+=.' "$conf_file" || true
}

# _merge_preserved_values — Merges user-preserved values into a new config file.
# Reads the new config, replaces matching keys with user values, writes result.
# Args: $1 = config file to update, $2 = preserved values (newline-separated KEY=VALUE)
_merge_preserved_values() {
    local conf_file="$1"
    local preserved="$2"
    [[ -z "$preserved" ]] && return 0
    [[ ! -f "$conf_file" ]] && return 0

    # Build associative array of preserved key=value pairs
    local -A _preserved_map=()
    local key val kv_line
    while IFS= read -r kv_line; do
        [[ -z "$kv_line" ]] && continue
        key="${kv_line%%=*}"
        val="${kv_line#*=}"
        [[ -z "$key" ]] && continue
        _preserved_map["$key"]="$val"
    done <<< "$preserved"

    # Rewrite config line-by-line, replacing matching keys.
    # Pure bash avoids sed delimiter/backreference issues with | and & in values.
    local tmpfile="${conf_file}.merge.$$"
    local line line_key
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Match active KEY=... lines (not comments)
        if [[ "$line" =~ ^([A-Z_]+)= ]]; then
            line_key="${BASH_REMATCH[1]}"
            if [[ -n "${_preserved_map[$line_key]+x}" ]]; then
                echo "${line_key}=${_preserved_map[$line_key]}"
                continue
            fi
        fi
        echo "$line"
    done < "$conf_file" > "$tmpfile"

    mv "$tmpfile" "$conf_file"
}

# --- Config file section emitters --------------------------------------------

_emit_header() {
    local project_name="$1"
    # Compute config version watermark from running Tekhton version (MAJOR.MINOR only)
    local config_version="${TEKHTON_VERSION%.*}"
    config_version="${config_version:-3.0}"
    cat << EOF
# =============================================================================
# pipeline.conf — Auto-generated by tekhton --init (Smart Init)
#
# Review all values below. Lines marked # VERIFY: were detected with medium
# confidence — double-check before your first pipeline run.
# Lines marked # SUGGESTION: were detected with low confidence.
# =============================================================================

# --- Tekhton config version (do not edit manually) ---------------------------
TEKHTON_CONFIG_VERSION="${config_version}"

# --- Project identity --------------------------------------------------------
PROJECT_NAME="${project_name}"
PROJECT_DESCRIPTION="(fill in a one-line description)"

EOF
}

_emit_tools() {
    local required_tools="$1"
    cat << EOF
# --- Required CLI tools (auto-detected) --------------------------------------
REQUIRED_TOOLS="${required_tools}"

EOF
}

_emit_models() {
    local coder_model="$1"
    cat << EOF
# --- Agent models ------------------------------------------------------------
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
CLAUDE_CODER_MODEL="${coder_model}"
CLAUDE_JR_CODER_MODEL="claude-haiku-4-5"
CLAUDE_SCOUT_MODEL="claude-haiku-4-5"
CLAUDE_REVIEWER_MODEL="claude-sonnet-4-6"
CLAUDE_ARCHITECT_MODEL="claude-sonnet-4-6"
CLAUDE_TESTER_MODEL="claude-haiku-4-5"

EOF
}

_emit_turns() {
    local coder="$1" jr="$2" reviewer="$3" tester="$4" scout="$5"
    cat << EOF
# --- Turn limits (scaled by project size) ------------------------------------
CODER_MAX_TURNS=${coder}
JR_CODER_MAX_TURNS=${jr}
REVIEWER_MAX_TURNS=${reviewer}
TESTER_MAX_TURNS=${tester}
SCOUT_MAX_TURNS=${scout}
MAX_REVIEW_CYCLES=2

EOF
}

_emit_commands() {
    local test_cmd="$1" test_conf="$2"
    local analyze_cmd="$3" analyze_conf="$4"
    local build_cmd="$5" build_conf="$6"

    echo "# --- Build / test / analyze commands ----------------------------------------"

    # TEST_CMD
    if [[ -n "$test_cmd" ]]; then
        _emit_command_line "TEST_CMD" "$test_cmd" "$test_conf"
    else
        echo '# No test command detected — set manually:'
        echo 'TEST_CMD="true"'
    fi

    # ANALYZE_CMD
    if [[ -n "$analyze_cmd" ]]; then
        _emit_command_line "ANALYZE_CMD" "$analyze_cmd" "$analyze_conf"
    else
        echo '# No analyze command detected — set manually:'
        echo "ANALYZE_CMD=\"echo 'No analyze command configured'\""
    fi

    # BUILD_CHECK_CMD
    if [[ -n "$build_cmd" ]]; then
        _emit_command_line "BUILD_CHECK_CMD" "$build_cmd" "$build_conf"
    else
        echo 'BUILD_CHECK_CMD=""'
    fi

    echo
}

# _emit_command_line — Emits a config line with confidence annotation.
_emit_command_line() {
    local key="$1"
    local cmd="$2"
    local conf="$3"

    case "$conf" in
        high)
            echo "${key}=\"${cmd}\""
            ;;
        medium)
            echo "# VERIFY: detected with medium confidence"
            echo "${key}=\"${cmd}\""
            ;;
        low)
            echo "# SUGGESTION: detected with low confidence — uncomment if correct"
            echo "# ${key}=\"${cmd}\""
            echo "${key}=\"true\""
            ;;
        *)
            echo "${key}=\"${cmd}\""
            ;;
    esac
}

# _emit_workspace_config — Emits workspace/service/structure config (Milestone 12).
_emit_workspace_config() {
    local workspaces="${_INIT_WORKSPACES:-}"
    local services="${_INIT_SERVICES:-}"
    local workspace_scope="${_INIT_WORKSPACE_SCOPE:-}"

    # Determine project structure
    local project_structure="single"
    if [[ -n "$workspaces" ]]; then
        project_structure="monorepo"
    elif [[ -n "$services" ]]; then
        local svc_count
        svc_count=$(echo "$services" | grep -c '.' || echo "0")
        [[ "$svc_count" -gt 1 ]] && project_structure="multi-service"
    fi

    cat << EOF
# --- Project structure (Milestone 12) ----------------------------------------
PROJECT_STRUCTURE="${project_structure}"
EOF

    if [[ -n "$workspaces" ]]; then
        local ws_type
        ws_type=$(echo "$workspaces" | head -1 | cut -d'|' -f1)
        local ws_subs
        ws_subs=$(echo "$workspaces" | head -1 | cut -d'|' -f3)
        cat << EOF
WORKSPACE_TYPE="${ws_type}"
# WORKSPACE_SUBPROJECTS="${ws_subs}"
EOF
        if [[ -n "$workspace_scope" ]] && [[ "$workspace_scope" != "root" ]]; then
            cat << EOF
# Scoped to subproject: ${workspace_scope}
# WORKSPACE_SCOPE="${workspace_scope}"
EOF
        fi
    fi

    if [[ -n "$services" ]]; then
        echo "# Detected services:"
        while IFS='|' read -r name dir tech source; do
            [[ -z "$name" ]] && continue
            echo "# SERVICE: ${name} → ${dir} (${tech}, detected from ${source})"
        done <<< "$services"
    fi
    echo ""
}

_emit_paths() {
    local design_file="${1:-}"
    cat << EOF
# --- Pipeline file paths -----------------------------------------------------
PIPELINE_STATE_FILE=".claude/PIPELINE_STATE.md"
LOG_DIR=".claude/logs"

# --- Agent role files --------------------------------------------------------
CODER_ROLE_FILE=".claude/agents/coder.md"
REVIEWER_ROLE_FILE=".claude/agents/reviewer.md"
TESTER_ROLE_FILE=".claude/agents/tester.md"
JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"
ARCHITECT_ROLE_FILE=".claude/agents/architect.md"

# --- Context files -----------------------------------------------------------
ARCHITECTURE_FILE=""
PROJECT_RULES_FILE="CLAUDE.md"
DESIGN_FILE="${design_file}"

# --- Drift detection ---------------------------------------------------------
DRIFT_LOG_FILE="DRIFT_LOG.md"
ARCHITECTURE_LOG_FILE="ARCHITECTURE_LOG.md"
HUMAN_ACTION_FILE="HUMAN_ACTION_REQUIRED.md"
DRIFT_OBSERVATION_THRESHOLD=8
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=5
NON_BLOCKING_LOG_FILE="NON_BLOCKING_LOG.md"

# --- Dynamic turns -----------------------------------------------------------
DYNAMIC_TURNS_ENABLED=true

# --- Context budget ----------------------------------------------------------
CONTEXT_BUDGET_ENABLED=true
CONTEXT_BUDGET_PCT=50
CHARS_PER_TOKEN=4
EOF
}
