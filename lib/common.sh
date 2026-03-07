#!/usr/bin/env bash
# =============================================================================
# common.sh — Shared color codes, logging utilities, and prerequisite checks
#
# Sourced by tekhton.sh — do not run directly.
# =============================================================================

# --- Terminal colors ---------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Logging -----------------------------------------------------------------

log()    { echo -e "${CYAN}[tekhton]${NC} $*"; }
success(){ echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
error()  { echo -e "${RED}[✗]${NC} $*"; }
header() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $*${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}\n"; }

# --- Prerequisite check ------------------------------------------------------

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { error "Required command not found: $1"; exit 1; }
}
