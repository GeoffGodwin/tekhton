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

# _do_git_commit MSG
# Stages pipeline-declared files only (coder-declared ∪ bookkeeping
# allowlist), runs gitignore safety check, commits. Anything outside that
# union is left in the working tree with a warning — the old `git add -A`
# swept up unrelated edits and made commit messages misleading.
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
        if _is_path_allowed "$path"; then
            expected+=( "$path" )
        else
            unexpected+=( "$path" )
        fi
    done

    if [ ${#unexpected[@]} -gt 0 ]; then
        warn "[commit] Skipping ${#unexpected[@]} file(s) not declared by the coder or pipeline bookkeeping:"
        local u
        for u in "${unexpected[@]}"; do
            warn "  - $u"
        done
        warn "[commit] Review with \`git status\` and commit manually if intended."
    fi

    if [ ${#expected[@]} -eq 0 ]; then
        warn "[commit] No pipeline-declared files in working tree — nothing to auto-commit."
        return 0
    fi

    git add -- "${expected[@]}" > /dev/null 2>&1
    local git_output
    git_output=$(git commit -m "$msg" 2>&1) || true
    # Show only the summary line (e.g. "[branch abc1234] feat: message")
    local summary
    summary=$(echo "$git_output" | head -1)
    log "$summary"
}

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

# _final_check_result_read
# Returns the persisted FINAL_CHECK_RESULT (0 when no failure was recorded).
# Each finalize hook runs in its own bash subprocess under the Go shim, so
# the in-memory FINAL_CHECK_RESULT set by _hook_final_checks does not
# survive to _hook_commit — the sentinel file (.tekhton/.final_check_result)
# is what carries the verdict between hooks.
_final_check_result_read() {
    local f="${TEKHTON_DIR:-.tekhton}/.final_check_result"
    [[ -f "$f" ]] || { echo 0; return 0; }
    local v
    v=$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$v" ]] && { echo 0; return 0; }
    echo "$v"
}

# _hook_commit EXIT_CODE
# Auto-commit flow. Runs only on success + clean final checks. Prints the
# completion banner, the commit message, and commits. No push (operator
# reviews + pushes manually).
#
# 2026-05-27: the y/e/n prompt was removed entirely. The historical
# Tekhton behavior was always-commit-no-push, and the interactive prompt
# we'd added was burning operator attention (be at terminal when run
# finishes) AND occasionally hanging the whole pipeline when stdin was
# unreachable (M27.2 cascade). Operators who want to review before
# committing can set AUTO_COMMIT=false in pipeline.conf or pass
# --no-commit; the pipeline then skips the commit and prints the
# suggested message + manual command.
_hook_commit() {
    local exit_code="$1"
    if [[ "$exit_code" -ne 0 ]]; then
        # Pipeline failed before reaching the commit gate; gate the
        # downstream completion hooks (mark_done / cleanup_milestone /
        # clear_state) on the same "skipped" sentinel so the manifest
        # is not mutated on failure paths either.
        _write_commit_decision "skipped"
        return 0
    fi
    # FINAL_CHECK_RESULT is set in-process when this hook happens to share a
    # shell with _hook_final_checks (legacy / test paths). Under the Go
    # orchestrator each hook is its own subprocess so we ALSO read the
    # sentinel file _hook_final_checks writes. Either source non-zero ⇒
    # block the commit and tell the operator why.
    local _fcr_persisted
    _fcr_persisted=$(_final_check_result_read)
    if [[ "${FINAL_CHECK_RESULT:-0}" -ne 0 ]] || [[ "$_fcr_persisted" -ne 0 ]]; then
        warn "Commit blocked: final checks failed (FINAL_CHECK_RESULT=${FINAL_CHECK_RESULT:-0}, persisted=${_fcr_persisted})."
        warn "Resolve the failures shown above, then commit manually with: git add -A && git commit"
        warn "To skip the gate intentionally, run: tekhton finalize --commit-on-test-failure (TBD)."
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
