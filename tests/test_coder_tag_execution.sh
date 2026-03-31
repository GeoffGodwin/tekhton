#!/usr/bin/env bash
# Test: M42 tag-specialized coder execution — scout decision logic,
#       turn budget multiplier calculations, NOTE_TEMPLATE_NAME fallback
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stubs for logging functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Stubs for config.sh helpers (no-op: we're testing defaults, not clamping)
_clamp_config_value() { :; }
_clamp_config_float() { :; }

# --------------------------------------------------------------------------
# Helper: resolve_note_template_name
#   Mirrors the fallback logic in stages/coder.sh (lines 318-329).
#   Sets NOTE_TEMPLATE_NAME to the tag-specific name, or clears it if the
#   file does not exist in TEKHTON_HOME/prompts/.
# --------------------------------------------------------------------------
resolve_note_template_name() {
    local _filter="$1"
    local _home="$2"
    NOTE_TEMPLATE_NAME=""
    case "$_filter" in
        BUG)    NOTE_TEMPLATE_NAME="coder_note_bug" ;;
        FEAT)   NOTE_TEMPLATE_NAME="coder_note_feat" ;;
        POLISH) NOTE_TEMPLATE_NAME="coder_note_polish" ;;
    esac
    if [[ -n "$NOTE_TEMPLATE_NAME" ]] && \
       [[ ! -f "${_home}/prompts/${NOTE_TEMPLATE_NAME}.prompt.md" ]]; then
        NOTE_TEMPLATE_NAME=""
    fi
}

# --------------------------------------------------------------------------
# Helper: compute_scout_decision
#   Mirrors the scout decision case statement in stages/coder.sh (lines 100-146).
#   Outputs "true" or "false" for SHOULD_SCOUT.
#   Arguments: filter  scout_on_value  est_turns  task_text
# --------------------------------------------------------------------------
compute_scout_decision() {
    local _filter="$1"
    local _scout_val="$2"
    local _est_turns="$3"
    local _task_text="$4"
    local _should_scout=false

    case "$_filter" in
        BUG)
            case "$_scout_val" in
                always) _should_scout=true ;;
                auto)   _should_scout=true ;;  # BUG auto = same as always
                never)  _should_scout=false ;;
            esac
            ;;
        FEAT)
            case "$_scout_val" in
                always) _should_scout=true ;;
                auto)
                    if [[ -n "$_est_turns" ]] && [[ "$_est_turns" -gt 10 ]]; then
                        _should_scout=true
                    elif echo "$_task_text" | grep -qiE "extend|add to|modify|integrate|update|change|existing"; then
                        _should_scout=true
                    fi
                    ;;
                never)  _should_scout=false ;;
            esac
            ;;
        POLISH)
            case "$_scout_val" in
                always) _should_scout=true ;;
                auto)
                    if echo "$_task_text" | grep -qiE "extend|add to|modify|integrate|update|change|existing"; then
                        _should_scout=true
                    fi
                    ;;
                never)  _should_scout=false ;;
            esac
            ;;
    esac
    echo "$_should_scout"
}

# --------------------------------------------------------------------------
# Helper: compute_turn_budget
#   Mirrors the tag turn budget calculation in stages/coder.sh (lines 516-548).
#   Sets ADJUSTED_CODER_TURNS based on filter, multiplier, and optional est_turns.
# --------------------------------------------------------------------------
compute_turn_budget() {
    local _filter="$1"
    local _base="$2"
    local _multiplier="$3"
    local _est_turns="$4"

    if [[ -n "$_est_turns" ]] && [[ "$_est_turns" -gt 0 ]]; then
        local _max_from_multiplier
        _max_from_multiplier=$(awk "BEGIN { printf \"%.0f\", ${_base} * ${_multiplier} }")
        local _from_estimate
        _from_estimate=$(awk "BEGIN { v = ${_est_turns} * 1.5; printf \"%.0f\", (v < ${_max_from_multiplier}) ? v : ${_max_from_multiplier} }")
        ADJUSTED_CODER_TURNS="$_from_estimate"
    else
        ADJUSTED_CODER_TURNS=$(awk "BEGIN { printf \"%.0f\", ${_base} * ${_multiplier} }")
    fi

    # Floor at 5
    if [[ "${ADJUSTED_CODER_TURNS:-0}" -lt 5 ]]; then
        ADJUSTED_CODER_TURNS=5
    fi
}

# --------------------------------------------------------------------------
echo "Suite 1: Config defaults for M42 tag-specialized execution"
# --------------------------------------------------------------------------

# Source config_defaults.sh with a clean env (unset any existing values first)
unset SCOUT_ON_BUG SCOUT_ON_FEAT SCOUT_ON_POLISH \
      BUG_TURN_MULTIPLIER FEAT_TURN_MULTIPLIER POLISH_TURN_MULTIPLIER \
      POLISH_SKIP_REVIEW POLISH_SKIP_REVIEW_PATTERNS POLISH_LOGIC_FILE_PATTERNS 2>/dev/null || true

# Provide required variables that config_defaults.sh references
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
CODER_MAX_TURNS=80
ARCHITECT_MAX_TURNS=25
CLEANUP_TRIGGER_THRESHOLD=5
# shellcheck source=../lib/config_defaults.sh
source "${TEKHTON_HOME}/lib/config_defaults.sh"

[[ "${SCOUT_ON_BUG:-}" == "always" ]] \
    && pass "SCOUT_ON_BUG default is 'always'" \
    || fail "SCOUT_ON_BUG default wrong (got: ${SCOUT_ON_BUG:-})"

[[ "${SCOUT_ON_FEAT:-}" == "auto" ]] \
    && pass "SCOUT_ON_FEAT default is 'auto'" \
    || fail "SCOUT_ON_FEAT default wrong (got: ${SCOUT_ON_FEAT:-})"

[[ "${SCOUT_ON_POLISH:-}" == "never" ]] \
    && pass "SCOUT_ON_POLISH default is 'never'" \
    || fail "SCOUT_ON_POLISH default wrong (got: ${SCOUT_ON_POLISH:-})"

[[ "${BUG_TURN_MULTIPLIER:-}" == "1.0" ]] \
    && pass "BUG_TURN_MULTIPLIER default is 1.0" \
    || fail "BUG_TURN_MULTIPLIER default wrong (got: ${BUG_TURN_MULTIPLIER:-})"

[[ "${FEAT_TURN_MULTIPLIER:-}" == "1.0" ]] \
    && pass "FEAT_TURN_MULTIPLIER default is 1.0" \
    || fail "FEAT_TURN_MULTIPLIER default wrong (got: ${FEAT_TURN_MULTIPLIER:-})"

[[ "${POLISH_TURN_MULTIPLIER:-}" == "0.6" ]] \
    && pass "POLISH_TURN_MULTIPLIER default is 0.6" \
    || fail "POLISH_TURN_MULTIPLIER default wrong (got: ${POLISH_TURN_MULTIPLIER:-})"

[[ "${POLISH_SKIP_REVIEW:-}" == "true" ]] \
    && pass "POLISH_SKIP_REVIEW default is true" \
    || fail "POLISH_SKIP_REVIEW default wrong (got: ${POLISH_SKIP_REVIEW:-})"

# --------------------------------------------------------------------------
echo "Suite 2: NOTE_TEMPLATE_NAME fallback when tag-specific template absent"
# --------------------------------------------------------------------------

# 2a: Template files exist in real TEKHTON_HOME — names should resolve
resolve_note_template_name "BUG" "$TEKHTON_HOME"
[[ "$NOTE_TEMPLATE_NAME" == "coder_note_bug" ]] \
    && pass "BUG resolves to coder_note_bug when template exists" \
    || fail "BUG template name wrong (got: ${NOTE_TEMPLATE_NAME:-empty})"

resolve_note_template_name "FEAT" "$TEKHTON_HOME"
[[ "$NOTE_TEMPLATE_NAME" == "coder_note_feat" ]] \
    && pass "FEAT resolves to coder_note_feat when template exists" \
    || fail "FEAT template name wrong (got: ${NOTE_TEMPLATE_NAME:-empty})"

resolve_note_template_name "POLISH" "$TEKHTON_HOME"
[[ "$NOTE_TEMPLATE_NAME" == "coder_note_polish" ]] \
    && pass "POLISH resolves to coder_note_polish when template exists" \
    || fail "POLISH template name wrong (got: ${NOTE_TEMPLATE_NAME:-empty})"

# 2b: Fallback — template files absent → NOTE_TEMPLATE_NAME cleared
FAKE_HOME="$TEST_TMPDIR/fake_tekhton"
mkdir -p "$FAKE_HOME/prompts"
# Only put a generic coder.prompt.md (no tag-specific ones)
touch "$FAKE_HOME/prompts/coder.prompt.md"

resolve_note_template_name "BUG" "$FAKE_HOME"
[[ -z "$NOTE_TEMPLATE_NAME" ]] \
    && pass "NOTE_TEMPLATE_NAME cleared when BUG template file absent" \
    || fail "Expected NOTE_TEMPLATE_NAME empty when BUG template absent (got: $NOTE_TEMPLATE_NAME)"

resolve_note_template_name "FEAT" "$FAKE_HOME"
[[ -z "$NOTE_TEMPLATE_NAME" ]] \
    && pass "NOTE_TEMPLATE_NAME cleared when FEAT template file absent" \
    || fail "Expected NOTE_TEMPLATE_NAME empty when FEAT template absent (got: $NOTE_TEMPLATE_NAME)"

resolve_note_template_name "POLISH" "$FAKE_HOME"
[[ -z "$NOTE_TEMPLATE_NAME" ]] \
    && pass "NOTE_TEMPLATE_NAME cleared when POLISH template file absent" \
    || fail "Expected NOTE_TEMPLATE_NAME empty when POLISH template absent (got: $NOTE_TEMPLATE_NAME)"

# 2c: Unknown tag → NOTE_TEMPLATE_NAME stays empty (no match)
resolve_note_template_name "UNKNOWN" "$TEKHTON_HOME"
[[ -z "$NOTE_TEMPLATE_NAME" ]] \
    && pass "Unknown tag leaves NOTE_TEMPLATE_NAME empty" \
    || fail "Unknown tag should not set NOTE_TEMPLATE_NAME (got: $NOTE_TEMPLATE_NAME)"

# --------------------------------------------------------------------------
echo "Suite 3: Scout decision logic — SCOUT_ON_* config paths"
# --------------------------------------------------------------------------

# BUG: always → scout
result=$(compute_scout_decision "BUG" "always" "" "implement feature X")
[[ "$result" == "true" ]] \
    && pass "BUG + SCOUT_ON_BUG=always → scout" \
    || fail "BUG + SCOUT_ON_BUG=always should scout (got: $result)"

# BUG: auto → scout (same as always for BUG)
result=$(compute_scout_decision "BUG" "auto" "" "fix the bug")
[[ "$result" == "true" ]] \
    && pass "BUG + SCOUT_ON_BUG=auto → scout" \
    || fail "BUG + SCOUT_ON_BUG=auto should scout (got: $result)"

# BUG: never → no scout
result=$(compute_scout_decision "BUG" "never" "" "fix the bug")
[[ "$result" == "false" ]] \
    && pass "BUG + SCOUT_ON_BUG=never → no scout" \
    || fail "BUG + SCOUT_ON_BUG=never should NOT scout (got: $result)"

# FEAT: always → scout
result=$(compute_scout_decision "FEAT" "always" "" "add new dashboard")
[[ "$result" == "true" ]] \
    && pass "FEAT + SCOUT_ON_FEAT=always → scout" \
    || fail "FEAT + SCOUT_ON_FEAT=always should scout (got: $result)"

# FEAT: never → no scout
result=$(compute_scout_decision "FEAT" "never" "" "add new dashboard")
[[ "$result" == "false" ]] \
    && pass "FEAT + SCOUT_ON_FEAT=never → no scout" \
    || fail "FEAT + SCOUT_ON_FEAT=never should NOT scout (got: $result)"

# FEAT: auto + est_turns > 10 → scout
result=$(compute_scout_decision "FEAT" "auto" "15" "add new dashboard")
[[ "$result" == "true" ]] \
    && pass "FEAT + SCOUT_ON_FEAT=auto + est_turns=15 → scout" \
    || fail "FEAT + auto + est_turns=15 should scout (got: $result)"

# FEAT: auto + est_turns = 10 (not > 10) + no brownfield keywords → no scout
result=$(compute_scout_decision "FEAT" "auto" "10" "add new dashboard")
[[ "$result" == "false" ]] \
    && pass "FEAT + SCOUT_ON_FEAT=auto + est_turns=10 + no brownfield → no scout" \
    || fail "FEAT + auto + est_turns=10 (not >10) should NOT scout (got: $result)"

# FEAT: auto + est_turns = 5 + brownfield keyword → scout
result=$(compute_scout_decision "FEAT" "auto" "5" "modify existing config parser")
[[ "$result" == "true" ]] \
    && pass "FEAT + SCOUT_ON_FEAT=auto + brownfield keyword ('modify') → scout" \
    || fail "FEAT + auto + brownfield keyword should scout (got: $result)"

# FEAT: auto + no est_turns + no brownfield keywords → no scout
result=$(compute_scout_decision "FEAT" "auto" "" "add new dashboard widget")
[[ "$result" == "false" ]] \
    && pass "FEAT + SCOUT_ON_FEAT=auto + no est_turns + no brownfield → no scout" \
    || fail "FEAT + auto + no signal should NOT scout (got: $result)"

# POLISH: never → no scout (default)
result=$(compute_scout_decision "POLISH" "never" "" "fix css spacing")
[[ "$result" == "false" ]] \
    && pass "POLISH + SCOUT_ON_POLISH=never → no scout" \
    || fail "POLISH + SCOUT_ON_POLISH=never should NOT scout (got: $result)"

# POLISH: always → scout
result=$(compute_scout_decision "POLISH" "always" "" "fix css spacing")
[[ "$result" == "true" ]] \
    && pass "POLISH + SCOUT_ON_POLISH=always → scout" \
    || fail "POLISH + SCOUT_ON_POLISH=always should scout (got: $result)"

# POLISH: auto + brownfield keyword → scout
result=$(compute_scout_decision "POLISH" "auto" "" "update existing styles for dark mode")
[[ "$result" == "true" ]] \
    && pass "POLISH + SCOUT_ON_POLISH=auto + brownfield keyword ('update') → scout" \
    || fail "POLISH + auto + brownfield keyword should scout (got: $result)"

# POLISH: auto + no brownfield keywords → no scout
result=$(compute_scout_decision "POLISH" "auto" "" "fix css spacing")
[[ "$result" == "false" ]] \
    && pass "POLISH + SCOUT_ON_POLISH=auto + no brownfield → no scout" \
    || fail "POLISH + auto + no brownfield should NOT scout (got: $result)"

# --------------------------------------------------------------------------
echo "Suite 4: Turn budget multiplier calculations"
# --------------------------------------------------------------------------

# POLISH, no estimate: 80 * 0.6 = 48
compute_turn_budget "POLISH" 80 0.6 ""
[[ "$ADJUSTED_CODER_TURNS" -eq 48 ]] \
    && pass "POLISH no-estimate: 80 × 0.6 = 48" \
    || fail "POLISH no-estimate: expected 48, got $ADJUSTED_CODER_TURNS"

# BUG, no estimate: 80 * 1.0 = 80
compute_turn_budget "BUG" 80 1.0 ""
[[ "$ADJUSTED_CODER_TURNS" -eq 80 ]] \
    && pass "BUG no-estimate: 80 × 1.0 = 80" \
    || fail "BUG no-estimate: expected 80, got $ADJUSTED_CODER_TURNS"

# FEAT, no estimate: 80 * 1.0 = 80
compute_turn_budget "FEAT" 80 1.0 ""
[[ "$ADJUSTED_CODER_TURNS" -eq 80 ]] \
    && pass "FEAT no-estimate: 80 × 1.0 = 80" \
    || fail "FEAT no-estimate: expected 80, got $ADJUSTED_CODER_TURNS"

# POLISH, est_turns=10: min(10*1.5=15, 80*0.6=48) = 15
compute_turn_budget "POLISH" 80 0.6 10
[[ "$ADJUSTED_CODER_TURNS" -eq 15 ]] \
    && pass "POLISH est=10: min(15, 48) = 15 (estimate wins)" \
    || fail "POLISH est=10: expected 15, got $ADJUSTED_CODER_TURNS"

# POLISH, est_turns=40: min(40*1.5=60, 80*0.6=48) = 48 (cap wins)
compute_turn_budget "POLISH" 80 0.6 40
[[ "$ADJUSTED_CODER_TURNS" -eq 48 ]] \
    && pass "POLISH est=40: min(60, 48) = 48 (multiplier cap wins)" \
    || fail "POLISH est=40: expected 48, got $ADJUSTED_CODER_TURNS"

# BUG, est_turns=20: min(20*1.5=30, 80*1.0=80) = 30
compute_turn_budget "BUG" 80 1.0 20
[[ "$ADJUSTED_CODER_TURNS" -eq 30 ]] \
    && pass "BUG est=20: min(30, 80) = 30 (estimate wins)" \
    || fail "BUG est=20: expected 30, got $ADJUSTED_CODER_TURNS"

# Floor: very small base with small multiplier → floor 5
compute_turn_budget "POLISH" 6 0.6 ""
# 6 * 0.6 = 3.6 → rounded to 4 → but 4 < 5 → floor to 5
[[ "$ADJUSTED_CODER_TURNS" -ge 5 ]] \
    && pass "Turn floor: result < 5 is raised to minimum 5" \
    || fail "Turn floor: expected ≥ 5, got $ADJUSTED_CODER_TURNS"

# Floor: est * 1.5 rounds below 5 → floor 5
compute_turn_budget "BUG" 80 1.0 2
# 2 * 1.5 = 3 → floor to 5
[[ "$ADJUSTED_CODER_TURNS" -ge 5 ]] \
    && pass "Turn floor with tiny estimate: floored to 5" \
    || fail "Turn floor with tiny estimate: expected ≥ 5, got $ADJUSTED_CODER_TURNS"

# --------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
