#!/usr/bin/env bash
# =============================================================================
# test_run_summary_reconstruct.sh — Verify the finalize-subprocess Run
# Summary reconstruction from .tekhton/stage_results/ envelopes.
#
# Regression for the M24 dogfood observation (2026-05-26): the final
# "Run Summary" printed at the end of every pipeline showed 0 turns / 0m0s
# because the V4 m18 stagerunner spawns each stage in its own bash
# subprocess; the in-process TOTAL_TURNS/TOTAL_TIME accumulators reset
# between stages and the finalize subprocess starts fresh. The Go runner
# already collects per-stage agent_calls + duration_sec into stage
# envelopes — this helper aggregates them so print_run_summary renders
# real cumulative totals.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PROJECT_DIR="$TMP"
TEKHTON_DIR="$TMP/.tekhton"
export PROJECT_DIR TEKHTON_DIR
mkdir -p "${TEKHTON_DIR}/stage_results"

# Stub logging from common.sh so tests don't pollute stdout with TUI noise.
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# shellcheck source=lib/run_summary_reconstruct.sh
source "${TEKHTON_HOME}/lib/run_summary_reconstruct.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then pass "$name"
    else fail "$name — want '${want}', got '${got}'"
    fi
}

# Seed a representative full pipeline run.
write_envelope() {
    local stage="$1" calls="$2" dur="$3"
    cat > "${TEKHTON_DIR}/stage_results/stage_${stage}_r1_b0.json" <<EOF
{
  "proto": "tekhton.stage.result.v1",
  "stage": "${stage}",
  "verdict": "pass",
  "exit_reason": "exit=0",
  "agent_calls": ${calls},
  "duration_sec": ${dur},
  "human_action_required": false
}
EOF
}

echo "=== Suite 1: happy path — standard pipeline order ==="
write_envelope intake   1 50
write_envelope coder    3 8616
write_envelope security 1 170
write_envelope review   3 493
write_envelope tester   2 491

TOTAL_TURNS=0; TOTAL_TIME=0; STAGE_SUMMARY=""
_reconstruct_run_summary_from_stage_results

assert_eq "1.1 TOTAL_TURNS sums to 1+3+1+3+2=10" "10" "$TOTAL_TURNS"
assert_eq "1.2 TOTAL_TIME sums to 50+8616+170+493+491=9820" "9820" "$TOTAL_TIME"

# STAGE_SUMMARY ordered by the canonical pipeline order so operators read
# left-to-right matching their pipeline view.
echo -e "$STAGE_SUMMARY" | grep -q "Intake: 1 agent calls" && pass "1.3 Intake row present" \
    || fail "1.3 Intake row missing"
echo -e "$STAGE_SUMMARY" | grep -q "Coder: 3 agent calls, 143m" && pass "1.4 Coder row with minutes" \
    || fail "1.4 Coder row wrong: $(echo -e "$STAGE_SUMMARY")"
echo -e "$STAGE_SUMMARY" | grep -q "Tester: 2 agent calls" && pass "1.5 Tester row present" \
    || fail "1.5 Tester row missing"

# Stable canonical order — intake before coder before security before
# review before tester. If a refactor swaps the order, operators reading
# the summary will see stages in a non-pipeline sequence and may misread
# which stage spent what.
_intake_pos=$(echo -e "$STAGE_SUMMARY" | grep -n "Intake:" | cut -d: -f1)
_tester_pos=$(echo -e "$STAGE_SUMMARY" | grep -n "Tester:" | cut -d: -f1)
if [[ -n "$_intake_pos" ]] && [[ -n "$_tester_pos" ]] && [[ "$_intake_pos" -lt "$_tester_pos" ]]; then
    pass "1.6 Intake appears before Tester (canonical pipeline order)"
else
    fail "1.6 Order broken: intake=${_intake_pos} tester=${_tester_pos}"
fi

echo "=== Suite 2: empty stage_results directory — defensive zero ==="
rm -f "${TEKHTON_DIR}/stage_results"/*.json
TOTAL_TURNS=0; TOTAL_TIME=0; STAGE_SUMMARY=""
_reconstruct_run_summary_from_stage_results
assert_eq "2.1 empty dir leaves TOTAL_TURNS=0" "0" "$TOTAL_TURNS"
assert_eq "2.2 empty dir leaves TOTAL_TIME=0" "0" "$TOTAL_TIME"
assert_eq "2.3 empty dir leaves STAGE_SUMMARY empty" "" "$STAGE_SUMMARY"

echo "=== Suite 3: multiple review cycles sum into same stage row ==="
# When the pipeline goes coder → review → coder (review_cycle=2), the
# coder runs twice. The Go runner writes stage_coder_r1_b0.json and
# stage_coder_r2_b0.json. Both must accumulate into one "Coder:" row.
write_envelope coder 2 100
# Override the per-cycle file with a r2 counterpart.
cat > "${TEKHTON_DIR}/stage_results/stage_coder_r2_b0.json" <<'EOF'
{
  "proto": "tekhton.stage.result.v1",
  "stage": "coder",
  "verdict": "pass",
  "exit_reason": "exit=0",
  "agent_calls": 1,
  "duration_sec": 60,
  "human_action_required": false
}
EOF
TOTAL_TURNS=0; TOTAL_TIME=0; STAGE_SUMMARY=""
_reconstruct_run_summary_from_stage_results
assert_eq "3.1 multi-cycle coder turns sum (2+1=3)" "3" "$TOTAL_TURNS"
assert_eq "3.2 multi-cycle coder time sum (100+60=160)" "160" "$TOTAL_TIME"

# Output should have ONE "Coder:" row, not two — confirms the per-stage
# aggregation works rather than emitting a row per file.
coder_row_count=$(echo -e "$STAGE_SUMMARY" | grep -c "Coder:" || true)
assert_eq "3.3 single Coder row despite two envelopes" "1" "$coder_row_count"

echo "=== Suite 4: non-canonical stage name appended at end ==="
rm -f "${TEKHTON_DIR}/stage_results"/*.json
write_envelope intake 1 10
write_envelope custom_stage 1 20
TOTAL_TURNS=0; TOTAL_TIME=0; STAGE_SUMMARY=""
_reconstruct_run_summary_from_stage_results
assert_eq "4.1 totals include non-canonical stage" "2" "$TOTAL_TURNS"
echo -e "$STAGE_SUMMARY" | grep -q "Custom_stage:" && pass "4.2 non-canonical stage row appears" \
    || fail "4.2 non-canonical stage missing: $(echo -e "$STAGE_SUMMARY")"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
