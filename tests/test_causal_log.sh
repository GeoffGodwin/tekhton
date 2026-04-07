#!/usr/bin/env bash
# Test: Causal event log (lib/causality.sh)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Minimal stubs -----------------------------------------------------------
PROJECT_DIR="$TMPDIR"
TIMESTAMP="20260315_100000"
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "$LOG_DIR"

# Stub functions expected by causality.sh
log() { :; }
warn() { :; }
error() { :; }
success() { :; }

# Source the module under test
source "${TEKHTON_HOME}/lib/causality.sh"
source "${TEKHTON_HOME}/lib/causality_query.sh"

# --- Test: init_causal_log creates directory and sets run ID ---
CAUSAL_LOG_ENABLED=true
CAUSAL_LOG_FILE="${TMPDIR}/.claude/logs/CAUSAL_LOG.jsonl"
CAUSAL_LOG_MAX_EVENTS=2000
init_causal_log
[[ -n "$_CURRENT_RUN_ID" ]] || { echo "FAIL: _CURRENT_RUN_ID not set"; exit 1; }
[[ -d "${TMPDIR}/.claude/logs/runs" ]] || { echo "FAIL: runs dir not created"; exit 1; }

# --- Test: emit_event appends valid JSON and returns ID ---
eid=$(emit_event "pipeline_start" "pipeline" "test task" "" "" "")
[[ "$eid" == "pipeline.001" ]] || { echo "FAIL: expected pipeline.001, got $eid"; exit 1; }
[[ -f "$CAUSAL_LOG_FILE" ]] || { echo "FAIL: log file not created"; exit 1; }
line_count=$(wc -l < "$CAUSAL_LOG_FILE")
[[ "$line_count" -eq 1 ]] || { echo "FAIL: expected 1 line, got $line_count"; exit 1; }

# Validate JSON structure
first_line=$(head -1 "$CAUSAL_LOG_FILE")
echo "$first_line" | grep -q '"id":"pipeline.001"' || { echo "FAIL: id field missing"; exit 1; }
echo "$first_line" | grep -q '"type":"pipeline_start"' || { echo "FAIL: type field missing"; exit 1; }
echo "$first_line" | grep -q '"run_id"' || { echo "FAIL: run_id field missing"; exit 1; }
echo "$first_line" | grep -q '"caused_by":\[\]' || { echo "FAIL: caused_by not empty array"; exit 1; }

# --- Test: event IDs are unique and per-stage ---
eid2=$(emit_event "stage_start" "coder" "starting coder" "$eid" "" "")
[[ "$eid2" == "coder.001" ]] || { echo "FAIL: expected coder.001, got $eid2"; exit 1; }
eid3=$(emit_event "stage_end" "coder" "done" "$eid2" "" '{"files":3}')
[[ "$eid3" == "coder.002" ]] || { echo "FAIL: expected coder.002, got $eid3"; exit 1; }

# --- Test: caused_by threading ---
line3=$(tail -1 "$CAUSAL_LOG_FILE")
echo "$line3" | grep -q '"caused_by":\["coder.001"\]' || { echo "FAIL: caused_by not threaded"; exit 1; }

# --- Test: _last_event_id returns most recent ---
last=$(_last_event_id)
[[ "$last" == "coder.002" ]] || { echo "FAIL: _last_event_id wrong, got $last"; exit 1; }

# --- Test: multiple caused_by ---
eid4=$(emit_event "rework_trigger" "review" "changes required" "coder.002,pipeline.001" "" "")
line4=$(tail -1 "$CAUSAL_LOG_FILE")
echo "$line4" | grep -q '"caused_by":\["coder.002","pipeline.001"\]' || { echo "FAIL: multi caused_by"; exit 1; }

# --- Test: emit_event with verdict ---
eid5=$(emit_event "verdict" "review" "APPROVED" "$eid4" '{"result":"APPROVED"}' "")
line5=$(tail -1 "$CAUSAL_LOG_FILE")
echo "$line5" | grep -q '"verdict":{"result":"APPROVED"}' || { echo "FAIL: verdict not in event"; exit 1; }

# --- Test: events_for_milestone filters correctly ---
_CURRENT_MILESTONE="m03"
eid6=$(emit_event "stage_start" "tester" "" "$eid5" "" "")
_CURRENT_MILESTONE=""
eid7=$(emit_event "stage_end" "tester" "" "$eid6" "" "")
m03_events=$(events_for_milestone "m03")
m03_count=$(echo "$m03_events" | grep -c "m03" || true)
[[ "$m03_count" -ge 1 ]] || { echo "FAIL: events_for_milestone found no events"; exit 1; }

# --- Test: events_by_type filters by type ---
type_events=$(events_by_type "stage_start")
type_count=$(echo "$type_events" | grep -c "stage_start" || true)
[[ "$type_count" -ge 2 ]] || { echo "FAIL: events_by_type found fewer than expected"; exit 1; }

# --- Test: trace_cause_chain walks backward ---
chain=$(trace_cause_chain "$eid5")
chain_count=$(echo "$chain" | grep -c "." || true)
[[ "$chain_count" -ge 1 ]] || { echo "FAIL: trace_cause_chain returned empty"; exit 1; }

# --- Test: trace_effect_chain walks forward ---
effects=$(trace_effect_chain "$eid")
effect_count=$(echo "$effects" | grep -c "." || true)
[[ "$effect_count" -ge 1 ]] || { echo "FAIL: trace_effect_chain returned empty"; exit 1; }

# --- Test: cause_chain_summary produces readable output ---
summary=$(cause_chain_summary "$eid5")
[[ -n "$summary" ]] || { echo "FAIL: cause_chain_summary empty"; exit 1; }
echo "$summary" | grep -q "<-" || { echo "FAIL: summary missing <- separators"; exit 1; }

# --- Test: disabled mode returns synthetic IDs ---
CAUSAL_LOG_ENABLED=false
: > "$CAUSAL_LOG_FILE"  # clear
synth_id=$(emit_event "test_disabled" "test" "should not log" "" "" "")
[[ "$synth_id" == "test.001" ]] || { echo "FAIL: synthetic ID wrong, got $synth_id"; exit 1; }
disabled_lines=$(wc -l < "$CAUSAL_LOG_FILE" 2>/dev/null || echo "0")
[[ "$disabled_lines" -eq 0 ]] || { echo "FAIL: disabled mode wrote to log"; exit 1; }
CAUSAL_LOG_ENABLED=true

# --- Test: event cap enforcement ---
CAUSAL_LOG_MAX_EVENTS=5
: > "$CAUSAL_LOG_FILE"
_CAUSAL_EVENT_COUNT=0
rm -rf "$_CAUSAL_SEQ_DIR"/* 2>/dev/null || true
for i in $(seq 1 8); do
    emit_event "test_cap" "cap" "event $i" "" "" "" > /dev/null
done
cap_lines=$(wc -l < "$CAUSAL_LOG_FILE")
cap_lines="${cap_lines## }"
[[ "$cap_lines" -le 5 ]] || { echo "FAIL: event cap not enforced, got $cap_lines lines"; exit 1; }
CAUSAL_LOG_MAX_EVENTS=2000

# --- Test: archive_causal_log copies to runs/ ---
: > "$CAUSAL_LOG_FILE"
_CAUSAL_EVENT_COUNT=0
rm -rf "$_CAUSAL_SEQ_DIR"/* 2>/dev/null || true
emit_event "archive_test" "test" "" "" "" "" > /dev/null
archive_causal_log
archive_file="${LOG_DIR}/runs/CAUSAL_LOG_${_CURRENT_RUN_ID}.jsonl"
[[ -f "$archive_file" ]] || { echo "FAIL: archive not created at $archive_file"; exit 1; }

# --- Test: prune archives beyond retention ---
CAUSAL_LOG_RETENTION_RUNS=2
for i in $(seq 1 5); do
    echo '{"id":"test"}' > "${LOG_DIR}/runs/CAUSAL_LOG_run_test_${i}.jsonl"
done
_prune_causal_archives
remaining=$(ls "${LOG_DIR}/runs/"CAUSAL_LOG_*.jsonl 2>/dev/null | wc -l)
remaining="${remaining## }"
[[ "$remaining" -le 3 ]] || { echo "FAIL: pruning failed, $remaining archives remain"; exit 1; }

# --- Test: recurring_pattern counts across archives ---
for i in $(seq 1 3); do
    echo '{"type":"rework_cycle","run_id":"run_rp_'$i'"}' > "${LOG_DIR}/runs/CAUSAL_LOG_run_rp_${i}.jsonl"
done
pattern_result=$(recurring_pattern "rework_cycle" 5)
pattern_count="${pattern_result%% *}"
[[ "$pattern_count" -ge 3 ]] || { echo "FAIL: recurring_pattern count wrong: $pattern_count"; exit 1; }

# --- Test: verdict_history returns verdict events ---
for i in $(seq 1 2); do
    echo '{"type":"verdict","stage":"review","run_id":"run_vh_'$i'"}' > "${LOG_DIR}/runs/CAUSAL_LOG_run_vh_${i}.jsonl"
done
vh_result=$(verdict_history "review" 5)
vh_count=$(echo "$vh_result" | grep -c "verdict" || true)
[[ "$vh_count" -ge 2 ]] || { echo "FAIL: verdict_history found fewer than expected"; exit 1; }

# --- Test: JSON escape handles special characters ---
escaped=$(_json_escape 'hello "world"
newline	tab\back')
echo "$escaped" | grep -q '\\\"' || { echo "FAIL: quotes not escaped"; exit 1; }
echo "$escaped" | grep -q '\\n' || { echo "FAIL: newline not escaped"; exit 1; }
echo "$escaped" | grep -q '\\t' || { echo "FAIL: tab not escaped"; exit 1; }
echo "$escaped" | grep -q '\\\\' || { echo "FAIL: backslash not escaped"; exit 1; }

# --- Test: init_causal_log on resumed run preserves existing events -----------
# A resumed run re-calls init_causal_log() on an existing non-empty log.
# The function must not clear the log — it only resets in-memory state.
CAUSAL_LOG_ENABLED=true
: > "$CAUSAL_LOG_FILE"
_CAUSAL_EVENT_COUNT=0
rm -rf "$_CAUSAL_SEQ_DIR"/* 2>/dev/null || true
# Emit a "prior run" event directly into the log file (simulating a pre-existing run)
echo '{"id":"pipeline.001","ts":"2026-01-01T00:00:00Z","run_id":"run_prior","milestone":"","type":"pipeline_start","stage":"pipeline","detail":"prior run","caused_by":[],"verdict":null,"context":null}' >> "$CAUSAL_LOG_FILE"
prior_count=$(wc -l < "$CAUSAL_LOG_FILE")
prior_count="${prior_count## }"
[[ "$prior_count" -eq 1 ]] || { echo "FAIL: setup: expected 1 prior event, got $prior_count"; exit 1; }
# Re-initialize (simulates resume)
TIMESTAMP="20260315_120000"
init_causal_log
# Log file must still contain the prior event
post_init_count=$(wc -l < "$CAUSAL_LOG_FILE")
post_init_count="${post_init_count## }"
[[ "$post_init_count" -ge 1 ]] || { echo "FAIL: init_causal_log cleared existing events on resume"; exit 1; }
# New events emitted after re-init must append, not replace
new_id=$(emit_event "stage_start" "coder" "resumed" "" "" "")
[[ -n "$new_id" ]] || { echo "FAIL: emit_event returned empty ID after resume"; exit 1; }
final_count=$(wc -l < "$CAUSAL_LOG_FILE")
final_count="${final_count## }"
[[ "$final_count" -ge 2 ]] || { echo "FAIL: new event not appended after resume, count=$final_count"; exit 1; }
# Prior event must still be present
grep -q '"run_id":"run_prior"' "$CAUSAL_LOG_FILE" || { echo "FAIL: prior run events lost after resume init"; exit 1; }

# --- Test: trace_effect_chain known false-positive via detail field -----------
# KNOWN LIMITATION: trace_effect_chain uses grep -F "\"$current\"" which matches
# any JSON field, not just caused_by. An event whose detail field contains an
# event ID string will be treated as a descendant even without a causal edge.
# This test documents the behavior so future refactors can verify it.
CAUSAL_LOG_ENABLED=true
: > "$CAUSAL_LOG_FILE"
_CAUSAL_EVENT_COUNT=0
rm -rf "$_CAUSAL_SEQ_DIR"/* 2>/dev/null || true
root_id=$(emit_event "stage_end" "coder" "finished" "" "" "")
# This event has coder.001 in its detail string but no causal edge
fp_id=$(emit_event "stage_start" "review" "checking output of ${root_id}" "" "" "")
# This event has a real causal edge
real_id=$(emit_event "verdict" "review" "approved" "$root_id" "" "")
effects=$(trace_effect_chain "$root_id")
# The real effect (causal edge) must be found
echo "$effects" | grep -q "\"id\":\"${real_id}\"" || { echo "FAIL: trace_effect_chain missed real causal descendant"; exit 1; }
# KNOWN LIMITATION: the false-positive event (matching detail field) is also returned.
# This assertion documents the current behavior; if it starts failing, the
# implementation has been improved to do field-specific matching.
fp_found=false
if echo "$effects" | grep -q "\"id\":\"${fp_id}\""; then
    fp_found=true
fi
# We do not fail the test either way — we just record which behavior is active.
# The behavior is documented here for future reference.
if [[ "$fp_found" = "true" ]]; then
    : # Known false-positive present — documented limitation
fi

echo "All causal log tests passed."
