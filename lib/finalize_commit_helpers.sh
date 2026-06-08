#!/usr/bin/env bash
# =============================================================================
# finalize_commit_helpers.sh — Bookkeeping / decision / tag helpers for
# _hook_commit.
#
# Sourced by lib/finalize_commit.sh — do not run directly.
# Split out of finalize_commit.sh (m50) to make room for the manifest
# write guard while keeping every file under the 300-line bash ceiling.
#
# Expects globals: TEKHTON_DIR, PROJECT_DIR, MILESTONE_MODE, _CURRENT_MILESTONE,
#                  _CACHED_DISPOSITION, TEKHTON_BIN, TEKHTON_HOME.
# Expects helpers from common.sh: warn, log.
# Expects from lib/milestone_ops.sh: tag_milestone_complete.
#
# Provides:
#   _write_commit_decision       — write .tekhton/.commit_decision sentinel
#   _run_commit_bookkeeping      — pre-commit mark_done / cleanup / clear_state
#   _tag_milestone_if_complete   — milestone tag on commit success
# =============================================================================
set -euo pipefail

# _write_commit_decision DECISION
# Writes the commit decision sentinel that downstream completion hooks
# (mark_done, cleanup_milestone, clear_state) read to decide whether to
# fire. Values: "committed" (user said y/e), "declined" (user said n or
# anything else), "skipped" (commit was bypassed by an earlier gate).
# Each finalize hook runs in its own bash subprocess under the Go shim,
# so an in-memory variable will not survive — the sentinel file is the
# only reliable carrier.
_write_commit_decision() {
    local decision="$1"
    local dir="${TEKHTON_DIR:-.tekhton}"
    if [[ "$dir" != /* ]] && [[ -n "${PROJECT_DIR:-}" ]]; then
        dir="${PROJECT_DIR}/${dir}"
    fi
    mkdir -p "$dir" 2>/dev/null || {
        warn "_write_commit_decision: could not create ${dir}"
        return 1
    }
    printf '%s\n' "$decision" > "${dir}/.commit_decision" || {
        warn "_write_commit_decision: could not write ${dir}/.commit_decision"
        return 1
    }
}

# _run_commit_bookkeeping
# Invokes `tekhton commit-bookkeeping` to run mark_done + cleanup_milestone +
# clear_state BEFORE _do_git_commit. Without this pre-commit invocation, the
# same three hooks run via the Go finalize chain AFTER _hook_commit (per the
# 2026-05 reorder gating them on the commit_decision sentinel), but by then
# the commit is already made — the manifest mutation + file deletion show up
# as uncommitted working-tree changes, breaking the "clean state after
# success" contract operators expect.
#
# Best-effort: bookkeeping failures (e.g. tekhton binary missing) emit a
# warning and let _do_git_commit proceed. The Go-chain hooks fire again
# afterward and pick up anything that didn't land here.
_run_commit_bookkeeping() {
    local bin="${TEKHTON_BIN:-tekhton}"
    if ! command -v "$bin" >/dev/null 2>&1; then
        warn "_run_commit_bookkeeping: ${bin} not on PATH — skipping pre-commit bookkeeping (post-commit chain will retry)"
        return 0
    fi
    [[ "${MILESTONE_MODE:-false}" = "true" ]] || return 0
    [[ -n "${_CURRENT_MILESTONE:-}" ]] || return 0
    "$bin" commit-bookkeeping \
        --project-dir "${PROJECT_DIR:-$(pwd)}" \
        --home "${TEKHTON_HOME:-}" \
        --milestone "${_CURRENT_MILESTONE:-}" \
        --milestone-mode "true" \
        --milestone-disposition "${_CACHED_DISPOSITION:-COMPLETE_AND_CONTINUE}" \
        --exit-code 0 \
        2>&1 | while IFS= read -r _line; do
            log "[commit-bookkeeping] $_line"
        done || true
}

# _tag_milestone_if_complete
# Creates the milestone tag once the commit has landed. Reads
# _CACHED_DISPOSITION so it behaves correctly even after _hook_clear_state
# has removed MILESTONE_STATE.md.
_tag_milestone_if_complete() {
    [[ "${MILESTONE_MODE:-false}" != true ]] && return 0
    [[ -z "${_CURRENT_MILESTONE:-}" ]] && return 0
    local disposition="${_CACHED_DISPOSITION:-}"
    if [[ "$disposition" == COMPLETE_AND_CONTINUE ]] || [[ "$disposition" == COMPLETE_AND_WAIT ]]; then
        tag_milestone_complete "${_CURRENT_MILESTONE:-}"
    fi
}
