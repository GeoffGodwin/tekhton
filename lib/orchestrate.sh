#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# orchestrate.sh — Outer orchestration loop wedge shim (M12).
#
# m12 carved this file down from a 278-line monolith to a thin source-only
# shim. The actual loop body lives in lib/orchestrate_main.sh; recovery
# classification is mirrored to internal/orchestrate/recovery.go (driven by
# `tekhton orchestrate classify`) and retained in lib/orchestrate_classify.sh
# for the parity gate + run_complete_loop call site.
#
# Sourced by tekhton.sh — do not run directly.
#
# Loaded module map:
#   orchestrate_classify.sh  — _classify_failure + cause/diagnose helpers
#   orchestrate_aux.sh       — auto-advance, escalation, smart resume, state
#   orchestrate_preflight.sh — pre-finalization fix retry
#   orchestrate_iteration.sh — _handle_pipeline_success / _handle_pipeline_failure
#   orchestrate_main.sh      — run_complete_loop + orchestration globals
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

# shellcheck source=lib/orchestrate_main.sh
source "$(dirname "${BASH_SOURCE[0]}")/orchestrate_main.sh"
