#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# init_helpers_maturity.sh — Project-maturity classification + next-step hint
# (Milestone 120, Goal 4).
#
# Sourced by init_helpers.sh — do not run directly.
# Provides: _classify_project_maturity, _print_init_next_step
# Depends on: common.sh (log, out_section, out_msg)
# =============================================================================

# _classify_project_maturity — Pure function. Classifies a project into one of
# three buckets so the post-init banner can tailor its next-step hint.
# Args: $1 = project_dir, $2 = resolved design_file path (empty if none),
#       $3 = file_count, $4 = has_commands (1 if any test/build/analyze found)
# Output: one of: has_design | greenfield | brownfield
_classify_project_maturity() {
    local project_dir="$1"
    local design_file="$2"
    local file_count="${3:-0}"
    local has_commands="${4:-0}"

    # Design doc already present (either pipeline.conf points at one, or a
    # canonical name is on disk) → no next-step push.
    # NOTE: the disk-file checks below are redundant when the caller in
    # init.sh (see _m120_design_file computation) has already resolved those
    # same paths, but we keep them so this function stays usable from other
    # call sites where design_file may be unset. The $design_file argument
    # short-circuits the common case.
    if [[ -n "$design_file" ]] \
        || [[ -f "${project_dir}/.tekhton/DESIGN.md" ]] \
        || [[ -f "${project_dir}/DESIGN.md" ]]; then
        echo "has_design"
        return 0
    fi

    # Tiny, quiet directories with no detected commands → greenfield.
    if [[ "$file_count" -le 5 ]] && [[ "$has_commands" -eq 0 ]]; then
        echo "greenfield"
        return 0
    fi

    echo "brownfield"
}

# _print_init_next_step — Emits a branch-aware hint at the end of run_init.
# Args: $1 = classification (has_design|greenfield|brownfield)
# Output: stdout (nothing for has_design; greenfield pushes --plan; brownfield
# tells the user Tekhton is ready without pushing --plan).
_print_init_next_step() {
    local classification="${1:-}"

    case "$classification" in
        has_design)
            # Silent: a design doc already exists, nothing to suggest.
            return 0
            ;;
        greenfield)
            echo
            out_section "Next step"
            out_msg "  No design document detected, and this looks like a fresh project."
            out_msg "    → Run 'tekhton --plan' to create DESIGN.md + CLAUDE.md through"
            out_msg "      a guided interview."
            echo
            ;;
        brownfield)
            echo
            out_section "Next step"
            out_msg "  Tekhton is ready. No design document was auto-detected — that's fine,"
            out_msg "  Tekhton runs without one. If you keep a design doc elsewhere, set"
            out_msg "  DESIGN_FILE in .claude/pipeline.conf to point at it. You can also"
            out_msg "  run 'tekhton --plan' later if you want to add a formal design document."
            echo
            ;;
        *)
            return 0
            ;;
    esac
}
