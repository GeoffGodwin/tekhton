#!/usr/bin/env bash
# =============================================================================
# gates_compat.sh — Backwards-compatibility shims for bash functions that
# m31 (gates port) deleted but left bash callers depending on.
#
# Why this file exists. m31 ported lib/gates*.sh to internal/gates and
# internal/pipeline and exposed the surface through `tekhton gate <sub>`.
# The bash callers in stages/coder_buildfix.sh, stages/architect.sh,
# stages/cleanup.sh, stages/review.sh, lib/milestone_acceptance.sh, and
# the lib/stage_envelope.sh post-coder wrapper were never updated. Without
# these shims, every `if run_build_gate ...; then` evaluates as
# `command not found` (rc=127), the build-fix loop interprets that as
# "build still failing", and the pipeline halts after 2 no-progress
# attempts even when the underlying code change is actually fine — the
# real-world failure that surfaced on the m34.1 auto-advance run.
#
# Like lib/drift_compat.sh, these shims delegate to the Cobra subcommand
# (`tekhton gate build|completion`) the Go port already exposes. The
# bash callsites do not need any changes — the function-name surface
# is preserved.
#
# Sourced by tekhton-legacy.sh, internal/stagerunner/DefaultLibHelpers,
# and lib/finalize_shim.sh. Do not run directly.
#
# Expects globals from config defaults: TEKHTON_BIN (optional — falls
# back to `command -v tekhton`), PROJECT_DIR.
# Provides: run_build_gate, run_completion_gate.
# =============================================================================
set -euo pipefail

# _gates_compat_resolve_bin — common binary lookup. Echoes the resolved
# tekhton binary path or empty when unavailable.
_gates_compat_resolve_bin() {
    local b="${TEKHTON_BIN:-}"
    if [[ -z "$b" ]] && command -v tekhton >/dev/null 2>&1; then
        b=$(command -v tekhton)
    fi
    [[ -x "$b" ]] && echo "$b"
}

# run_build_gate STAGE_LABEL
# Runs the build gate (analyze + compile + constraints + ui_test +
# ui_validation) and returns its exit code unchanged. STAGE_LABEL is the
# human-readable label that gets recorded in BUILD_ERRORS.md when the
# gate fails — bash callers pass strings like "post-coder-fix-1",
# "post-architect-remediation", "milestone-acceptance".
#
# Returns 0 on gate pass, non-zero on gate fail. Missing-binary returns
# non-zero so the caller's `if run_build_gate ...; then` correctly
# falls through to the failure branch instead of silently treating
# unavailability as success.
run_build_gate() {
    local label="${1:-unknown}"
    local _bin
    _bin=$(_gates_compat_resolve_bin) || true
    if [[ -z "$_bin" ]]; then
        # Tekhton binary unavailable — surface as a gate failure so the
        # caller does not optimistically advance past an un-verified
        # build. Matches the bash-era behavior when the gate function
        # exited non-zero from any unexpected error.
        return 2
    fi
    "$_bin" gate build --stage-label "$label"
}

# run_completion_gate
# Runs the completion gate after the coder self-reports `COMPLETE`.
# Verifies (a) coder summary status, (b) TEST_CMD passes (gated on
# TEST_DEDUP fingerprint), (c) no leftover claim markers in the
# in-progress notes. Returns 0 on gate pass, non-zero on gate fail.
#
# Called by lib/stage_envelope.sh's post-coder branch. The shim is
# arg-less because the Go side reads everything from env.
run_completion_gate() {
    local _bin
    _bin=$(_gates_compat_resolve_bin) || true
    if [[ -z "$_bin" ]]; then
        return 2
    fi
    "$_bin" gate completion
}
