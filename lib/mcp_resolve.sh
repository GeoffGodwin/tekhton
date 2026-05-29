#!/usr/bin/env bash
# =============================================================================
# mcp_resolve.sh — Serena path / config / probe resolvers for mcp.sh
#
# Sourced by mcp.sh — do not run directly.
# Provides: _resolve_serena_paths(), _probe_serena_startup(),
#           _is_stale_serena_config(), _resolve_mcp_config(),
#           _cli_supports_mcp_config()
#
# Extracted from mcp.sh to stay under the 300-line ceiling.
#
# Dependencies: common.sh (log_verbose), python3 (for stale-config detect)
# =============================================================================
set -euo pipefail

# --- Resolve Serena paths -----------------------------------------------------

# Locate the Serena installation and verify it's functional.
# Sets _SERENA_DIR, _SERENA_PYTHON, _SERENA_BIN on success.
# Returns: 0 if found, 1 if not
_resolve_serena_paths() {
    local serena_path="${SERENA_PATH:-.claude/serena}"
    if [[ "$serena_path" != /* ]]; then
        serena_path="${PROJECT_DIR}/${serena_path}"
    fi

    if [[ ! -d "$serena_path" ]]; then
        return 1
    fi

    # Locate venv Python inside Serena
    local venv_dir="${serena_path}/.venv"
    if [[ -f "${venv_dir}/bin/python" ]]; then
        _SERENA_PYTHON="${venv_dir}/bin/python"
    elif [[ -f "${venv_dir}/Scripts/python.exe" ]]; then
        _SERENA_PYTHON="${venv_dir}/Scripts/python.exe"
    else
        return 1
    fi

    # Resolve the console-script entrypoint. Serena's package ships no
    # __main__, so `python -m serena` fails at import time; the binary is
    # the only supported invocation surface.
    if [[ -f "${venv_dir}/bin/serena" ]]; then
        _SERENA_BIN="${venv_dir}/bin/serena"
    elif [[ -f "${venv_dir}/Scripts/serena.exe" ]]; then
        _SERENA_BIN="${venv_dir}/Scripts/serena.exe"
    else
        return 1
    fi

    _SERENA_DIR="$serena_path"
    return 0
}

# --- Probe Serena startup -----------------------------------------------------

# Verify the resolved Serena binary can launch its MCP server.
# Runs `serena start-mcp-server --help` with a 2-second timeout.
# Returns: 0 on success (exit 0 within budget), 1 on any failure.
_probe_serena_startup() {
    if [[ -z "${_SERENA_BIN:-}" ]]; then
        return 1
    fi
    if ! timeout 2 "$_SERENA_BIN" start-mcp-server --help >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# --- Detect pre-m28.1 stale Serena config ------------------------------------

# Returns 0 if the config at $1 matches the pre-m28.1 broken shape
# (`"args": ["-m", "serena", ...]`). Returns 1 for any other shape,
# including a non-existent file or a parse failure.
#
# Match is intentionally narrow: must have args[0]=="-m" && args[1]=="serena".
# A user with a custom MCP config that happens to name a server "serena"
# but uses a different command/args layout is not affected.
_is_stale_serena_config() {
    local config="$1"
    [[ -f "$config" ]] || return 1
    python3 - "$config" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        cfg = json.load(fh)
    args = cfg.get("mcpServers", {}).get("serena", {}).get("args", [])
    sys.exit(0 if (len(args) >= 2 and args[0] == "-m" and args[1] == "serena") else 1)
except Exception:
    sys.exit(1)
PY
}

# --- Resolve MCP config path -------------------------------------------------

# Find or generate the MCP config file.
# Returns: 0 if config found/generated, 1 otherwise
_resolve_mcp_config() {
    # Check explicit config path first
    if [[ -n "${SERENA_CONFIG_PATH:-}" ]] && [[ -f "${SERENA_CONFIG_PATH:-}" ]]; then
        _MCP_CONFIG_PATH="${SERENA_CONFIG_PATH:-}"
        return 0
    fi

    # Check default location
    local default_config="${PROJECT_DIR}/.claude/serena_mcp_config.json"
    if [[ -f "$default_config" ]]; then
        if _is_stale_serena_config "$default_config"; then
            local backup
            backup="${default_config}.bak.$(date +%Y%m%d%H%M%S)"
            cp "$default_config" "$backup"
            log_verbose "[mcp] Stale Serena config detected — backed up to ${backup}, regenerating."
            rm "$default_config"
            # Fall through to template-generation block below.
        else
            _MCP_CONFIG_PATH="$default_config"
            return 0
        fi
    fi

    # Generate config from template if possible
    local template="${TEKHTON_HOME}/tools/serena_config_template.json"
    if [[ ! -f "$template" ]]; then
        return 1
    fi

    if [[ -z "${_SERENA_DIR:-}" ]] || [[ -z "${_SERENA_BIN:-}" ]]; then
        return 1
    fi

    local lang_servers="${SERENA_LANGUAGE_SERVERS:-auto}"
    mkdir -p "$(dirname "$default_config")"

    sed \
        -e "s|{{SERENA_BIN}}|${_SERENA_BIN}|g" \
        -e "s|{{PROJECT_DIR}}|${PROJECT_DIR}|g" \
        -e "s|{{SERENA_PATH}}|${_SERENA_DIR}|g" \
        -e "s|{{LANGUAGE_SERVERS}}|${lang_servers}|g" \
        "$template" > "$default_config"

    _MCP_CONFIG_PATH="$default_config"
    return 0
}

# --- Detect --mcp-config support in Claude CLI --------------------------------

# Check if the installed Claude CLI supports --mcp-config.
# Returns: 0 if supported, 1 otherwise
_cli_supports_mcp_config() {
    # Cache the result — CLI version doesn't change mid-run
    if [[ "$_CLI_MCP_CONFIG_SUPPORTED" == "1" ]]; then
        return 0
    elif [[ "$_CLI_MCP_CONFIG_SUPPORTED" == "0" ]]; then
        return 1
    fi

    if claude --help 2>/dev/null | grep -q "\-\-mcp-config"; then
        _CLI_MCP_CONFIG_SUPPORTED="1"
        return 0
    fi
    _CLI_MCP_CONFIG_SUPPORTED="0"
    return 1
}
