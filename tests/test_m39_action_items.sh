#!/usr/bin/env bash
# =============================================================================
# test_m39_action_items.sh — Coverage gaps from M39 reviewer report
#
# Gap 1: _severity_for_count() — threshold edge cases
#         (count == 0, count == warn, count == crit, between, above).
# Gap 2: emit_dashboard_action_items() — writes data/action_items.js with
#         correct TK_ACTION_ITEMS structure (analogous to M38 patterns).
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

export PROJECT_DIR="$TMPDIR_ROOT"
export TEKHTON_HOME

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Minimal stubs required to source finalize_display.sh without the full pipeline.
# ---------------------------------------------------------------------------
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Source finalize_display.sh (provides _severity_for_count)
# shellcheck source=../lib/finalize_display.sh
source "${TEKHTON_HOME}/lib/finalize_display.sh"

# =============================================================================
# Test Suite 1: _severity_for_count()
# =============================================================================
echo "=== Test Suite 1: _severity_for_count() ==="

# --- 1.1: count=0 → normal ---------------------------------------------------
result=$(_severity_for_count 0 5 10)
if [[ "$result" = "normal" ]]; then
    pass "1.1 count=0 → normal"
else
    fail "1.1 count=0: expected 'normal', got '$result'"
fi

# --- 1.2: count below warn threshold → normal --------------------------------
result=$(_severity_for_count 4 5 10)
if [[ "$result" = "normal" ]]; then
    pass "1.2 count=4 (below warn=5) → normal"
else
    fail "1.2 count=4: expected 'normal', got '$result'"
fi

# --- 1.3: count == warn threshold → warning ----------------------------------
result=$(_severity_for_count 5 5 10)
if [[ "$result" = "warning" ]]; then
    pass "1.3 count=5 (== warn=5) → warning"
else
    fail "1.3 count=5 == warn: expected 'warning', got '$result'"
fi

# --- 1.4: count between warn and crit → warning ------------------------------
result=$(_severity_for_count 7 5 10)
if [[ "$result" = "warning" ]]; then
    pass "1.4 count=7 (between warn=5 and crit=10) → warning"
else
    fail "1.4 count=7: expected 'warning', got '$result'"
fi

# --- 1.5: count one below crit → warning -------------------------------------
result=$(_severity_for_count 9 5 10)
if [[ "$result" = "warning" ]]; then
    pass "1.5 count=9 (crit-1=9) → warning"
else
    fail "1.5 count=9: expected 'warning', got '$result'"
fi

# --- 1.6: count == crit threshold → critical ---------------------------------
result=$(_severity_for_count 10 5 10)
if [[ "$result" = "critical" ]]; then
    pass "1.6 count=10 (== crit=10) → critical"
else
    fail "1.6 count=10 == crit: expected 'critical', got '$result'"
fi

# --- 1.7: count above crit → critical ----------------------------------------
result=$(_severity_for_count 25 5 10)
if [[ "$result" = "critical" ]]; then
    pass "1.7 count=25 (above crit=10) → critical"
else
    fail "1.7 count=25: expected 'critical', got '$result'"
fi

# --- 1.8: default thresholds (warn=5, crit=10) apply when omitted ------------
result=$(_severity_for_count 5)
if [[ "$result" = "warning" ]]; then
    pass "1.8 default warn threshold: count=5 → warning"
else
    fail "1.8 default warn threshold: expected 'warning', got '$result'"
fi

result=$(_severity_for_count 10)
if [[ "$result" = "critical" ]]; then
    pass "1.9 default crit threshold: count=10 → critical"
else
    fail "1.9 default crit threshold: expected 'critical', got '$result'"
fi

result=$(_severity_for_count 0)
if [[ "$result" = "normal" ]]; then
    pass "1.10 default thresholds: count=0 → normal"
else
    fail "1.10 default thresholds: count=0: expected 'normal', got '$result'"
fi

# --- 1.11: equal warn and crit edge (warn == crit) —  critical wins ----------
# When warn == crit == 5, count=5 should be critical (crit check comes first)
result=$(_severity_for_count 5 5 5)
if [[ "$result" = "critical" ]]; then
    pass "1.11 warn == crit == 5, count=5 → critical (crit check wins)"
else
    fail "1.11 warn == crit edge: expected 'critical', got '$result'"
fi

# =============================================================================
# Test Suite 2: emit_dashboard_action_items()
# =============================================================================
echo "=== Test Suite 2: emit_dashboard_action_items() ==="

# ---------------------------------------------------------------------------
# Stubs required to source dashboard_parsers.sh + dashboard_emitters.sh
# ---------------------------------------------------------------------------
is_dashboard_enabled() { return 0; }

_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Source parsers (provides _write_js_file, _to_js_timestamp)
# shellcheck source=../lib/dashboard_parsers.sh
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

# Source emitters (provides emit_dashboard_action_items)
# shellcheck source=../lib/dashboard_emitters.sh
source "${TEKHTON_HOME}/lib/dashboard_emitters.sh"

# Set up dashboard data directory
mkdir -p "$TMPDIR_ROOT/.claude/dashboard/data"
export DASHBOARD_DIR=".claude/dashboard"

ACTION_ITEMS_FILE="$TMPDIR_ROOT/.claude/dashboard/data/action_items.js"

# --- 2.1: Basic structure — all counts zero, all normal ----------------------
# Stub helper functions to return zero counts
count_open_nonblocking_notes() { echo 0; }
has_human_actions()             { return 1; }  # no items
count_human_actions()           { echo 0; }
count_drift_observations()      { echo 0; }

# No HUMAN_NOTES.md → hn_count stays 0
rm -f "$TMPDIR_ROOT/HUMAN_NOTES.md"

export ACTION_ITEMS_WARN_THRESHOLD=5
export ACTION_ITEMS_CRITICAL_THRESHOLD=10
export HUMAN_NOTES_WARN_THRESHOLD=10
export HUMAN_NOTES_CRITICAL_THRESHOLD=20

emit_dashboard_action_items

if [[ ! -f "$ACTION_ITEMS_FILE" ]]; then
    fail "2.1 emit_dashboard_action_items did not create action_items.js"
else
    content=$(cat "$ACTION_ITEMS_FILE")

    # Verify the JS variable name
    if echo "$content" | grep -q 'window\.TK_ACTION_ITEMS'; then
        pass "2.1 action_items.js uses TK_ACTION_ITEMS variable"
    else
        fail "2.1 TK_ACTION_ITEMS variable not found — content: $content"
    fi

    # Verify all four keys are present
    for key in nonblocking human_notes drift human_actions; do
        if echo "$content" | grep -q "\"${key}\""; then
            pass "2.1 key '${key}' present in TK_ACTION_ITEMS"
        else
            fail "2.1 key '${key}' missing from TK_ACTION_ITEMS — content: $content"
        fi
    done

    # All counts should be 0, all severities normal
    if echo "$content" | grep -q '"nonblocking":{"count":0,"severity":"normal"}'; then
        pass "2.1 nonblocking: count=0, severity=normal"
    else
        fail "2.1 nonblocking structure wrong — content: $content"
    fi

    if echo "$content" | grep -q '"human_notes":{"count":0,"severity":"normal"}'; then
        pass "2.1 human_notes: count=0, severity=normal"
    else
        fail "2.1 human_notes structure wrong — content: $content"
    fi

    if echo "$content" | grep -q '"drift":{"count":0}'; then
        pass "2.1 drift: count=0"
    else
        fail "2.1 drift structure wrong — content: $content"
    fi

    if echo "$content" | grep -q '"human_actions":{"count":0}'; then
        pass "2.1 human_actions: count=0"
    else
        fail "2.1 human_actions structure wrong — content: $content"
    fi
fi

# --- 2.2: nonblocking at warning threshold ------------------------------------
count_open_nonblocking_notes() { echo 5; }

emit_dashboard_action_items

content=$(cat "$ACTION_ITEMS_FILE")
if echo "$content" | grep -q '"nonblocking":{"count":5,"severity":"warning"}'; then
    pass "2.2 nonblocking: count=5 (== warn=5) → severity=warning"
else
    fail "2.2 nonblocking warning threshold — content: $content"
fi

# --- 2.3: nonblocking at critical threshold -----------------------------------
count_open_nonblocking_notes() { echo 10; }

emit_dashboard_action_items

content=$(cat "$ACTION_ITEMS_FILE")
if echo "$content" | grep -q '"nonblocking":{"count":10,"severity":"critical"}'; then
    pass "2.3 nonblocking: count=10 (== crit=10) → severity=critical"
else
    fail "2.3 nonblocking critical threshold — content: $content"
fi

# --- 2.4: nonblocking below warn threshold → normal ---------------------------
count_open_nonblocking_notes() { echo 3; }

emit_dashboard_action_items

content=$(cat "$ACTION_ITEMS_FILE")
if echo "$content" | grep -q '"nonblocking":{"count":3,"severity":"normal"}'; then
    pass "2.4 nonblocking: count=3 (below warn=5) → severity=normal"
else
    fail "2.4 nonblocking normal below warn — content: $content"
fi

# --- 2.5: human_notes severity from HUMAN_NOTES.md via get_notes_summary -----
count_open_nonblocking_notes() { echo 0; }

# Create HUMAN_NOTES.md so the hn_count branch fires
cat > "$TMPDIR_ROOT/HUMAN_NOTES.md" << 'EOF'
- [ ] [BUG] Fix login regression
- [ ] [FEAT] Add dark mode
- [ ] [BUG] Crash on startup
EOF

# Stub get_notes_summary: total|bug|feat|polish|checked|unchecked
# unchecked=15 (at warning threshold=10, below crit=20)
get_notes_summary() { echo "15|3|1|0|0|15"; }

emit_dashboard_action_items

content=$(cat "$ACTION_ITEMS_FILE")
if echo "$content" | grep -q '"human_notes":{"count":15,"severity":"warning"}'; then
    pass "2.5 human_notes: count=15 (>= warn=10, < crit=20) → severity=warning"
else
    fail "2.5 human_notes warning severity — content: $content"
fi

# --- 2.6: human_notes at critical threshold -----------------------------------
get_notes_summary() { echo "20|5|5|5|0|20"; }

emit_dashboard_action_items

content=$(cat "$ACTION_ITEMS_FILE")
if echo "$content" | grep -q '"human_notes":{"count":20,"severity":"critical"}'; then
    pass "2.6 human_notes: count=20 (== crit=20) → severity=critical"
else
    fail "2.6 human_notes critical threshold — content: $content"
fi

# --- 2.7: no data dir → returns 0 without creating file ----------------------
rm -rf "$TMPDIR_ROOT/.claude/dashboard"
rm -f "$ACTION_ITEMS_FILE"

emit_dashboard_action_items

if [[ ! -f "$ACTION_ITEMS_FILE" ]]; then
    pass "2.7 emit_dashboard_action_items returns gracefully when data dir absent"
else
    fail "2.7 created file even when data dir missing"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  M39 action items: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[[ "$FAIL" -eq 0 ]] || exit 1
echo "All M39 action items tests passed"
