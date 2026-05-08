#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# orchestrate.sh — Outer orchestration loop wedge shim.
#
# m12 carved this file down to a thin source-only shim. m19 rewires it to
# point at the renamed sibling files (`orchestrate_complete.sh`,
# `orchestrate_save.sh`) and removes the orchestrate_main.sh / orchestrate_state.sh
# entries since those files were deleted by the m19 wedge cutover.
#
# The Go runner (internal/runner.RunCompleteLoop) is the canonical owner of
# the outer retry loop. The bash bodies in orchestrate_complete.sh and
# orchestrate_save.sh exist only because tekhton.sh has not been flipped to
# dispatch through `tekhton run --complete` yet — m20 owns that cutover.
#
# Sourced by tekhton.sh — do not run directly.
#
# Loaded module map:
#   orchestrate_classify.sh   — _classify_failure + cause/diagnose helpers
#   orchestrate_aux.sh        — auto-advance, escalation, smart resume, save shim
#   orchestrate_preflight.sh  — pre-finalization fix retry
#   orchestrate_iteration.sh  — _handle_pipeline_success / _handle_pipeline_failure
#   orchestrate_complete.sh   — _orch_complete_run + orchestration globals
# =============================================================================

# shellcheck source=lib/orchestrate_classify.sh
source "$(dirname "${BASH_SOURCE[0]}")/orchestrate_classify.sh"

# shellcheck source=lib/orchestrate_aux.sh
source "$(dirname "${BASH_SOURCE[0]}")/orchestrate_aux.sh"

# shellcheck source=lib/orchestrate_preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/orchestrate_preflight.sh"

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/test_baseline.sh"

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/test_baseline_cleanup.sh"

# shellcheck source=lib/orchestrate_iteration.sh
source "$(dirname "${BASH_SOURCE[0]}")/orchestrate_iteration.sh"

# shellcheck source=lib/orchestrate_complete.sh
source "$(dirname "${BASH_SOURCE[0]}")/orchestrate_complete.sh"
