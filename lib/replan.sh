#!/usr/bin/env bash
# =============================================================================
# replan.sh — Shim that sources both mid-run and brownfield replan modules.
#
# Split into replan_midrun.sh and replan_brownfield.sh for maintainability.
# This file preserves the single-source interface for tekhton.sh and tests.
# =============================================================================

# Shared config defaults used by both modules
export REPLAN_MODEL="${REPLAN_MODEL:-${PLAN_GENERATION_MODEL:-opus}}"
export REPLAN_MAX_TURNS="${REPLAN_MAX_TURNS:-${PLAN_GENERATION_MAX_TURNS:-50}}"

_REPLAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/replan_midrun.sh
source "${_REPLAN_DIR}/replan_midrun.sh"

# shellcheck source=lib/replan_brownfield.sh
source "${_REPLAN_DIR}/replan_brownfield.sh"
