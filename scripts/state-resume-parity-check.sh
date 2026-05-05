#!/usr/bin/env bash
# scripts/state-resume-parity-check.sh — m03 acceptance gate (AC #6).
#
# Drives a small fixture sequence of state writes against two writers:
#   1. The pre-m03 bash heredoc writer, retrieved via `git show HEAD~1:lib/state.sh`
#   2. The current m03 writer (Go via `tekhton state …`, or the bash fallback
#      when the Go binary is not on PATH)
#
# For each, after writing the state, we read back canonical fields
# (exit_stage, exit_reason, resume_flag, resume_task, milestone_id,
# human_mode, human_notes_tag, current_note_line, current_note_id,
# human_single_note) and compare. Both sides should agree byte-for-byte
# on the readback values — that is the resume contract.
#
# Usage:
#   scripts/state-resume-parity-check.sh [--use-fallback]
#
# Exit codes:
#   0 = parity holds
#   1 = parity diff detected, or setup error
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$REPO_ROOT"

USE_FALLBACK=0
for arg in "$@"; do
    case "$arg" in
        --use-fallback) USE_FALLBACK=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

_log()  { printf '\033[0;36m[state-parity]\033[0m %s\n' "$*"; }
_ok()   { printf '\033[0;32m[state-parity] PASS\033[0m %s\n' "$*"; }
_fail() { printf '\033[0;31m[state-parity] FAIL\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "$USE_FALLBACK" -eq 0 ]]; then
    if command -v go >/dev/null 2>&1; then
        _log "Building Go binary via 'make build'..."
        make build >/dev/null
        export PATH="${REPO_ROOT}/bin:${PATH}"
    else
        _log "Go not installed — using bash fallback for HEAD writer."
    fi
fi

PREV_LIB="$(mktemp)"
PREV_RUN="$(mktemp -d)"
HEAD_RUN="$(mktemp -d)"
trap 'rm -f "$PREV_LIB"; rm -rf "$PREV_RUN" "$HEAD_RUN"' EXIT

if ! git show HEAD~1:lib/state.sh > "$PREV_LIB" 2>/dev/null; then
    _fail "Cannot read HEAD~1:lib/state.sh; ensure m03 is committed."
fi
_log "Loaded pre-m03 writer from HEAD~1:lib/state.sh"

# fixture run: writes a state file using the given writer, then reads back
# all the canonical fields used by resume into a "key=value" report.
_run_fixture() {
    local out_dir="$1" state_lib="$2" report_file="$3"
    local state_file="${out_dir}/.claude/PIPELINE_STATE.md"
    # The pre-m03 writer chats on stdout (log "State file target …"); collect
    # the canonical-readback table on FD 3 so it stays clean.
    exec 3>"$report_file"
    bash -c '
        set -euo pipefail
        TEKHTON_HOME="'"$REPO_ROOT"'"
        export PATH="'"$PATH"'"
        PROJECT_DIR="'"$out_dir"'"
        mkdir -p "$PROJECT_DIR/.claude"
        PIPELINE_STATE_FILE="'"$state_file"'"
        TEKHTON_SESSION_DIR="$PROJECT_DIR/.claude/session"
        mkdir -p "$TEKHTON_SESSION_DIR"
        log() { :; }; warn() { :; }; error() { :; }; success() { :; }
        # shellcheck source=/dev/null
        source "$TEKHTON_HOME/lib/common.sh"
        # state_helpers.sh exists only on HEAD; the legacy writer pulls
        # everything inline.
        if grep -q state_helpers "'"$state_lib"'" 2>/dev/null; then
            # shellcheck source=/dev/null
            source "$TEKHTON_HOME/lib/state_helpers.sh"
        fi
        # shellcheck source=/dev/null
        source "'"$state_lib"'"

        HUMAN_MODE=true
        HUMAN_NOTES_TAG=BUG
        CURRENT_NOTE_LINE=12
        CURRENT_NOTE_ID=note-2026-0501-001
        HUMAN_SINGLE_NOTE=false
        PIPELINE_ORDER=standard
        TESTER_MODE=verify_passing
        TOTAL_TURNS=42
        _ORCH_ATTEMPT=3
        _ORCH_AGENT_CALLS=14
        _ORCH_ELAPSED=900
        _ORCH_ATTEMPT_LOG=""

        write_pipeline_state \
            "review" \
            "blockers_remain" \
            "--human BUG --start-at review" \
            "Fix the broken login redirect when SSO returns 302" \
            "3 complex blockers" \
            "m03"

        # Emit canonical readback table. For the legacy writer we use the
        # same awk shapes the pre-m03 bash side used; for the HEAD writer we
        # use read_pipeline_state_field.
        read_field() {
            local f="$1" v=""
            if declare -f read_pipeline_state_field &>/dev/null; then
                v="$(read_pipeline_state_field "$f")"
            else
                case "$f" in
                    exit_stage)        v=$(awk '"'"'/^## Exit Stage$/{getline; print; exit}'"'"' "$PIPELINE_STATE_FILE") ;;
                    exit_reason)       v=$(awk '"'"'/^## Exit Reason$/{getline; print; exit}'"'"' "$PIPELINE_STATE_FILE") ;;
                    resume_flag)       v=$(awk '"'"'/^## Resume Command$/{getline; print; exit}'"'"' "$PIPELINE_STATE_FILE") ;;
                    resume_task)       v=$(awk '"'"'/^## Task$/{getline; print; exit}'"'"' "$PIPELINE_STATE_FILE") ;;
                    milestone_id)      v=$(awk '"'"'/^## Milestone$/{getline; print; exit}'"'"' "$PIPELINE_STATE_FILE") ;;
                    human_mode)        v=$(awk '"'"'/^## Human Mode$/{getline; print; exit}'"'"' "$PIPELINE_STATE_FILE") ;;
                    human_notes_tag)   v=$(awk '"'"'/^## Human Notes Tag$/{getline; print; exit}'"'"' "$PIPELINE_STATE_FILE") ;;
                    current_note_line) v=$(awk '"'"'/^## Current Note Line$/{getline; print; exit}'"'"' "$PIPELINE_STATE_FILE") ;;
                    current_note_id)   v=$(awk '"'"'/^## Current Note ID$/{getline; print; exit}'"'"' "$PIPELINE_STATE_FILE") ;;
                    human_single_note) v=$(awk '"'"'/^## Human Single Note$/{getline; print; exit}'"'"' "$PIPELINE_STATE_FILE") ;;
                esac
            fi
            printf "%s=%s\n" "$f" "$v" >&3
        }
        for f in exit_stage exit_reason resume_flag resume_task milestone_id \
                 human_mode human_notes_tag current_note_line current_note_id \
                 human_single_note; do
            read_field "$f"
        done
    ' >/dev/null
    exec 3>&-
}

PREV_REPORT="$(mktemp)"
HEAD_REPORT="$(mktemp)"
trap 'rm -f "$PREV_LIB" "$PREV_REPORT" "$HEAD_REPORT"; rm -rf "$PREV_RUN" "$HEAD_RUN"' EXIT

_log "Running fixture against pre-m03 writer..."
_run_fixture "$PREV_RUN" "$PREV_LIB" "$PREV_REPORT"

_log "Running fixture against HEAD writer..."
_run_fixture "$HEAD_RUN" "${REPO_ROOT}/lib/state.sh" "$HEAD_REPORT"

if diff -u "$PREV_REPORT" "$HEAD_REPORT" >/dev/null 2>&1; then
    _ok "Resume readback parity holds across writers."
    exit 0
fi

_log "Parity diff:"
diff -u "$PREV_REPORT" "$HEAD_REPORT" | sed 's/^/    /' >&2 || true
_fail "Resume readback differs across writers — see above."
