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
# Resolver / probe / config-shape helpers live in mcp_resolve.sh and are
# sourced below so all callers of mcp.sh pick them up transitively.
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
_SERENA_BIN=""

# Exported for agent.sh to check
SERENA_MCP_AVAILABLE=false
export SERENA_MCP_AVAILABLE

# Template-friendly flag: non-empty when Serena is active (for {{IF:SERENA_ACTIVE}})
SERENA_ACTIVE=""
export SERENA_ACTIVE

# --- Resolver helpers ---------------------------------------------------------

# shellcheck source=lib/mcp_resolve.sh
source "$(dirname "${BASH_SOURCE[0]}")/mcp_resolve.sh"

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

    # Probe that the resolved binary actually launches before declaring success.
    # A pass here doesn't guarantee runtime MCP behavior, but a fail here
    # guarantees runtime MCP failure — cheap pre-flight catch.
    if ! _probe_serena_startup; then
        warn "[mcp] Serena startup probe failed (binary: ${_SERENA_BIN:-unresolved})."
        warn "[mcp] Continuing without LSP-backed tools."
        SERENA_MCP_AVAILABLE=false
        SERENA_ACTIVE=""
        return 1
    fi

    # Claude CLI manages the MCP server lifecycle based on the config file.
    # We don't need to start Serena ourselves — Claude starts it when it sees
    # --mcp-config and stops it when the agent session ends. We just verify
    # the config is valid and the installation is present.
    _MCP_SERVER_RUNNING=true
    SERENA_MCP_AVAILABLE=true
    SERENA_ACTIVE="true"

    log_verbose "[mcp] Serena MCP integration enabled (probe passed)."
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
