#!/usr/bin/env bash
# Test: Causal event log (lib/causality.sh shim + Go writer or bash fallback)
#
# After m02, lib/causality.sh is a wedge shim that exec's `tekhton causal …`
# when the Go binary is on PATH, and falls back to an inline bash writer when
# it is not. Both paths emit the same `causal.event.v1` JSONL contract, so
# the assertions below cover either backend transparently.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
TIMESTAMP="20260315_100000"
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "$LOG_DIR"

# Stubs for log helpers (the shim itself does not call them, but tests may).
log() { :; }
warn() { :; }
error() { :; }
success() { :; }

# common.sh hosts _json_escape after m02 — source it before causality.sh so
# the bash fallback path can format JSON strings.
# shellcheck source=lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=lib/causality.sh
source "${TEKHTON_HOME}/lib/causality.sh"
# shellcheck source=lib/causality_query.sh
source "${TEKHTON_HOME}/lib/causality_query.sh"

# --- init_causal_log: creates dirs, sets run id ------------------------------
CAUSAL_LOG_ENABLED=true
CAUSAL_LOG_FILE="${TMPDIR}/.claude/logs/CAUSAL_LOG.jsonl"
CAUSAL_LOG_MAX_EVENTS=2000
init_causal_log
[[ -n "$_CURRENT_RUN_ID" ]] || { echo "FAIL: _CURRENT_RUN_ID not set"; exit 1; }
[[ -d "${TMPDIR}/.claude/logs/runs" ]] || { echo "FAIL: runs dir not created"; exit 1; }

# --- emit_event appends valid JSON and returns ID ----------------------------
eid=$(emit_event "pipeline_start" "pipeline" "test task" "" "" "")
[[ "$eid" == "pipeline.001" ]] || { echo "FAIL: expected pipeline.001, got $eid"; exit 1; }
[[ -f "$CAUSAL_LOG_FILE" ]] || { echo "FAIL: log file not created"; exit 1; }
line_count=$(wc -l < "$CAUSAL_LOG_FILE")
[[ "$line_count" -eq 1 ]] || { echo "FAIL: expected 1 line, got $line_count"; exit 1; }

first_line=$(head -1 "$CAUSAL_LOG_FILE")
echo "$first_line" | grep -q '"proto":"tekhton.causal.v1"' || { echo "FAIL: proto envelope missing"; exit 1; }
echo "$first_line" | grep -q '"id":"pipeline.001"' || { echo "FAIL: id field missing"; exit 1; }
echo "$first_line" | grep -q '"type":"pipeline_start"' || { echo "FAIL: type field missing"; exit 1; }
echo "$first_line" | grep -q '"run_id"' || { echo "FAIL: run_id field missing"; exit 1; }
echo "$first_line" | grep -q '"caused_by":\[\]' || { echo "FAIL: caused_by not empty array"; exit 1; }

# --- per-stage monotonic IDs -------------------------------------------------
eid2=$(emit_event "stage_start" "coder" "starting coder" "$eid" "" "")
[[ "$eid2" == "coder.001" ]] || { echo "FAIL: expected coder.001, got $eid2"; exit 1; }
eid3=$(emit_event "stage_end" "coder" "done" "$eid2" "" '{"files":3}')
[[ "$eid3" == "coder.002" ]] || { echo "FAIL: expected coder.002, got $eid3"; exit 1; }

# --- caused_by threading -----------------------------------------------------
line3=$(tail -1 "$CAUSAL_LOG_FILE")
echo "$line3" | grep -q '"caused_by":\["coder.001"\]' || { echo "FAIL: caused_by not threaded"; exit 1; }

# --- _last_event_id returns most recent --------------------------------------
last=$(_last_event_id)
[[ "$last" == "coder.002" ]] || { echo "FAIL: _last_event_id wrong, got $last"; exit 1; }

# --- multiple caused_by ------------------------------------------------------
eid4=$(emit_event "rework_trigger" "review" "changes required" "coder.002,pipeline.001" "" "")
line4=$(tail -1 "$CAUSAL_LOG_FILE")
echo "$line4" | grep -q '"caused_by":\["coder.002","pipeline.001"\]' || { echo "FAIL: multi caused_by"; exit 1; }

# --- emit_event with verdict -------------------------------------------------
eid5=$(emit_event "verdict" "review" "APPROVED" "$eid4" '{"result":"APPROVED"}' "")
line5=$(tail -1 "$CAUSAL_LOG_FILE")
echo "$line5" | grep -q '"verdict":{"result":"APPROVED"}' || { echo "FAIL: verdict not in event"; exit 1; }

# --- events_for_milestone filters correctly ----------------------------------
_CURRENT_MILESTONE="m03"
eid6=$(emit_event "stage_start" "tester" "" "$eid5" "" "")
_CURRENT_MILESTONE=""
eid7=$(emit_event "stage_end" "tester" "" "$eid6" "" "")
m03_events=$(events_for_milestone "m03")
m03_count=$(echo "$m03_events" | grep -c "m03" || true)
[[ "$m03_count" -ge 1 ]] || { echo "FAIL: events_for_milestone found no events"; exit 1; }

# --- events_by_type filters by type ------------------------------------------
type_events=$(events_by_type "stage_start")
type_count=$(echo "$type_events" | grep -c "stage_start" || true)
[[ "$type_count" -ge 2 ]] || { echo "FAIL: events_by_type found fewer than expected"; exit 1; }

# --- trace_cause_chain walks backward ----------------------------------------
chain=$(trace_cause_chain "$eid5")
chain_count=$(echo "$chain" | grep -c "." || true)
[[ "$chain_count" -ge 1 ]] || { echo "FAIL: trace_cause_chain returned empty"; exit 1; }

# --- trace_effect_chain walks forward ----------------------------------------
effects=$(trace_effect_chain "$eid")
effect_count=$(echo "$effects" | grep -c "." || true)
[[ "$effect_count" -ge 1 ]] || { echo "FAIL: trace_effect_chain returned empty"; exit 1; }

# --- cause_chain_summary produces readable output ----------------------------
summary=$(cause_chain_summary "$eid5")
[[ -n "$summary" ]] || { echo "FAIL: cause_chain_summary empty"; exit 1; }
echo "$summary" | grep -q "<-" || { echo "FAIL: summary missing <- separators"; exit 1; }

# --- disabled mode returns synthetic IDs -------------------------------------
CAUSAL_LOG_ENABLED=false
: > "$CAUSAL_LOG_FILE"
rm -rf "${_CAUSAL_SEQ_DIR:-/nonexistent}"/* 2>/dev/null || true
synth_id=$(emit_event "test_disabled" "test" "should not log" "" "" "")
[[ "$synth_id" == "test.001" ]] || { echo "FAIL: synthetic ID wrong, got $synth_id"; exit 1; }
disabled_lines=$(wc -l < "$CAUSAL_LOG_FILE" 2>/dev/null || echo "0")
[[ "$disabled_lines" -eq 0 ]] || { echo "FAIL: disabled mode wrote to log"; exit 1; }
CAUSAL_LOG_ENABLED=true

# --- event cap enforcement ---------------------------------------------------
CAUSAL_LOG_MAX_EVENTS=5
: > "$CAUSAL_LOG_FILE"
rm -rf "${_CAUSAL_SEQ_DIR:-/nonexistent}"/* 2>/dev/null || true
for i in $(seq 1 8); do
    emit_event "test_cap" "cap" "event $i" "" "" "" > /dev/null
done
cap_lines=$(wc -l < "$CAUSAL_LOG_FILE")
cap_lines="${cap_lines## }"
[[ "$cap_lines" -le 5 ]] || { echo "FAIL: event cap not enforced, got $cap_lines lines"; exit 1; }
CAUSAL_LOG_MAX_EVENTS=2000

# --- archive_causal_log copies to runs/ --------------------------------------
: > "$CAUSAL_LOG_FILE"
rm -rf "${_CAUSAL_SEQ_DIR:-/nonexistent}"/* 2>/dev/null || true
emit_event "archive_test" "test" "" "" "" "" > /dev/null
archive_causal_log
archive_file="${LOG_DIR}/runs/CAUSAL_LOG_${_CURRENT_RUN_ID}.jsonl"
[[ -f "$archive_file" ]] || { echo "FAIL: archive not created at $archive_file"; exit 1; }

# --- archive retention prunes old runs ---------------------------------------
# Pre-seed several stale archives, then run archive (which prunes after copy).
CAUSAL_LOG_RETENTION_RUNS=2
for i in $(seq 1 5); do
    echo '{"id":"test"}' > "${LOG_DIR}/runs/CAUSAL_LOG_run_test_${i}.jsonl"
done
archive_causal_log
remaining=$(ls "${LOG_DIR}/runs/"CAUSAL_LOG_*.jsonl 2>/dev/null | wc -l)
remaining="${remaining## }"
[[ "$remaining" -le 3 ]] || { echo "FAIL: pruning failed, $remaining archives remain"; exit 1; }

# --- recurring_pattern counts across archives --------------------------------
for i in $(seq 1 3); do
    echo '{"type":"rework_cycle","run_id":"run_rp_'$i'"}' > "${LOG_DIR}/runs/CAUSAL_LOG_run_rp_${i}.jsonl"
done
pattern_result=$(recurring_pattern "rework_cycle" 5)
pattern_count="${pattern_result%% *}"
[[ "$pattern_count" -ge 3 ]] || { echo "FAIL: recurring_pattern count wrong: $pattern_count"; exit 1; }

# --- verdict_history returns verdict events ----------------------------------
for i in $(seq 1 2); do
    echo '{"type":"verdict","stage":"review","run_id":"run_vh_'$i'"}' > "${LOG_DIR}/runs/CAUSAL_LOG_run_vh_${i}.jsonl"
done
vh_result=$(verdict_history "review" 5)
vh_count=$(echo "$vh_result" | grep -c "verdict" || true)
[[ "$vh_count" -ge 2 ]] || { echo "FAIL: verdict_history found fewer than expected"; exit 1; }

# --- _json_escape (now hosted in common.sh) handles special characters -------
escaped=$(_json_escape 'hello "world"
newline	tab\back')
echo "$escaped" | grep -q '\\\"' || { echo "FAIL: quotes not escaped"; exit 1; }
echo "$escaped" | grep -q '\\n' || { echo "FAIL: newline not escaped"; exit 1; }
echo "$escaped" | grep -q '\\t' || { echo "FAIL: tab not escaped"; exit 1; }
echo "$escaped" | grep -q '\\\\' || { echo "FAIL: backslash not escaped"; exit 1; }

# --- init_causal_log on resumed run preserves existing events ----------------
# Re-init must not clear the log; new events append.
CAUSAL_LOG_ENABLED=true
: > "$CAUSAL_LOG_FILE"
rm -rf "${_CAUSAL_SEQ_DIR:-/nonexistent}"/* 2>/dev/null || true
echo '{"proto":"tekhton.causal.v1","id":"pipeline.001","ts":"2026-01-01T00:00:00Z","run_id":"run_prior","milestone":"","type":"pipeline_start","stage":"pipeline","detail":"prior run","caused_by":[],"verdict":null,"context":null}' >> "$CAUSAL_LOG_FILE"
prior_count=$(wc -l < "$CAUSAL_LOG_FILE")
prior_count="${prior_count## }"
[[ "$prior_count" -eq 1 ]] || { echo "FAIL: setup: expected 1 prior event, got $prior_count"; exit 1; }
TIMESTAMP="20260315_120000"
init_causal_log
post_init_count=$(wc -l < "$CAUSAL_LOG_FILE")
post_init_count="${post_init_count## }"
[[ "$post_init_count" -ge 1 ]] || { echo "FAIL: init_causal_log cleared existing events on resume"; exit 1; }
new_id=$(emit_event "stage_start" "coder" "resumed" "" "" "")
[[ -n "$new_id" ]] || { echo "FAIL: emit_event returned empty ID after resume"; exit 1; }
final_count=$(wc -l < "$CAUSAL_LOG_FILE")
final_count="${final_count## }"
[[ "$final_count" -ge 2 ]] || { echo "FAIL: new event not appended after resume, count=$final_count"; exit 1; }
grep -q '"run_id":"run_prior"' "$CAUSAL_LOG_FILE" || { echo "FAIL: prior run events lost after resume init"; exit 1; }

# --- causal status: direct CLI invocation or bash fallback parse --------------
# Coverage gap from m02 review: `tekhton causal status` had no direct bash test.
# The Go-side lastEventID helper is exercised indirectly through _last_event_id
# in every Go-binary-present run; this section proves both paths explicitly.
#
# Use a fresh, isolated log so this section doesn't depend on earlier test state.
STATUS_LOG="${TMPDIR}/.claude/logs/status_direct_test.jsonl"
mkdir -p "$(dirname "$STATUS_LOG")" 2>/dev/null || true
# Write two fixed events (known IDs, known order) directly — no emit_event fork
# so the test doesn't inherit earlier test sequence numbers.
printf '{"proto":"tekhton.causal.v1","id":"st.001","ts":"2026-01-01T00:00:00Z","run_id":"run_status","milestone":"","type":"ev_a","stage":"st","detail":"","caused_by":[],"verdict":null,"context":null}\n' > "$STATUS_LOG"
printf '{"proto":"tekhton.causal.v1","id":"st.002","ts":"2026-01-01T00:00:01Z","run_id":"run_status","milestone":"","type":"ev_b","stage":"st","detail":"","caused_by":[],"verdict":null,"context":null}\n' >> "$STATUS_LOG"

if command -v tekhton >/dev/null 2>&1; then
    # Happy path: tekhton binary on PATH — invoke `tekhton causal status` directly.
    go_last=$(tekhton causal status --path "$STATUS_LOG" 2>/dev/null)
    [[ "$go_last" == "st.002" ]] || { echo "FAIL: tekhton causal status returned '$go_last', want st.002"; exit 1; }
    # Also verify that an empty log returns an empty string (not an error).
    EMPTY_LOG="${TMPDIR}/.claude/logs/status_empty_test.jsonl"
    : > "$EMPTY_LOG"
    empty_last=$(tekhton causal status --path "$EMPTY_LOG" 2>/dev/null)
    [[ -z "$empty_last" ]] || { echo "FAIL: empty log should return empty string, got '$empty_last'"; exit 1; }
else
    # Go binary not available — exercise the bash fallback branch of _last_event_id.
    prev_causal_log="$CAUSAL_LOG_FILE"
    CAUSAL_LOG_FILE="$STATUS_LOG"
    bash_last=$(_last_event_id)
    CAUSAL_LOG_FILE="$prev_causal_log"
    [[ "$bash_last" == "st.002" ]] || { echo "FAIL: bash _last_event_id fallback returned '$bash_last', want st.002"; exit 1; }
    # Verify missing-file case returns empty (no error exit).
    CAUSAL_LOG_FILE="${TMPDIR}/nonexistent_causal.jsonl"
    missing_last=$(_last_event_id)
    CAUSAL_LOG_FILE="$prev_causal_log"
    [[ -z "$missing_last" ]] || { echo "FAIL: missing log should return empty, got '$missing_last'"; exit 1; }
fi

echo "All causal log tests passed."
