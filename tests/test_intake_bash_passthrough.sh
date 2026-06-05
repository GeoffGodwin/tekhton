#!/usr/bin/env bash
# =============================================================================
# test_intake_bash_passthrough.sh — m36.2 wedge boundary test.
#
# Exercises stages/intake.sh's call chain through the shimmed
# lib/intake_helpers.sh + lib/intake_verdict_handlers.sh into the Go
# transition CLI subcommands (`tekhton intake helpers ...` /
# `tekhton intake verdict ...`).
#
# Scenarios:
#   1. PASS                — happy path; no halt; verdict + confidence parsed.
#   2. TWEAKED             — non-confirm; tweaks block extracted.
#   3. SPLIT_RECOMMENDED   — non-interactive 'c' continue; no halt.
#   4. NEEDS_CLARITY       — COMPLETE_MODE → halt; bash forwards state.
#
# Skips cleanly when the tekhton Go binary is not built.
#
# DELETED in m36.3 along with stages/intake.sh and the bash shim files.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"
if [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "test_intake_bash_passthrough.sh: tekhton binary not found at ${TEKHTON_BIN}; skipping (run 'make build' first)"
    exit 0
fi
export TEKHTON_HOME TEKHTON_BIN

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PROJECT_DIR="$TMPROOT"
TEKHTON_SESSION_DIR="${TMPROOT}/session"
MILESTONE_DIR="${TMPROOT}/milestones"
mkdir -p "$TEKHTON_SESSION_DIR" "$MILESTONE_DIR"
export PROJECT_DIR TEKHTON_SESSION_DIR MILESTONE_DIR

MILESTONE_DAG_ENABLED="false"
MILESTONE_MODE="false"
_CURRENT_MILESTONE=""
TASK="test task"
CLARIFICATIONS_FILE=".tekhton/CLARIFICATIONS.md"
export MILESTONE_DAG_ENABLED MILESTONE_MODE _CURRENT_MILESTONE TASK CLARIFICATIONS_FILE

# Stub pipeline functions sourced files expect.
log()     { :; }
warn()    { :; }
error()   { :; }
header()  { :; }
success() { :; }
# Capture write_pipeline_state calls so the NEEDS_CLARITY scenario can assert.
_STATE_LAST=""
write_pipeline_state() {
    _STATE_LAST="$1|$2|$3|$4|$5|$6"
    return 0
}
export -f write_pipeline_state log warn error header success || true

# Source the shims under test.
# shellcheck source=../lib/intake_helpers.sh
source "${TEKHTON_HOME}/lib/intake_helpers.sh"
# shellcheck source=../lib/intake_verdict_handlers.sh
source "${TEKHTON_HOME}/lib/intake_verdict_handlers.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m $label — expected='$expected', got='$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m $label — needle='$needle' not in haystack"
        FAIL=$((FAIL + 1))
    fi
}

FIXTURE_DIR="${TEKHTON_HOME}/internal/intake/testdata"

# Scenario 1: PASS verdict — no halt, no tweaks.
echo "Scenario 1 — PASS"
verdict=$(_intake_parse_verdict "${FIXTURE_DIR}/report_pass.md")
confidence=$(_intake_parse_confidence "${FIXTURE_DIR}/report_pass.md")
assert_eq "PASS verdict from fixture" "PASS" "$verdict"
assert_eq "PASS confidence = 95" "95" "$confidence"

# Scenario 2: TWEAKED verdict — non-confirm, no halt.
echo "Scenario 2 — TWEAKED (non-confirm)"
verdict=$(_intake_parse_verdict "${FIXTURE_DIR}/report_tweaked.md")
tweaks=$(_intake_parse_tweaks "${FIXTURE_DIR}/report_tweaked.md")
assert_eq "TWEAKED verdict from fixture" "TWEAKED" "$verdict"
assert_contains "Tweaks contain milestone heading" "# m99.9 — Test Milestone (PM-tweaked)" "$tweaks"
# Drive the verdict handler in non-confirm mode; should exit cleanly.
INTAKE_CONFIRM_TWEAKS=false COMPLETE_MODE=false \
    bash -c "
        TEKHTON_HOME='${TEKHTON_HOME}' TEKHTON_BIN='${TEKHTON_BIN}'
        export TEKHTON_HOME TEKHTON_BIN
        TEKHTON_SESSION_DIR='${TEKHTON_SESSION_DIR}'
        export TEKHTON_SESSION_DIR
        INTAKE_CONFIRM_TWEAKS=false
        export INTAKE_CONFIRM_TWEAKS
        log() { :; }; warn() { :; }; success() { :; }; header() { :; }; error() { :; }
        write_pipeline_state() { :; }
        source '${TEKHTON_HOME}/lib/intake_helpers.sh'
        source '${TEKHTON_HOME}/lib/intake_verdict_handlers.sh'
        _intake_handle_tweaked '${FIXTURE_DIR}/report_tweaked.md'
    " >/dev/null 2>&1
rc=$?
assert_eq "TWEAKED non-confirm exits 0" "0" "$rc"

# Scenario 3: SPLIT_RECOMMENDED — non-interactive 'c' continue.
echo "Scenario 3 — SPLIT_RECOMMENDED (continue)"
verdict=$(_intake_parse_verdict "${FIXTURE_DIR}/report_split.md")
assert_eq "SPLIT_RECOMMENDED verdict from fixture" "SPLIT_RECOMMENDED" "$verdict"
# Pipe "c" as stdin so the readChoice path returns "continue".
bash -c "
    TEKHTON_HOME='${TEKHTON_HOME}' TEKHTON_BIN='${TEKHTON_BIN}'
    export TEKHTON_HOME TEKHTON_BIN
    TEKHTON_SESSION_DIR='${TEKHTON_SESSION_DIR}'
    export TEKHTON_SESSION_DIR
    MILESTONE_MODE=false
    export MILESTONE_MODE
    log() { :; }; warn() { :; }; success() { :; }; header() { :; }; error() { :; }
    write_pipeline_state() { :; }
    source '${TEKHTON_HOME}/lib/intake_helpers.sh'
    source '${TEKHTON_HOME}/lib/intake_verdict_handlers.sh'
    echo c | _intake_handle_split_recommended '${FIXTURE_DIR}/report_split.md'
" >/dev/null 2>&1
rc=$?
assert_eq "SPLIT_RECOMMENDED with 'c' input exits 0" "0" "$rc"

# Scenario 4: NEEDS_CLARITY + COMPLETE_MODE → halt.
echo "Scenario 4 — NEEDS_CLARITY (complete mode → halt)"
verdict=$(_intake_parse_verdict "${FIXTURE_DIR}/report_needs_clarity.md")
assert_eq "NEEDS_CLARITY verdict from fixture" "NEEDS_CLARITY" "$verdict"
# Sub-shell so the `exit 1` from the shim doesn't kill the parent test.
output=$(bash -c "
    TEKHTON_HOME='${TEKHTON_HOME}' TEKHTON_BIN='${TEKHTON_BIN}'
    export TEKHTON_HOME TEKHTON_BIN
    TEKHTON_SESSION_DIR='${TEKHTON_SESSION_DIR}/clarity-halt'
    mkdir -p \"\$TEKHTON_SESSION_DIR\"
    PROJECT_DIR='${TMPROOT}/clarity-halt'
    mkdir -p \"\$PROJECT_DIR\"
    export TEKHTON_SESSION_DIR PROJECT_DIR
    COMPLETE_MODE=true
    CLARIFICATIONS_FILE='${CLARIFICATIONS_FILE}'
    export COMPLETE_MODE CLARIFICATIONS_FILE
    log() { :; }; warn() { :; }; success() { :; }; header() { :; }; error() { :; }
    captured=''
    write_pipeline_state() {
        captured=\"\$1|\$2|\$3|\$4|\$5|\$6\"
        echo \"STATE_CAPTURED:\$captured\"
    }
    source '${TEKHTON_HOME}/lib/intake_helpers.sh'
    source '${TEKHTON_HOME}/lib/intake_verdict_handlers.sh'
    _intake_handle_needs_clarity '${FIXTURE_DIR}/report_needs_clarity.md'
" 2>&1) || true
assert_contains "NEEDS_CLARITY halt forwarded pipeline state" "STATE_CAPTURED:intake|needs_clarity" "$output"
assert_contains "NEEDS_CLARITY halt reason mentions clarifications file" "Intake needs human clarification" "$output"

# --- Wrap-up ----------------------------------------------------------------
echo
echo "────────────────────────────────────────"
echo "  Passed: $PASS  Failed: $FAIL"
echo "────────────────────────────────────────"

[[ $FAIL -eq 0 ]]
