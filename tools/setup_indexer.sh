#!/usr/bin/env bash
# =============================================================================
# setup_indexer.sh — Create virtualenv and install tree-sitter dependencies
#
# Standalone setup script invoked by `tekhton --setup-indexer`.
# Idempotent — safe to re-run. Creates .claude/indexer-venv/ in PROJECT_DIR.
#
# Usage:
#   bash tools/setup_indexer.sh [project_dir]
#
# Arguments:
#   project_dir  Target project directory (default: current working directory)
#
# Requirements:
#   - Python 3.8+ on PATH (as python3 or python)
# =============================================================================
set -euo pipefail

# --- Configuration -----------------------------------------------------------

VENV_DIR_NAME="${2:-.claude/indexer-venv}"
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=8

# --- Colors (if stdout is a terminal) ----------------------------------------

if [ -t 1 ]; then
    _GREEN='\033[0;32m'
    _YELLOW='\033[0;33m'
    _RED='\033[0;31m'
    _RESET='\033[0m'
else
    _GREEN='' _YELLOW='' _RED='' _RESET=''
fi

_log()     { echo -e "${_GREEN}[indexer]${_RESET} $*"; }
_warn()    { echo -e "${_YELLOW}[indexer]${_RESET} $*" >&2; }
_error()   { echo -e "${_RED}[indexer]${_RESET} $*" >&2; }

# --- Resolve project directory ------------------------------------------------

PROJECT_DIR="${1:-$(pwd)}"
VENV_DIR="${PROJECT_DIR}/${VENV_DIR_NAME}"

# --- Locate Python 3 ---------------------------------------------------------

find_python3() {
    local cmd
    for cmd in python3 python; do
        if command -v "$cmd" &>/dev/null; then
            # Verify it's actually Python 3
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
    _error "Install Python and ensure 'python3' or 'python' is available."
    exit 1
fi

PYTHON_VERSION=$("$PYTHON_CMD" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')")
_log "Found Python ${PYTHON_VERSION} at $(command -v "$PYTHON_CMD")"

# --- Create or verify virtualenv ---------------------------------------------

if [ -d "$VENV_DIR" ]; then
    _log "Virtualenv already exists at ${VENV_DIR}"
    # Verify it's functional
    if [ -f "${VENV_DIR}/bin/python" ] || [ -f "${VENV_DIR}/Scripts/python.exe" ]; then
        _log "Virtualenv appears functional — upgrading pip and dependencies."
    else
        _warn "Virtualenv appears broken — recreating."
        rm -rf "$VENV_DIR"
    fi
fi

if [ ! -d "$VENV_DIR" ]; then
    _log "Creating virtualenv at ${VENV_DIR}..."
    "$PYTHON_CMD" -m venv "$VENV_DIR"
    _log "Virtualenv created."
fi

# --- Locate pip inside the venv -----------------------------------------------

if [ -f "${VENV_DIR}/bin/pip" ]; then
    VENV_PIP="${VENV_DIR}/bin/pip"
    VENV_PYTHON="${VENV_DIR}/bin/python"
elif [ -f "${VENV_DIR}/Scripts/pip.exe" ]; then
    VENV_PIP="${VENV_DIR}/Scripts/pip.exe"
    VENV_PYTHON="${VENV_DIR}/Scripts/python.exe"
else
    _error "Cannot locate pip inside the virtualenv at ${VENV_DIR}."
    _error "Try deleting ${VENV_DIR} and re-running this script."
    exit 1
fi

# --- Upgrade pip --------------------------------------------------------------

_log "Upgrading pip..."
"$VENV_PYTHON" -m pip install --upgrade pip --quiet 2>/dev/null || {
    _warn "pip upgrade failed (non-fatal) — continuing with existing pip."
}

# --- Install requirements from tools/requirements.txt -----------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"

if [ -f "$REQUIREMENTS_FILE" ]; then
    _log "Installing dependencies from ${REQUIREMENTS_FILE}..."
    "$VENV_PIP" install --quiet -r "$REQUIREMENTS_FILE" 2>&1 | while IFS= read -r line; do
        # Show only non-empty, non-"already satisfied" lines
        if [[ -n "$line" ]] && ! [[ "$line" == *"already satisfied"* ]]; then
            _log "  $line"
        fi
    done
    _log "Core dependencies installed."
else
    _warn "requirements.txt not found at ${REQUIREMENTS_FILE} — skipping dependency install."
fi

# --- Install tree-sitter language grammars -----------------------------------
# Individual grammars may fail on some platforms — install each independently
# so one failure doesn't block the rest.

_log "Installing tree-sitter language grammars..."

# Core languages supported by tree-sitter
GRAMMARS=(
    "tree-sitter-python"
    "tree-sitter-javascript"
    "tree-sitter-typescript"
    "tree-sitter-go"
    "tree-sitter-rust"
    "tree-sitter-java"
    "tree-sitter-c"
    "tree-sitter-cpp"
    "tree-sitter-ruby"
    "tree-sitter-bash"
)

installed_count=0
failed_count=0

for grammar in "${GRAMMARS[@]}"; do
    if "$VENV_PIP" install --quiet "$grammar" 2>/dev/null; then
        installed_count=$((installed_count + 1))
    else
        _warn "  Failed to install ${grammar} (platform may not be supported)"
        failed_count=$((failed_count + 1))
    fi
done

_log "Grammars installed: ${installed_count}/${#GRAMMARS[@]}"
if [ "$failed_count" -gt 0 ]; then
    _warn "${failed_count} grammar(s) failed — indexing will skip those languages."
fi

# --- Verify installation ------------------------------------------------------

_log "Verifying installation..."

verify_ok=true

if ! "$VENV_PYTHON" -c "import tree_sitter" 2>/dev/null; then
    _error "tree-sitter Python package not found in virtualenv."
    verify_ok=false
fi

if ! "$VENV_PYTHON" -c "import networkx" 2>/dev/null; then
    _error "networkx package not found in virtualenv."
    verify_ok=false
fi

if [ "$verify_ok" = true ]; then
    _log "Verification passed — indexer is ready."
    _log ""
    _log "Enable in your pipeline.conf:"
    _log "  REPO_MAP_ENABLED=true"
    _log ""
    _log "Virtualenv location: ${VENV_DIR}"
    _log "To remove: rm -rf ${VENV_DIR}"
else
    _error "Verification failed. Check the errors above."
    exit 1
fi

# --- Ensure .gitignore covers the venv ---------------------------------------

GITIGNORE_FILE="${PROJECT_DIR}/.gitignore"
if [ -f "$GITIGNORE_FILE" ]; then
    if ! grep -qF "$VENV_DIR_NAME" "$GITIGNORE_FILE" 2>/dev/null; then
        _warn "${VENV_DIR_NAME}/ is not in .gitignore — consider adding it."
    fi
elif [ -d "${PROJECT_DIR}/.git" ]; then
    _warn "No .gitignore found. Consider creating one with ${VENV_DIR_NAME}/ in it."
fi
