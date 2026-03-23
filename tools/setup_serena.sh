#!/usr/bin/env bash
# =============================================================================
# setup_serena.sh — Install Serena MCP server and detect language servers
#
# Standalone setup script invoked by `tekhton --setup-indexer --with-lsp`.
# Idempotent — safe to re-run. Clones/updates Serena into .claude/serena/
# and generates MCP configuration for Claude CLI.
#
# Usage:
#   bash tools/setup_serena.sh <project_dir> [serena_path]
#
# Arguments:
#   project_dir  Target project directory (required)
#   serena_path  Serena installation directory (default: .claude/serena)
#
# Requirements:
#   - Python 3.8+ on PATH
#   - git on PATH
#   - pip (bundled with Python)
# =============================================================================
set -euo pipefail

# --- Configuration -----------------------------------------------------------

SERENA_REPO="https://github.com/oraios/serena.git"
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=8

# --- Colors (if stdout is a terminal) ----------------------------------------

if [ -t 1 ]; then
    _GREEN='\033[0;32m'
    _YELLOW='\033[0;33m'
    _RED='\033[0;31m'
    _CYAN='\033[0;36m'
    _RESET='\033[0m'
else
    _GREEN='' _YELLOW='' _RED='' _CYAN='' _RESET=''
fi

_log()     { echo -e "${_GREEN}[serena]${_RESET} $*"; }
_warn()    { echo -e "${_YELLOW}[serena]${_RESET} $*" >&2; }
_error()   { echo -e "${_RED}[serena]${_RESET} $*" >&2; }

# --- Resolve arguments -------------------------------------------------------

if [ $# -lt 1 ]; then
    _error "Usage: setup_serena.sh <project_dir> [serena_path]"
    exit 1
fi

PROJECT_DIR="$1"
SERENA_REL_PATH="${2:-.claude/serena}"
SERENA_DIR="${PROJECT_DIR}/${SERENA_REL_PATH}"

# --- Locate Python 3 ---------------------------------------------------------

find_python3() {
    local cmd
    for cmd in python3 python; do
        if command -v "$cmd" &>/dev/null; then
            local ver
            ver=$("$cmd" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null) || continue
            local major minor
            major="${ver%%.*}"
            minor="${ver#*.}"
            if [[ "$major" -ge "$MIN_PYTHON_MAJOR" ]] && [[ "$minor" -ge "$MIN_PYTHON_MINOR" ]]; then
                echo "$cmd"
                return 0
            fi
        fi
    done
    return 1
}

PYTHON_CMD=""
if ! PYTHON_CMD=$(find_python3); then
    _error "Python ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}+ is required but not found on PATH."
    exit 1
fi

_log "Found Python at $(command -v "$PYTHON_CMD")"

# --- Require git --------------------------------------------------------------

if ! command -v git &>/dev/null; then
    _error "git is required but not found on PATH."
    exit 1
fi

# --- Clone or update Serena ---------------------------------------------------

if [ -d "$SERENA_DIR" ]; then
    if [ -d "${SERENA_DIR}/.git" ]; then
        _log "Serena already installed at ${SERENA_DIR} — updating..."
        if ! git -C "$SERENA_DIR" pull --quiet 2>/dev/null; then
            _warn "git pull failed (non-fatal) — using existing version."
        fi
    else
        _warn "Directory ${SERENA_DIR} exists but is not a git repo."
        _warn "Remove it and re-run to reinstall: rm -rf ${SERENA_DIR}"
        # Continue with existing install
    fi
else
    _log "Cloning Serena into ${SERENA_DIR}..."
    mkdir -p "$(dirname "$SERENA_DIR")"
    if ! git clone --quiet --depth 1 "$SERENA_REPO" "$SERENA_DIR"; then
        _error "Failed to clone Serena from ${SERENA_REPO}"
        exit 1
    fi
    _log "Serena cloned successfully."
fi

# --- Create virtualenv inside Serena dir if needed ----------------------------

SERENA_VENV="${SERENA_DIR}/.venv"
if [ ! -d "$SERENA_VENV" ]; then
    _log "Creating virtualenv at ${SERENA_VENV}..."
    "$PYTHON_CMD" -m venv "$SERENA_VENV"
fi

# Locate venv Python
if [ -f "${SERENA_VENV}/bin/python" ]; then
    SERENA_PYTHON="${SERENA_VENV}/bin/python"
elif [ -f "${SERENA_VENV}/Scripts/python.exe" ]; then
    SERENA_PYTHON="${SERENA_VENV}/Scripts/python.exe"
else
    _error "Cannot locate Python in Serena virtualenv."
    exit 1
fi

# --- Install Serena dependencies ---------------------------------------------

_log "Installing Serena dependencies..."
if [ -f "${SERENA_DIR}/requirements.txt" ]; then
    "$SERENA_PYTHON" -m pip install --quiet -r "${SERENA_DIR}/requirements.txt" 2>/dev/null || {
        _warn "pip install from requirements.txt failed — trying setup.py/pyproject.toml..."
    }
fi

# Try pip install -e . for editable install (covers pyproject.toml and setup.py)
if [ -f "${SERENA_DIR}/pyproject.toml" ] || [ -f "${SERENA_DIR}/setup.py" ]; then
    "$SERENA_PYTHON" -m pip install --quiet -e "$SERENA_DIR" 2>/dev/null || {
        _warn "Editable install failed — Serena may not be fully functional."
    }
fi

# --- Detect available language servers ----------------------------------------

_log "Detecting available language servers..."

detected_servers=""
detected_count=0

# Python: pyright or pylsp
if command -v pyright &>/dev/null; then
    _log "  Found: pyright (Python)"
    detected_servers="${detected_servers:+${detected_servers},}pyright"
    detected_count=$((detected_count + 1))
elif command -v pylsp &>/dev/null; then
    _log "  Found: pylsp (Python)"
    detected_servers="${detected_servers:+${detected_servers},}pylsp"
    detected_count=$((detected_count + 1))
fi

# TypeScript/JavaScript: typescript-language-server
if command -v typescript-language-server &>/dev/null; then
    _log "  Found: typescript-language-server (TypeScript/JavaScript)"
    detected_servers="${detected_servers:+${detected_servers},}typescript-language-server"
    detected_count=$((detected_count + 1))
fi

# Go: gopls
if command -v gopls &>/dev/null; then
    _log "  Found: gopls (Go)"
    detected_servers="${detected_servers:+${detected_servers},}gopls"
    detected_count=$((detected_count + 1))
fi

# Rust: rust-analyzer
if command -v rust-analyzer &>/dev/null; then
    _log "  Found: rust-analyzer (Rust)"
    detected_servers="${detected_servers:+${detected_servers},}rust-analyzer"
    detected_count=$((detected_count + 1))
fi

# Java: jdtls
if command -v jdtls &>/dev/null; then
    _log "  Found: jdtls (Java)"
    detected_servers="${detected_servers:+${detected_servers},}jdtls"
    detected_count=$((detected_count + 1))
fi

# C/C++: clangd
if command -v clangd &>/dev/null; then
    _log "  Found: clangd (C/C++)"
    detected_servers="${detected_servers:+${detected_servers},}clangd"
    detected_count=$((detected_count + 1))
fi

# Ruby: solargraph
if command -v solargraph &>/dev/null; then
    _log "  Found: solargraph (Ruby)"
    detected_servers="${detected_servers:+${detected_servers},}solargraph"
    detected_count=$((detected_count + 1))
fi

if [ "$detected_count" -eq 0 ]; then
    _warn "No language servers detected on PATH."
    _warn "Serena will have limited functionality without language servers."
    _warn "Install one for your project's language (e.g., 'pip install pyright' for Python)."
    detected_servers="none"
else
    _log "Detected ${detected_count} language server(s): ${detected_servers}"
fi

# --- Generate MCP config from template ---------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/serena_config_template.json"
CONFIG_OUTPUT="${PROJECT_DIR}/.claude/serena_mcp_config.json"

if [ ! -f "$TEMPLATE_FILE" ]; then
    _error "Config template not found at ${TEMPLATE_FILE}"
    exit 1
fi

_log "Generating MCP config at ${CONFIG_OUTPUT}..."
mkdir -p "$(dirname "$CONFIG_OUTPUT")"

# Perform template substitution
sed \
    -e "s|{{SERENA_PYTHON}}|${SERENA_PYTHON}|g" \
    -e "s|{{PROJECT_DIR}}|${PROJECT_DIR}|g" \
    -e "s|{{SERENA_PATH}}|${SERENA_DIR}|g" \
    -e "s|{{LANGUAGE_SERVERS}}|${detected_servers}|g" \
    "$TEMPLATE_FILE" > "$CONFIG_OUTPUT"

_log "MCP config written to ${CONFIG_OUTPUT}"

# --- Summary ------------------------------------------------------------------

_log ""
_log "Serena setup complete."
_log "  Installation: ${SERENA_DIR}"
_log "  MCP config:   ${CONFIG_OUTPUT}"
_log "  Language servers: ${detected_servers}"
_log ""
_log "Enable in your pipeline.conf:"
_log "  SERENA_ENABLED=true"
if [ "$detected_servers" != "none" ]; then
    _log "  SERENA_LANGUAGE_SERVERS=\"${detected_servers}\""
fi
_log ""

# --- Ensure .gitignore covers Serena dir --------------------------------------

GITIGNORE_FILE="${PROJECT_DIR}/.gitignore"
if [ -f "$GITIGNORE_FILE" ]; then
    if ! grep -qF "$SERENA_REL_PATH" "$GITIGNORE_FILE" 2>/dev/null; then
        _warn "${SERENA_REL_PATH}/ is not in .gitignore — consider adding it."
    fi
elif [ -d "${PROJECT_DIR}/.git" ]; then
    _warn "No .gitignore found. Consider creating one with ${SERENA_REL_PATH}/ in it."
fi
