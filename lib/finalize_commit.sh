#!/usr/bin/env bash
# =============================================================================
# finalize_commit.sh — Commit-stage finalize hooks and helpers
#
# Sourced by lib/finalize.sh — do not run directly.
# Expects: out_banner, out_kv, out_msg, out_section, log, success helpers
#          from lib/common.sh; generate_commit_message, drain_pending_inbox,
#          update_checkpoint_commit, tag_milestone_complete, print_run_summary,
#          _print_action_items, _print_next_action, _check_gitignore_safety,
#          _format_timing_banner, display_health_score.
# Expects globals: TASK, START_AT, VERDICT, LOG_FILE, MILESTONE_MODE,
#                  _CURRENT_MILESTONE, _CACHED_DISPOSITION, AUTO_COMMIT,
#                  FINAL_CHECK_RESULT, _BUMPED_VERSION_*, HEALTH_SCORE,
#                  _PHASE_TIMINGS, EDITOR, TEKHTON_SESSION_DIR, _TEKHTON_LOCK_FILE.
#
# Provides:
#   _do_git_commit              — stage, commit, and log output
#   _tag_milestone_if_complete  — create milestone tag post-commit (helper)
#   _hook_commit                — interactive/auto commit finalize hook
# =============================================================================
set -euo pipefail

# shellcheck source=lib/finalize_commit_staging.sh
source "${TEKHTON_HOME:-}/lib/finalize_commit_staging.sh"
# shellcheck source=lib/finalize_commit_sentinel.sh
source "${TEKHTON_HOME:-}/lib/finalize_commit_sentinel.sh"
# shellcheck source=lib/finalize_commit_helpers.sh
source "${TEKHTON_HOME:-}/lib/finalize_commit_helpers.sh"

# _do_git_commit MSG
# Stages every dirty path except pure run transients (S1 denylist —
# _is_path_committable), runs gitignore safety check, commits. This keeps the
# committed file-set equal to the substantive working-tree set m27 accepts on,
# so no source change can be stranded (the pre-S1 allowlist dropped lib/,
# stages/, prompts/ work the coder didn't explicitly declare). The targeted
# MANIFEST.cfg protection is preserved by _check_manifest_write_guard below.
# M40: Drains pending inbox before commit.
_do_git_commit() {
    local msg="$1"
    # Drain any pending watchtower inbox notes before committing
    if command -v drain_pending_inbox &>/dev/null; then
        drain_pending_inbox 2>/dev/null || true
    fi
    _check_gitignore_safety

    # Inventory dirty files. Use porcelain v1 — first two columns are status,
    # then a space, then the path (or "rename -> newpath").
    local dirty_files=() unexpected=()
    local line path
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        path="${line:3}"
        # Rename entries: "R  old -> new" — track the destination.
        if [[ "$path" == *' -> '* ]]; then
            path="${path##* -> }"
        fi
        dirty_files+=( "$path" )
    done < <(git status --porcelain 2>/dev/null)

    if [ ${#dirty_files[@]} -eq 0 ]; then
        log "[commit] No working-tree changes to commit."
        return 0
    fi

    local expected=()
    for path in "${dirty_files[@]}"; do
        if _is_path_committable "$path"; then
            expected+=( "$path" )
        else
            unexpected+=( "$path" )
        fi
    done

    if [ ${#unexpected[@]} -gt 0 ]; then
        # Transients (logs, session dir, venvs) — expected to be skipped, not a
        # problem. Verbose-only so the normal log isn't noisy.
        log_verbose "[commit] Skipped ${#unexpected[@]} transient path(s) (logs/session/venv)."
    fi

    if [ ${#expected[@]} -eq 0 ]; then
        warn "[commit] Only transient paths in working tree — nothing to auto-commit."
        return 0
    fi

    git add -- "${expected[@]}" > /dev/null 2>&1
    # m50 — Pre-commit guard: refuse a stage-time MANIFEST.cfg write.
    # See _check_manifest_write_guard below.
    _check_manifest_write_guard
    local git_output
    git_output=$(git commit -m "$msg" 2>&1) || true
    # Show only the summary line (e.g. "[branch abc1234] feat: message")
    local summary
    summary=$(echo "$git_output" | head -1)
    log "$summary"
}

# _check_manifest_write_guard
# m50 — Pre-commit guard: refuse to commit MANIFEST.cfg from any stage that
# is not the finalize chain. The finalize chain marks itself active by
# writing the sentinel .tekhton/.finalize_active in
# internal/finalize/orchestrator.go::Run; its absence here means a stage
# agent (coder/reviewer/tester/security/etc.) is the one attempting the
# write — exactly the m48 / 51aff09 scenario where the coder ran the
# milestone-split subroutine against m01 as a fixture and silently
# corrupted MANIFEST.cfg with 69 spurious lines.
#
# Behavior: warn, unstage MANIFEST.cfg, continue with the rest of the
# changeset. The intent is "the rest of the changeset is probably
# legitimate, just the manifest write isn't" — aborting the whole commit
# would lose the legitimate stage work, which is what m46 spent its
# budget preventing.
#
# Operator escape hatch: TEKHTON_MANIFEST_WRITE_OVERRIDE=1 keeps the
# stage-time MANIFEST.cfg write staged (used by milestone-authoring
# tools and manual recovery flows like the b7b5e25 restore).
_check_manifest_write_guard() {
    local manifest_path=".claude/milestones/MANIFEST.cfg"
    local tekhton_dir="${TEKHTON_DIR:-.tekhton}"
    if [[ "$tekhton_dir" != /* ]] && [[ -n "${PROJECT_DIR:-}" ]]; then
        tekhton_dir="${PROJECT_DIR}/${tekhton_dir}"
    fi
    local sentinel="${tekhton_dir}/.finalize_active"

    if ! git diff --cached --name-only 2>/dev/null \
            | grep -qx "$manifest_path"; then
        return 0
    fi
    if [[ -f "$sentinel" ]]; then
        return 0
    fi
    if [[ "${TEKHTON_MANIFEST_WRITE_OVERRIDE:-}" = "1" ]]; then
        warn "[manifest-guard] override set (TEKHTON_MANIFEST_WRITE_OVERRIDE=1) — proceeding with ${manifest_path} write"
        return 0
    fi
    warn "[manifest-guard] Refusing to commit ${manifest_path} from stage (${STAGE_LABEL:-unknown}): file is finalize-owned. Unstaging."
    warn "[manifest-guard] If this is intentional (e.g. a milestone-authoring tool), set TEKHTON_MANIFEST_WRITE_OVERRIDE=1 in the environment."
    git restore --staged -- "$manifest_path" 2>/dev/null || true
    return 0
}

# _hook_commit EXIT_CODE — auto-commit on success + clean final checks.
# No push (operator reviews + pushes manually). 2026-05-27 removed the
# y/e/n prompt — it burned operator attention and hung the pipeline when
# stdin was unreachable (M27.2). AUTO_COMMIT=false / --no-commit skips
# the commit and prints the suggested message + manual command.
_hook_commit() {
    local exit_code="$1"
    if [[ "$exit_code" -ne 0 ]]; then
        # Pipeline failed before reaching the commit gate; gate the
        # downstream completion hooks (mark_done / cleanup_milestone /
        # clear_state) on the same "skipped" sentinel so the manifest
        # is not mutated on failure paths either.
        # m46: emit a stderr warning so operators see the skip rather
        # than inferring it post-hoc. The 2026-06-06 auto-advance run
        # silently skipped 4 commits across ~10 hours of work because
        # this branch returned 0 with no visible signal.
        warn "[_hook_commit] skipped — finalize received exit_code=${exit_code} (pipeline disposition was non-success)"
        _write_commit_decision "skipped"
        return 0
    fi
    # FINAL_CHECK_RESULT may be set in-process (legacy) or only in the sentinel
    # (Go-shim per-hook subprocess). Either source non-zero ⇒ block.
    # m41: print the sentinel's `# <reason>` (coder_did_not_produce_summary,
    # completion_gate_failed_substantive_work_only, …) instead of the
    # FINAL_CHECK_RESULT=0 / persisted=1 contradiction. Numerics go to
    # log_verbose for postmortem.
    local _fcr_persisted _fcr_reason _sentinel_path
    _fcr_persisted=$(_final_check_result_read)
    _sentinel_path="${TEKHTON_DIR:-.tekhton}/.final_check_result"
    if [[ "${FINAL_CHECK_RESULT:-0}" -ne 0 ]] || [[ "$_fcr_persisted" -ne 0 ]]; then
        _fcr_reason=$(_final_check_reason_read)
        if [[ -n "$_fcr_reason" ]]; then
            warn "Commit blocked: ${_fcr_reason} (see ${_sentinel_path})"
        else
            warn "Commit blocked: final checks failed (see ${_sentinel_path})"
        fi
        log_verbose "[_hook_commit] FINAL_CHECK_RESULT=${FINAL_CHECK_RESULT:-0} persisted=${_fcr_persisted} reason=${_fcr_reason:-<none>}"
        warn "Resolve the failures shown above, then commit manually with: git add -A && git commit"
        warn "To skip the gate intentionally, run: tekhton finalize --commit-on-test-failure (TBD)."
        # m46: tagged warn carrying both "_hook_commit" and "skip" so log
        # scrapers see the silent-skip cascade signal at both code paths.
        # When the sentinel is tripped by a false-positive replan dialog,
        # lib/replan_midrun_choice.sh::handle_replan_choice clears it.
        warn "[_hook_commit] skipped commit — FINAL_CHECK_RESULT sentinel still set; if this is a false-positive, the operator-override path should have cleared ${_sentinel_path}"
        _write_commit_decision "skipped"
        return 0
    fi

    # Milestone disposition for commit signatures (read from cache —
    # _hook_clear_state may have already deleted MILESTONE_STATE.md)
    local ms_num=""
    local ms_disposition=""
    if [[ "${MILESTONE_MODE:-false}" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
        ms_num="${_CURRENT_MILESTONE:-}"
        ms_disposition="${_CACHED_DISPOSITION:-}"
    fi

    # Remove lock file before staging so it isn't committed
    if [[ -n "${_TEKHTON_LOCK_FILE:-}" ]] && [[ -f "${_TEKHTON_LOCK_FILE}" ]]; then
        rm -f "${_TEKHTON_LOCK_FILE}" 2>/dev/null || true
    fi

    # Generate commit message
    COMMIT_MSG=$(generate_commit_message "${TASK:-}" "$ms_num" "$ms_disposition" || echo "feat: ${TASK:-}")

    # Print completion banner. Recap fields route through out_summary_kv so
    # the TUI hold view renders them in a dedicated summary block rather than
    # interleaved with runtime chronology events (M110).
    out_banner "Tekhton — Pipeline Complete"
    out_summary_kv "Task"      "${TASK:-}"
    out_summary_kv "Started"   "${START_AT:-intake}"
    out_summary_kv "Verdict"   "${VERDICT:-APPROVED}"
    out_summary_kv "Log"       "${LOG_FILE:-}"
    if [[ -n "$ms_num" ]]; then
        if [[ "$ms_disposition" == COMPLETE_AND_CONTINUE ]] || [[ "$ms_disposition" == COMPLETE_AND_WAIT ]]; then
            out_summary_kv "Milestone" "${ms_num} — COMPLETE"
        else
            out_kv "Milestone" "${ms_num} — PARTIAL" warn
        fi
    fi
    # Project version bump (M96 IA2) — exposed by bump_version_files
    if [[ -n "${_BUMPED_VERSION_OLD:-}" ]] && [[ -n "${_BUMPED_VERSION_NEW:-}" ]]; then
        out_summary_kv "Version" "${_BUMPED_VERSION_OLD} → ${_BUMPED_VERSION_NEW} (${_BUMPED_VERSION_TYPE:-patch})"
    fi
    # Health score delta (Milestone 15)
    if [[ -n "${HEALTH_SCORE:-}" ]] && command -v display_health_score &>/dev/null; then
        display_health_score "$HEALTH_SCORE" "${HEALTH_PREV_SCORE:-}"
    fi
    # Top-3 time consumers (M46)
    if command -v _format_timing_banner &>/dev/null && [[ ${#_PHASE_TIMINGS[@]} -gt 0 ]]; then
        local _timing_banner
        _timing_banner=$(_format_timing_banner)
        if [[ -n "$_timing_banner" ]]; then
            out_section "Time breakdown (top 3)"
            out_msg "$_timing_banner"
        fi
    fi
    out_msg ""
    # Print action items summary
    _print_action_items

    log "Commit message:"
    echo "────────────────────────────────────────"
    echo "$COMMIT_MSG"
    echo "────────────────────────────────────────"
    echo

    # Explicit opt-out: AUTO_COMMIT=false (set in pipeline.conf or via
    # --no-commit) skips the commit entirely. Default is to commit.
    if [[ "${AUTO_COMMIT:-true}" = "false" ]]; then
        log "AUTO_COMMIT=false — skipping commit. When ready:"
        echo "  git add -A && git commit -m '${COMMIT_MSG%%$'\n'*}'"
        _COMMIT_SUCCEEDED=false
        _write_commit_decision "declined"
        _print_next_action
        return 0
    fi

    # Auto-commit path. Order matters: write the decision sentinel FIRST
    # (so the bookkeeping hooks' shouldRunOnCompletion gate sees
    # "committed"), then run bookkeeping (mutates manifest + deletes
    # milestone file), THEN _do_git_commit (captures both the agent's
    # work AND the bookkeeping mutations in a single commit, leaving the
    # working tree clean post-success).
    _write_commit_decision "committed"
    _run_commit_bookkeeping
    _do_git_commit "$COMMIT_MSG"
    _COMMIT_SUCCEEDED=true
    if command -v update_checkpoint_commit &>/dev/null; then
        update_checkpoint_commit "$(git rev-parse HEAD 2>/dev/null || echo "")"
    fi
    _tag_milestone_if_complete
    print_run_summary
    success "Committed. Review with \`git show HEAD\` and push when ready."
    _print_next_action
}
