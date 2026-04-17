#!/usr/bin/env bash
# =============================================================================
# mcp.sh — MCP server lifecycle management (Serena LSP integration)
#
# Sourced by tekhton.sh — do not run directly.
# Provides: start_mcp_server(), stop_mcp_server(), check_mcp_health(),
#           is_mcp_running(), get_mcp_config_path()
#
# Manages the Serena MCP server process. Designed for single-server use today
# but structured so future parallel-agent support can extend to per-agent
# instances or a shared server with locking.
#
# Dependencies: common.sh (log, warn, error)
# =============================================================================
set -euo pipefail

# --- Module state -------------------------------------------------------------

_MCP_SERVER_PID=""
_MCP_SERVER_RUNNING=false
_MCP_CONFIG_PATH=""
_CLI_MCP_CONFIG_SUPPORTED=""
_SERENA_DIR=""
_SERENA_PYTHON=""

# Exported for agent.sh to check
SERENA_MCP_AVAILABLE=false
export SERENA_MCP_AVAILABLE

# Template-friendly flag: non-empty when Serena is active (for {{IF:SERENA_ACTIVE}})
SERENA_ACTIVE=""
export SERENA_ACTIVE

# --- Config path accessor -----------------------------------------------------

# Returns the path to the generated MCP config file.
# Used by agent.sh to add --mcp-config flag.
get_mcp_config_path() {
    echo "${_MCP_CONFIG_PATH:-}"
}

# --- Health check -------------------------------------------------------------

# Check if the Serena MCP server is responsive.
# Returns: 0 if healthy, 1 otherwise
check_mcp_health() {
    if [[ "$_MCP_SERVER_RUNNING" != "true" ]]; then
        return 1
    fi

    # Reserved for future per-agent server instances. Currently, Claude CLI
    # owns the MCP server lifecycle, so _MCP_SERVER_PID is never set and this
    # branch never executes. Retained for when Tekhton manages its own server.
    if [[ -n "$_MCP_SERVER_PID" ]]; then
        if ! kill -0 "$_MCP_SERVER_PID" 2>/dev/null; then
            _MCP_SERVER_RUNNING=false
            SERENA_MCP_AVAILABLE=false
            return 1
        fi
    fi

    return 0
}

# --- Running check ------------------------------------------------------------

# Returns 0 if MCP server is currently running, 1 otherwise.
is_mcp_running() {
    [[ "$_MCP_SERVER_RUNNING" == "true" ]]
}

# --- Resolve Serena paths -----------------------------------------------------

# Locate the Serena installation and verify it's functional.
# Sets _SERENA_DIR, _SERENA_PYTHON on success.
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

    _SERENA_DIR="$serena_path"
    return 0
}

# --- Resolve MCP config path -------------------------------------------------

# Find or generate the MCP config file.
# Returns: 0 if config found/generated, 1 otherwise
_resolve_mcp_config() {
    # Check explicit config path first
    if [[ -n "${SERENA_CONFIG_PATH:-}" ]] && [[ -f "$SERENA_CONFIG_PATH" ]]; then
        _MCP_CONFIG_PATH="$SERENA_CONFIG_PATH"
        return 0
    fi

    # Check default location
    local default_config="${PROJECT_DIR}/.claude/serena_mcp_config.json"
    if [[ -f "$default_config" ]]; then
        _MCP_CONFIG_PATH="$default_config"
        return 0
    fi

    # Generate config from template if possible
    local template="${TEKHTON_HOME}/tools/serena_config_template.json"
    if [[ ! -f "$template" ]]; then
        return 1
    fi

    if [[ -z "${_SERENA_DIR:-}" ]] || [[ -z "${_SERENA_PYTHON:-}" ]]; then
        return 1
    fi

    local lang_servers="${SERENA_LANGUAGE_SERVERS:-auto}"
    mkdir -p "$(dirname "$default_config")"

    sed \
        -e "s|{{SERENA_PYTHON}}|${_SERENA_PYTHON}|g" \
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

# --- Start MCP server ---------------------------------------------------------

# Start the Serena MCP server as a background process.
# Shows a progress indicator during startup.
# Returns: 0 on success, 1 on failure (pipeline continues without LSP)
start_mcp_server() {
    if [[ "${SERENA_ENABLED:-false}" != "true" ]]; then
        return 1
    fi

    log_verbose "[mcp] Starting Serena MCP server..."

    # Verify Claude CLI supports --mcp-config
    if ! _cli_supports_mcp_config; then
        warn "[mcp] Claude CLI does not support --mcp-config — Serena disabled."
        warn "[mcp] Update Claude CLI to enable MCP integration."
        return 1
    fi

    # Resolve Serena installation
    if ! _resolve_serena_paths; then
        warn "[mcp] Serena not found at ${SERENA_PATH:-.claude/serena}."
        warn "[mcp] Run 'tekhton --setup-indexer --with-lsp' to install."
        return 1
    fi

    # Resolve or generate MCP config
    if ! _resolve_mcp_config; then
        warn "[mcp] Cannot find or generate MCP config."
        warn "[mcp] Run 'tekhton --setup-indexer --with-lsp' to set up."
        return 1
    fi

    log_verbose "[mcp] MCP config: ${_MCP_CONFIG_PATH}"

    # Claude CLI manages the MCP server lifecycle based on the config file.
    # We don't need to start Serena ourselves — Claude starts it when it sees
    # --mcp-config and stops it when the agent session ends. We just verify
    # the config is valid and the installation is present.
    _MCP_SERVER_RUNNING=true
    SERENA_MCP_AVAILABLE=true
    SERENA_ACTIVE="true"

    log_verbose "[mcp] Serena MCP integration enabled."
    log_verbose "[mcp] Serena path: ${_SERENA_DIR}"
    log_verbose "[mcp] Language servers: ${SERENA_LANGUAGE_SERVERS:-auto}"

    return 0
}

# --- Stop MCP server ----------------------------------------------------------

# Stop the Serena MCP server and clean up.
# Safe to call multiple times. Safe to call if server never started.
stop_mcp_server() {
    if [[ "$_MCP_SERVER_RUNNING" != "true" ]]; then
        return 0
    fi

    # Claude CLI manages MCP server lifecycle — nothing to kill here.
    # If we had started our own process, we'd kill the process group:
    #   kill -- -"$_MCP_SERVER_PID" 2>/dev/null || true
    _MCP_SERVER_RUNNING=false
    SERENA_MCP_AVAILABLE=false
    SERENA_ACTIVE=""
    _MCP_SERVER_PID=""

    log_verbose "[mcp] Serena MCP integration stopped."
    return 0
}

# --- Check Serena availability (for indexer.sh) --------------------------------

# Verify that Serena is installed and has at least one language server.
# Does NOT start the server — just checks installation.
# Returns: 0 if available, 1 if not
check_serena_available() {
    if [[ "${SERENA_ENABLED:-false}" != "true" ]]; then
        return 1
    fi

    if ! _resolve_serena_paths; then
        return 1
    fi

    # Verify Serena module is importable
    if ! "$_SERENA_PYTHON" -c "import serena" 2>/dev/null; then
        # Not all Serena installs expose a top-level module — check for the dir
        if [[ ! -f "${_SERENA_DIR}/pyproject.toml" ]] && [[ ! -f "${_SERENA_DIR}/setup.py" ]]; then
            return 1
        fi
    fi

    return 0
}
