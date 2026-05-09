#!/usr/bin/env bash
# =============================================================================
# test_fix_nonblockers_post_loop_refresh.sh
#
# Regression test for the --fix-nonblockers stale-action-items bug.
#
# Bug: _run_fix_nonblockers_loop in tekhton-legacy.sh exits on the
# break-on-zero check at the top of each iteration, skipping a final
# finalize_run. The previous pass's emit_dashboard_action_items and
# _print_action_items were called before the resolution had fully
# settled, so both the dashboard's action_items.js and the terminal
# "Action Items" banner kept showing the pre-run count.
#
# Fix: after the loop exits (any path — break-on-zero, max-passes,
# wall-clock timeout, usage threshold), re-emit the dashboard data
# and re-print the terminal summary.
#
# This test asserts:
#   1. After the loop's break-on-zero exit, emit_dashboard_action_items
#      and _print_action_items are both invoked.
#   2. The dashboard's action_items.js reflects post-loop state (count 0
#      when all items have been resolved).
#   3. The terminal banner from _print_action_items shows count 0 in
#      the same scenario.
# =============================================================================

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" = "$actual" ]]; then
        pass "$name"
    else
        fail "$name — expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name — '$needle' not found in: $haystack"
    fi
}

# -----------------------------------------------------------------------------
# Test environment scaffolding
# -----------------------------------------------------------------------------
export PROJECT_DIR="$TMPDIR"
export TEKHTON_DIR=".tekhton"
export NON_BLOCKING_LOG_FILE="${TEKHTON_DIR}/NON_BLOCKING_LOG.md"
export CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
export REVIEWER_REPORT_FILE="${TEKHTON_DIR}/REVIEWER_REPORT.md"
export JR_CODER_SUMMARY_FILE="${TEKHTON_DIR}/JR_CODER_SUMMARY.md"
export TESTER_REPORT_FILE="${TEKHTON_DIR}/TESTER_REPORT.md"
export LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "$LOG_DIR" "${TMPDIR}/${TEKHTON_DIR}"

# Source only what the loop body strictly needs. Anything else is stubbed.
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/drift_cleanup.sh"

# -----------------------------------------------------------------------------
# Stubs — capture call sequence to a file so the trace survives the
# command-substitution subshell that runs the loop body.
# -----------------------------------------------------------------------------
CALL_LOG_FILE="${TMPDIR}/call_log"
: > "$CALL_LOG_FILE"

_run_pipeline_stages() {
    echo "pipeline_stages" >> "$CALL_LOG_FILE"
    return 0
}

finalize_run() {
    echo "finalize_run:$1" >> "$CALL_LOG_FILE"
    return 0
}

emit_dashboard_action_items() {
    echo "emit_dashboard_action_items" >> "$CALL_LOG_FILE"
    # Mirror the production behaviour relevant to this test: write a tiny
    # action_items.js so the assertion can check post-loop state.
    local dash_dir="${PROJECT_DIR}/${DASHBOARD_DIR:-.claude/dashboard}"
    mkdir -p "${dash_dir}/data"
    local nb_count
    nb_count=$(count_open_nonblocking_notes 2>/dev/null || echo 0)
    printf 'window.TK_ACTION_ITEMS={"nonblocking":{"count":%d}};\n' \
        "$nb_count" > "${dash_dir}/data/action_items.js"
    return 0
}

_print_action_items() {
    echo "print_action_items" >> "$CALL_LOG_FILE"
    local nb_count
    nb_count=$(count_open_nonblocking_notes 2>/dev/null || echo 0)
    # Mimic the real banner so the test can assert the shown count.
    printf '[banner] %s — %d accumulated observation(s)\n' \
        "${NON_BLOCKING_LOG_FILE}" "$nb_count"
}

count_log_entries() {
    grep -c "^$1\$" "$CALL_LOG_FILE" 2>/dev/null || true
}

check_usage_threshold() { return 0; }
out_set_context() { :; }
out_reset_pass() { :; }
tui_append_event() { :; }
log() { :; }
warn() { :; }
success() { :; }

# -----------------------------------------------------------------------------
# Extract _run_fix_nonblockers_loop from tekhton-legacy.sh and eval it.
# -----------------------------------------------------------------------------
fn_def=$(awk '
    /^_run_fix_nonblockers_loop\(\) \{/ { capture=1 }
    capture { print }
    capture && /^\}$/ { exit }
' "${TEKHTON_HOME}/tekhton-legacy.sh")

if [[ -z "$fn_def" ]]; then
    fail "could not extract _run_fix_nonblockers_loop from tekhton-legacy.sh"
    exit 1
fi
eval "$fn_def"

# -----------------------------------------------------------------------------
# Phase 1: Break-on-zero — fixture has zero open items from the start.
# After loop exit, dashboard + terminal must reflect the post-loop state.
# -----------------------------------------------------------------------------
NB_FILE="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
cat > "$NB_FILE" << 'EOF'
# Non-Blocking Notes Log

## Open

## Resolved
- [x] Old resolved item
EOF

: > "$CALL_LOG_FILE"
output=$(_run_fix_nonblockers_loop 2>&1)

# Post-loop refresh must have fired, even though no pass actually ran.
assert_eq "1.1 emit_dashboard_action_items called after loop exits with count=0" \
    "1" "$(count_log_entries 'emit_dashboard_action_items')"
assert_eq "1.2 _print_action_items called after loop exits with count=0" \
    "1" "$(count_log_entries 'print_action_items')"

# Dashboard data file must show count 0.
DASH_FILE="${PROJECT_DIR}/.claude/dashboard/data/action_items.js"
if [[ -f "$DASH_FILE" ]]; then
    if grep -q '"count":0' "$DASH_FILE"; then
        pass "1.3 action_items.js shows count 0 after loop exit"
    else
        fail "1.3 action_items.js does not show count 0 — content: $(cat "$DASH_FILE")"
    fi
else
    fail "1.3 action_items.js was not written"
fi

# Terminal banner output must reference the post-loop count.
assert_contains "1.4 terminal banner shows count 0" \
    "0 accumulated observation(s)" "$output"

# -----------------------------------------------------------------------------
# Phase 2: All resolved during a pass — start with N items, the stubbed
# pipeline marks them all [x], the loop's next iteration sees count=0 and
# breaks. The post-loop refresh must reflect the post-resolution count.
# -----------------------------------------------------------------------------
cat > "$NB_FILE" << 'EOF'
# Non-Blocking Notes Log

## Open
- [ ] [lib/foo.dart:42] Missing null check
- [ ] [lib/bar.dart:10] Consider renaming variable

## Resolved
EOF

# Replace the pipeline stub for this phase: each invocation marks all
# remaining open items [x] in NON_BLOCKING_LOG.md, simulating a coder
# pass that successfully addresses everything.
_run_pipeline_stages() {
    echo "pipeline_stages" >> "$CALL_LOG_FILE"
    sed -i 's/^- \[ \]/- [x]/' "$NB_FILE"
    return 0
}

: > "$CALL_LOG_FILE"
# Force max passes high enough that the loop relies on break-on-zero.
export FIX_NONBLOCKERS_MAX_PASSES=5
output=$(_run_fix_nonblockers_loop 2>&1)

# Pipeline ran exactly once; loop's next iteration hit break-on-zero.
assert_eq "2.1 pipeline ran once before items resolved to zero" \
    "1" "$(count_log_entries 'pipeline_stages')"
assert_eq "2.2 emit_dashboard_action_items fired after break-on-zero" \
    "1" "$(count_log_entries 'emit_dashboard_action_items')"
assert_eq "2.3 _print_action_items fired after break-on-zero" \
    "1" "$(count_log_entries 'print_action_items')"

# Final-state assertions — both surfaces must reflect count 0, not the
# pre-run count of 2.
if grep -q '"count":0' "$DASH_FILE"; then
    pass "2.4 action_items.js shows count 0 after resolved-during-pass"
else
    fail "2.4 action_items.js does not show count 0 — content: $(cat "$DASH_FILE")"
fi
assert_contains "2.5 terminal banner shows count 0 after resolved-during-pass" \
    "0 accumulated observation(s)" "$output"

# Sanity: the bug would manifest as the banner showing "2" here, since
# that was the pre-run count.
if [[ "$output" == *"2 accumulated observation(s)"* ]]; then
    fail "2.6 terminal banner shows STALE pre-run count of 2 (regression)"
else
    pass "2.6 terminal banner does not show stale pre-run count"
fi

# -----------------------------------------------------------------------------
# Phase 3: Partial-success exit via FIX_NONBLOCKERS_MAX_PASSES — loop
# bails before all items are resolved. Even on this exit path, the
# post-loop refresh must fire so the surfaces match the actual state.
# -----------------------------------------------------------------------------
cat > "$NB_FILE" << 'EOF'
# Non-Blocking Notes Log

## Open
- [ ] [lib/foo.dart:42] Missing null check
- [ ] [lib/bar.dart:10] Consider renaming variable
- [ ] [lib/baz.dart:7] Add docstring

## Resolved
EOF

# Pipeline stub that doesn't resolve anything — forces the loop to
# exhaust its FIX_NONBLOCKERS_MAX_PASSES budget.
_run_pipeline_stages() {
    echo "pipeline_stages" >> "$CALL_LOG_FILE"
    return 0
}

export FIX_NONBLOCKERS_MAX_PASSES=2
: > "$CALL_LOG_FILE"
output=$(_run_fix_nonblockers_loop 2>&1)

assert_eq "3.1 emit_dashboard_action_items fires on max-passes exit" \
    "1" "$(count_log_entries 'emit_dashboard_action_items')"
assert_eq "3.2 _print_action_items fires on max-passes exit" \
    "1" "$(count_log_entries 'print_action_items')"

# Surfaces must show the actual remaining count (3).
if grep -q '"count":3' "$DASH_FILE"; then
    pass "3.3 action_items.js shows actual remaining count after max-passes exit"
else
    fail "3.3 action_items.js does not show count 3 — content: $(cat "$DASH_FILE")"
fi
assert_contains "3.4 terminal banner shows actual remaining count after max-passes exit" \
    "3 accumulated observation(s)" "$output"

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
if [[ "$FAIL" -ne 0 ]]; then
    echo
    echo "SOME TESTS FAILED"
    exit 1
fi
echo
echo "All fix-nonblockers post-loop refresh tests passed."
