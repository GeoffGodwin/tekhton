#!/usr/bin/env bash
# =============================================================================
# finalize_commit_prompt.sh — Interactive commit prompt with retry-on-empty.
#
# Sourced by tekhton.sh and lib/finalize_shim.sh (the _hook_commit arm) —
# do not run directly.
# Expects: log() warn() from common.sh (always available before this file).
# Provides: _prompt_commit_choice — prints to stderr, echoes the chosen
#           letter (y / e / n) on stdout. Caller assigns via
#           commit_choice=$(_prompt_commit_choice).
#
# Why a separate file: extracted from lib/finalize_commit.sh which was at
# the 300-line bash ceiling. The retry-on-empty logic is also worth its
# own test file (tests/test_finalize_commit_prompt.sh) so future regressions
# of the M25 "empty input silently skips" failure mode get caught early.
# =============================================================================
set -euo pipefail

# _prompt_commit_choice
# Prompts the user up to 3 times for a y / e / n commit decision. Reads
# from /dev/tty when stdin is piped (the Go-orchestrator subprocess case);
# falls back to plain stdin read when running interactively.
#
# Empty input behavior — the user-visible reason this helper exists.
# Prior to 2026-05 the prompt accepted empty input as "skip" because it
# fell through the case statement default arm. That regression bit M25:
# something (TUI sidecar escape-sequence response, accidental Enter, or
# long-run stdin drain by the upstream claude CLI) caused the read to
# return empty, the pipeline silently skipped the commit, and 28 files
# of agent work were stranded uncommitted.
#
# Now empty input re-prompts up to 3 times with a warning. If the user
# really wants to skip, they must type 'n' (or any non-empty non-y/e
# token, which is still treated as skip by the caller). After 3 empty
# attempts the helper defaults to 'n' so the pipeline doesn't hang
# forever on a contaminated terminal, but logs loudly so the operator
# sees what happened.
_prompt_commit_choice() {
    local _choice _attempt
    local _max=3
    for ((_attempt=1; _attempt<=_max; _attempt++)); do
        # All prompt output goes to stderr so callers can capture the
        # final choice via $(_prompt_commit_choice) without the prompt
        # text contaminating the captured value.
        log "Commit with suggested message? [y/e/n]" >&2
        echo "  y = commit now with this message" >&2
        echo "  e = open message in \$EDITOR first" >&2
        echo "  n = skip (commit manually later)" >&2
        # TEKHTON_TEST_FORCE_STDIN=1 forces the helper to read from
        # whatever stdin is connected to (a pipe, a file, etc.) instead
        # of falling back to /dev/tty. Tests set this to drive the
        # retry-on-empty branches with `printf '\n\ny\n' | …`. In
        # production stdin is /dev/null (Go-orchestrator subprocess) so
        # the /dev/tty fallback is the only way to reach the human.
        if [[ "${TEKHTON_TEST_FORCE_STDIN:-0}" = "1" ]]; then
            read -r _choice || _choice=""
        elif [[ -t 0 ]]; then
            read -r _choice
        else
            read -r _choice < /dev/tty 2>/dev/null || _choice="y"
            log "(read from /dev/tty — stdin was piped)" >&2
        fi
        # Trim all whitespace — "  y  " becomes "y", trailing CR from
        # Windows-style line endings also evaporates.
        _choice="${_choice//[[:space:]]/}"
        if [[ -n "$_choice" ]]; then
            printf '%s\n' "$_choice"
            return 0
        fi
        if (( _attempt < _max )); then
            warn "Empty input — please type y, e, or n. (attempt ${_attempt}/${_max})" >&2
        else
            warn "Empty input after ${_max} attempts — defaulting to SKIP." >&2
            warn "If you meant to commit, run: git add -A && git commit" >&2
        fi
    done
    printf 'n\n'
}
