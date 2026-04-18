#!/usr/bin/env bash
# =============================================================================
# test_tui_no_dead_weight.sh — Note 1: Verify redundant "stage" key is gone
#
# Verifies that _tui_json_build_status no longer emits the redundant "stage"
# key that was identical to "stage_label" (dead weight removed by coder).
# The Python renderer uses only stage_label, stage_num, and stage_total.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/tui_helpers.sh"

FAIL=0

# Verify JSON output does not contain a "stage" key
_TUI_CURRENT_STAGE_LABEL="coder"
_TUI_CURRENT_STAGE_NUM="1"
_TUI_CURRENT_STAGE_TOTAL="3"
_TUI_AGENT_STATUS="running"
_CURRENT_RUN_ID="test_run_123"
_TUI_RECENT_EVENTS=()
export _TUI_CURRENT_STAGE_LABEL _TUI_CURRENT_STAGE_NUM _TUI_CURRENT_STAGE_TOTAL
export _TUI_AGENT_STATUS _CURRENT_RUN_ID _TUI_RECENT_EVENTS

# Get the JSON output
json_output=$(_tui_json_build_status 0)

# Verify it's valid JSON
if ! echo "$json_output" | python3 -m json.tool >/dev/null 2>&1; then
    echo "FAIL: JSON output is not valid JSON"
    echo "Output: $json_output"
    FAIL=1
else
    echo "ok: JSON output is valid"
fi

# Verify no redundant "stage" key exists (parsing with jq to be sure)
if command -v jq &>/dev/null; then
    # Check that "stage" key does NOT exist at root level
    if echo "$json_output" | jq 'has("stage")' 2>/dev/null | grep -q "true"; then
        echo "FAIL: Redundant 'stage' key still present in output"
        FAIL=1
    else
        echo "ok: No redundant 'stage' key found"
    fi

    # Verify that stage_label DOES exist
    if ! echo "$json_output" | jq -e '.stage_label' >/dev/null 2>&1; then
        echo "FAIL: 'stage_label' key not found"
        FAIL=1
    else
        echo "ok: 'stage_label' key exists"
    fi

    # Verify that stage_num and stage_total exist
    if ! echo "$json_output" | jq -e '.stage_num' >/dev/null 2>&1; then
        echo "FAIL: 'stage_num' key not found"
        FAIL=1
    else
        echo "ok: 'stage_num' key exists"
    fi

    if ! echo "$json_output" | jq -e '.stage_total' >/dev/null 2>&1; then
        echo "FAIL: 'stage_total' key not found"
        FAIL=1
    else
        echo "ok: 'stage_total' key exists"
    fi
else
    # Fallback: basic string check without jq
    if echo "$json_output" | grep -q '"stage":'; then
        echo "FAIL: Redundant 'stage' key still present in output"
        echo "Output: $json_output"
        FAIL=1
    else
        echo "ok: No redundant 'stage' key found (string-based check)"
    fi

    if ! echo "$json_output" | grep -q '"stage_label"'; then
        echo "FAIL: 'stage_label' key not found"
        FAIL=1
    else
        echo "ok: 'stage_label' key exists"
    fi
fi

echo
if [ "$FAIL" -ne 0 ]; then
    echo "test_tui_no_dead_weight: FAILED"
    exit 1
fi
echo "test_tui_no_dead_weight: PASSED"
