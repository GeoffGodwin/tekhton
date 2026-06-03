#!/usr/bin/env bash
# =============================================================================
# milestone_window.sh — Active-milestone focused block + file resolver
#
# Sourced by tekhton.sh — do not run directly.
# Sources milestone_window_build.sh (multi-milestone budgeted view).
#
# Expects: milestone_dag.sh sourced first (DAG queries) and context.sh
#          sourced first (model-window / context-budget helpers).
#
# Provides:
#   set_focused_milestone_block  — full body of the active milestone
#   _read_milestone_file         — DAG-aware file lookup with glob fallback
#   build_milestone_window       — re-exported from milestone_window_build.sh
#
# m41: _read_milestone_file falls back to a glob lookup under MILESTONE_DIR
# when the DAG has no row for the requested id (downstream projects whose
# manifest does not list dotted-id rows like m49.2 / m40.1, or no manifest
# at all). The MILESTONE_BLOCK still carries the full file content — the
# block-unavailable signal is no longer a commit-blocking failure (see
# stages/coder.sh:m41 note).
# =============================================================================
set -euo pipefail

# shellcheck source=milestone_window_build.sh disable=SC1091
source "${TEKHTON_HOME}/lib/milestone_window_build.sh"

# set_focused_milestone_block
# Populates MILESTONE_BLOCK with the FULL content of the active milestone
# (resolved via _CURRENT_MILESTONE → dag_number_to_id → _read_milestone_file).
# Used by stages whose agent needs to actually DO the milestone work and
# therefore needs the full Design + Files Modified + Acceptance Criteria
# sections, not the budget-truncated multi-milestone view from
# build_milestone_window.
#
# Why a separate helper from build_milestone_window: the multi-milestone
# window is appropriate for THE OPERATOR'S situational awareness (active +
# frontier + on-deck), but a CODER agent told to port TUI ops needs the
# full m23 design, not a paragraph summary diluted across m23/m24/m25.
# This was the root cause of the M23-coder-does-nothing pattern (#49 v2
# diagnosis): coder saw 500 bytes of fragmented context and gave up in
# one turn.
#
# Returns 0 on success, 1 when no active milestone can be resolved
# (caller falls back to whatever it had before — typically a generic
# "Milestone Mode" block). NB: as of m41, a non-zero return is an INPUT
# safeguard, not a result check — coder.sh warns and continues rather
# than tripping the commit gate.
set_focused_milestone_block() {
    [[ "${MILESTONE_MODE:-false}" = "true" ]] || return 1
    [[ -n "${_CURRENT_MILESTONE:-}" ]] || return 1

    # Ensure the in-memory DAG arrays are populated before calling
    # dag_*. The Go runner does NOT pre-load the manifest in stage
    # subprocesses — DefaultLibHelpers sources milestone_dag.sh (which
    # only initializes empty arrays) and milestone_dag_io.sh (which
    # defines load_manifest), but nothing in the stage start-up path
    # actually calls load_manifest. Without this load, dag_get_file
    # below returns empty, _read_milestone_file falls through, and
    # MILESTONE_BLOCK stays unset — the symptom that triggered the
    # M23 hollow-coder cascade (scout saw no task, coder ran 1 turn).
    if declare -f load_manifest &>/dev/null \
       && [[ "${_DAG_LOADED:-false}" != "true" ]]; then
        load_manifest 2>/dev/null || true
    fi

    # Resolve numeric ID → "m<NN>" → filename via the DAG.
    local id="${_CURRENT_MILESTONE:-}"
    if declare -f dag_number_to_id &>/dev/null; then
        id=$(dag_number_to_id "${_CURRENT_MILESTONE:-}" 2>/dev/null || echo "${_CURRENT_MILESTONE:-}")
    fi
    # Fall back to literal m-prefix when dag_number_to_id is unavailable
    # or returned an unprefixed value. Accepts dotted IDs (49.2, 40.1).
    if [[ -n "$id" ]] && [[ "$id" != m* ]] && [[ "$id" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        id="m${id}"
    fi
    [[ -n "$id" ]] || return 1

    local content
    if declare -f _read_milestone_file &>/dev/null; then
        content=$(_read_milestone_file "$id" 2>/dev/null || true)
    fi
    [[ -n "$content" ]] || return 1

    export MILESTONE_BLOCK="
## Active Milestone — ${id}

The block below is the COMPLETE milestone definition for ${id}. Read it
fully. This is the work you are doing — do not stop after one turn or
ask for clarification you can resolve by reading the design sections
below. The Design section names the files to create/modify; the
Acceptance Criteria are the predicates your work will be evaluated
against.

--- BEGIN MILESTONE CONTENT ---
${content}
--- END MILESTONE CONTENT ---
"
    return 0
}

# _read_milestone_file ID
# Reads the full content of a milestone file. Returns empty if not found.
#
# m41 widening: when the DAG row carries no file (downstream project whose
# MANIFEST.cfg pre-dates the dotted-id convention, or no manifest at all),
# glob MILESTONE_DIR for `<id>-*.md` / `<id>.md`. Both m-prefixed and
# zero-padded variants are tried so `m49.2`, `m05.2`, and `m7` all resolve
# regardless of the file's exact naming.
_read_milestone_file() {
    local id="$1"
    local milestone_dir
    milestone_dir=$(_dag_milestone_dir)

    # 1. DAG-known file wins (preserves manifest as source of truth when set).
    local file
    file=$(dag_get_file "$id" 2>/dev/null) || file=""
    if [[ -n "$file" ]]; then
        local path="${milestone_dir}/${file}"
        if [[ -f "$path" ]]; then
            cat "$path"
            return 0
        fi
    fi

    # 2. Glob fallback. Without `shopt -s nullglob`, an unmatched glob
    # would expand to itself literally; the file test then rejects it.
    [[ -d "$milestone_dir" ]] || return 0
    shopt -s nullglob
    local matches=(
        "${milestone_dir}/${id}-"*.md
        "${milestone_dir}/${id}.md"
    )
    # Zero-padded variants — manifest may say `m05.2` while disk has
    # `m5.2-foo.md`. Strip ONE leading zero from the numeric part.
    if [[ "$id" == m0[0-9]* ]]; then
        local alt="m${id#m0}"
        matches+=(
            "${milestone_dir}/${alt}-"*.md
            "${milestone_dir}/${alt}.md"
        )
    fi
    shopt -u nullglob

    local cand
    for cand in "${matches[@]}"; do
        if [[ -f "$cand" ]]; then
            cat "$cand"
            return 0
        fi
    done
    return 0
}
