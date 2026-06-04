#!/usr/bin/env bash
# =============================================================================
# project_version_verify.sh — Post-bump version-file consistency self-check
#
# Sourced by tekhton.sh — do not run directly.
# Expects: lib/project_version.sh and lib/project_version_bump_helpers.sh
# sourced first (uses _detect_version_from_file + _accessor_for_file).
# Provides:
#   verify_version_files_synced TARGET_VERSION ENTRY [ENTRY ...]
#     — read every declared file back; trip_commit_gate +
#       drift human-action append on divergence. Independent of TEST_CMD
#       so a desynced bump fails the commit gate even when the project's
#       test suite is a no-op (m43 / pair with m42).
# =============================================================================

# verify_version_files_synced TARGET_VERSION ENTRY [ENTRY ...]
#   Returns 0 when every declared/detected version file matches
#   TARGET_VERSION; returns 1 (and trips the commit gate) otherwise.
#   Each ENTRY is `path:selector` (as emitted by _parse_version_files_list);
#   `path` is project-dir-relative.
verify_version_files_synced() {
    local target="$1"
    shift || true

    [[ "${PROJECT_VERSION_ENABLED:-true}" != "true" ]] && return 0
    [[ -z "$target" ]] && return 0
    [[ "$#" -eq 0 ]] && return 0

    local project_dir="${PROJECT_DIR:-.}"
    local -a divergent=()
    local entry file abs actual

    for entry in "$@"; do
        file="${entry%%:*}"
        [[ -z "$file" ]] && continue
        abs="${project_dir}/${file}"
        # Missing file: callers may declare a file that doesn't exist yet
        # (e.g. a template path) — treat that as a non-blocking miss, not a
        # divergence, so the bump still completes cleanly.
        [[ ! -f "$abs" ]] && continue

        local accessor
        accessor=$(_accessor_for_file "$file")
        actual=$(_detect_version_from_file "$abs" "$accessor" 2>/dev/null || true)

        if [[ -z "$actual" ]]; then
            # We bumped this file but couldn't read it back — that's a
            # bumper bug, not a desync. Surface it as a divergence so the
            # commit gate trips and the operator notices.
            divergent+=("${file} (unreadable after bump)")
            continue
        fi

        if [[ "$actual" != "$target" ]]; then
            divergent+=("${file} (${actual} != ${target})")
        fi
    done

    [[ "${#divergent[@]}" -eq 0 ]] && return 0

    # Trip the commit gate with a structured reason. _hook_commit reads
    # `.final_check_result` and refuses to commit when it's non-zero, so
    # the desynced bump never reaches the commit step regardless of
    # TEST_CMD (the m42 no-op path would have masked this otherwise).
    local reason="version_files_desynced"
    if command -v trip_commit_gate &>/dev/null; then
        # Use the first divergent file in the reason for greppable
        # specificity (matches the m43 acceptance criterion wording:
        # "version_files_desynced_<file>").
        local first_file="${divergent[0]%% *}"
        local sanitised="${first_file//\//_}"
        reason="version_files_desynced_${sanitised}"
        trip_commit_gate "$reason" || true
    fi

    # Emit a HUMAN_ACTION entry so the post-run banner surfaces the issue.
    # Use the Go drift CLI when available; gracefully no-op when missing
    # (test environments often stub the CLI out).
    local desc
    desc="Version bump left ${#divergent[@]} file(s) out of sync (target=${target}):"
    local d
    for d in "${divergent[@]}"; do
        desc+=$'\n  - '"$d"
    done
    desc+=$'\n'"Investigate the bump path for these files in pipeline.conf VERSION_FILES."

    if command -v _append_human_action_entry &>/dev/null; then
        _append_human_action_entry "project_version_bump" "$desc" || true
    else
        local tekhton_bin="${TEKHTON_BIN:-tekhton}"
        if command -v "$tekhton_bin" &>/dev/null; then
            "$tekhton_bin" drift human-action append \
                --project-dir "$project_dir" \
                --source "project_version_bump" \
                --description "$desc" 2>/dev/null || true
        fi
    fi

    if command -v warn &>/dev/null; then
        warn "Version-file desync detected after bump:"
        for d in "${divergent[@]}"; do
            warn "  - ${d}"
        done
    fi

    return 1
}
