#!/usr/bin/env bash
# tests/test_output_format_tui.sh — TUI-mode branch tests for lib/output_format.sh
#
# Covers the _TUI_ACTIVE=true paths that test_output_format.sh explicitly skips:
#   - out_msg: no stdout, writes ANSI-stripped text to LOG_FILE, calls _tui_notify
#   - out_banner: no stdout, title + kv pairs routed to LOG_FILE via _out_emit
#   - out_section: no stdout, "── TITLE ──" routed to LOG_FILE
#   - out_kv: all three severities routed to LOG_FILE (no [CRITICAL] suffix)
#   - out_hr: no-label and labelled variants routed to LOG_FILE
#   - out_progress: "LABEL CUR/MAX (PCT%)" routed to LOG_FILE
#   - out_action_item: no stdout, appends JSON object to _OUT_CTX[action_items]
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── TUI stubs (must be defined before sourcing output.sh) ─────────────────────
# _tui_notify: write level+msg to a file so tests can verify it was called.
_tui_notify()     { printf '%s %s\n' "${1:-}" "${2:-}" >> "${_TUI_NOTIFY_LOG:-/dev/null}" 2>/dev/null || true; }
# _tui_strip_ansi: strip ANSI CSI sequences — mirrors what the real sidecar does.
_tui_strip_ansi() { printf '%s' "${1:-}" | sed $'s/\x1b\\[[0-9;]*m//g'; }

# Force TUI mode — this is the branch under test.
export _TUI_ACTIVE=true

# Set ANSI codes to real values so that stripping tests are meaningful.
export BOLD='\033[1m'
export NC='\033[0m'
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export CYAN='\033[0;36m'

# Fix COLUMNS so _out_term_width is deterministic.
export COLUMNS=60

# Source output.sh first (provides _OUT_CTX and out_log/warn/error/header).
# shellcheck source=../lib/output.sh
source "${TEKHTON_HOME}/lib/output.sh"

# Source the module under test.
# shellcheck source=../lib/output_format.sh
source "${TEKHTON_HOME}/lib/output_format.sh"

# m23: re-stub _tui_notify after sourcing because lib/sidecar_lifecycle.sh
# (sourced transitively by output.sh) defines its own _tui_notify that goes
# to `_tui_call append-event ...`. The stub before sourcing would be
# overwritten otherwise.
_tui_notify() {
    printf '%s %s\n' "${1:-}" "${2:-}" >> "${_TUI_NOTIFY_LOG:-/dev/null}" 2>/dev/null || true
}

# ── Test infrastructure ──────────────────────────────────────────────────────
PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() {
    FAIL=$((FAIL + 1))
    FAILURES+=("$1")
    echo "  FAIL: $1"
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label (expected='${expected}' actual='${actual}')"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label (expected '${needle}' in: '${haystack}')"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label (unexpected '${needle}' found in: '${haystack}')"
    fi
}

contains_ansi() { [[ "$1" == *$'\033'* ]]; }

echo "=== test_output_format_tui.sh ==="

# ── Temp directory setup ──────────────────────────────────────────────────────
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export _TUI_NOTIFY_LOG="${TMPDIR_TEST}/tui_notify.log"

# ════════════════════════════════════════
# out_msg — TUI mode
# Primary behavior: no stdout, writes to LOG_FILE, calls _tui_notify.
# ════════════════════════════════════════

export LOG_FILE="${TMPDIR_TEST}/out_msg.log"
> "$LOG_FILE"
> "$_TUI_NOTIFY_LOG"

# 1. No stdout when TUI is active.
stdout_file="${TMPDIR_TEST}/msg_stdout.txt"
out_msg "hello from TUI" > "$stdout_file"
stdout_content=$(cat "$stdout_file")
assert_eq "out_msg TUI: no stdout produced" "" "$stdout_content"

# 2. Message written to LOG_FILE.
log_content=$(cat "$LOG_FILE")
assert_contains "out_msg TUI: message in LOG_FILE" "hello from TUI" "$log_content"

# 3. ANSI escape sequences stripped from LOG_FILE content.
> "$LOG_FILE"
out_msg $'\033[1mcolored text\033[0m'
log_content=$(cat "$LOG_FILE")
if ! contains_ansi "$log_content"; then
    pass "out_msg TUI: ANSI stripped from LOG_FILE"
else
    fail "out_msg TUI: ANSI not stripped from LOG_FILE"
fi

# 4. Underlying text preserved after stripping.
assert_contains "out_msg TUI: text preserved after ANSI strip" "colored text" "$log_content"

# 5. _tui_notify called with 'info' level.
notify_content=$(cat "$_TUI_NOTIFY_LOG")
assert_contains "out_msg TUI: _tui_notify called with info level" "info" "$notify_content"

# ════════════════════════════════════════
# out_banner — TUI mode
# ════════════════════════════════════════

export LOG_FILE="${TMPDIR_TEST}/out_banner.log"
> "$LOG_FILE"

# 6. No stdout produced.
stdout_file="${TMPDIR_TEST}/banner_stdout.txt"
out_banner "Test Banner" "Version" "3.0" > "$stdout_file"
stdout_content=$(cat "$stdout_file")
assert_eq "out_banner TUI: no stdout produced" "" "$stdout_content"

log_content=$(cat "$LOG_FILE")

# 7. Title routed to LOG_FILE (via _out_emit header → "=== TITLE ===").
assert_contains "out_banner TUI: title in LOG_FILE" "Test Banner" "$log_content"

# 8. Key/value pair routed to LOG_FILE (via _out_emit info → "[tekhton] Key: Val").
assert_contains "out_banner TUI: key in LOG_FILE" "Version" "$log_content"
assert_contains "out_banner TUI: value in LOG_FILE" "3.0" "$log_content"

# ════════════════════════════════════════
# out_section — TUI mode
# ════════════════════════════════════════

export LOG_FILE="${TMPDIR_TEST}/out_section.log"
> "$LOG_FILE"

# 9. No stdout produced.
stdout_file="${TMPDIR_TEST}/section_stdout.txt"
out_section "Analysis" > "$stdout_file"
stdout_content=$(cat "$stdout_file")
assert_eq "out_section TUI: no stdout produced" "" "$stdout_content"

# 10. Formatted line "── TITLE ──" routed to LOG_FILE.
log_content=$(cat "$LOG_FILE")
assert_contains "out_section TUI: formatted title in LOG_FILE" "── Analysis ──" "$log_content"

# ════════════════════════════════════════
# out_kv — TUI mode (all three severities)
# ════════════════════════════════════════

export LOG_FILE="${TMPDIR_TEST}/out_kv.log"
> "$LOG_FILE"

# 11. Normal severity: label+value routed to LOG_FILE, no [CRITICAL] suffix.
out_kv "Status" "running"
log_content=$(cat "$LOG_FILE")
assert_contains "out_kv TUI normal: label in LOG_FILE" "Status" "$log_content"
assert_contains "out_kv TUI normal: value in LOG_FILE" "running" "$log_content"
assert_not_contains "out_kv TUI normal: no [CRITICAL] suffix" "[CRITICAL]" "$log_content"

# 12. Warn severity: label+value routed to LOG_FILE.
out_kv "Alert" "high usage" "warn"
log_content=$(cat "$LOG_FILE")
assert_contains "out_kv TUI warn: label in LOG_FILE" "Alert" "$log_content"
assert_contains "out_kv TUI warn: value in LOG_FILE" "high usage" "$log_content"

# 13. Error severity: label+value routed to LOG_FILE (no [CRITICAL] in TUI mode).
out_kv "Failure" "build broken" "error"
log_content=$(cat "$LOG_FILE")
assert_contains "out_kv TUI error: label in LOG_FILE" "Failure" "$log_content"
assert_contains "out_kv TUI error: value in LOG_FILE" "build broken" "$log_content"

# ════════════════════════════════════════
# out_hr — TUI mode
# ════════════════════════════════════════

export LOG_FILE="${TMPDIR_TEST}/out_hr.log"
> "$LOG_FILE"

# 14. Without label: fallback text "────" routed to LOG_FILE.
out_hr
log_content=$(cat "$LOG_FILE")
assert_contains "out_hr TUI no label: fallback text in LOG_FILE" "────" "$log_content"

# 15. With label: "── LABEL ──" routed to LOG_FILE.
out_hr "Test Section"
log_content=$(cat "$LOG_FILE")
assert_contains "out_hr TUI with label: formatted label in LOG_FILE" "── Test Section ──" "$log_content"

# ════════════════════════════════════════
# out_progress — TUI mode
# ════════════════════════════════════════

export LOG_FILE="${TMPDIR_TEST}/out_progress.log"
> "$LOG_FILE"

# 16-18. "LABEL CUR/MAX (PCT%)" routed to LOG_FILE; no bar chars in TUI output.
out_progress "Loading" 3 10 20
log_content=$(cat "$LOG_FILE")
assert_contains "out_progress TUI: label in LOG_FILE" "Loading" "$log_content"
assert_contains "out_progress TUI: count in LOG_FILE" "3/10" "$log_content"
assert_contains "out_progress TUI: percent in LOG_FILE" "30%" "$log_content"
assert_not_contains "out_progress TUI: no bar fill chars in LOG_FILE" "█" "$log_content"

# ════════════════════════════════════════
# out_action_item — TUI mode
# Primary behavior: no stdout; JSON object appended to _OUT_CTX[action_items].
# ════════════════════════════════════════

_OUT_CTX[action_items]=""

# 19. No stdout produced.
stdout_file="${TMPDIR_TEST}/action_stdout.txt"
out_action_item "Fix the config" "warning" > "$stdout_file"
stdout_content=$(cat "$stdout_file")
assert_eq "out_action_item TUI: no stdout produced" "" "$stdout_content"

# 20. JSON object appended to _OUT_CTX[action_items].
assert_contains "out_action_item TUI: msg in _OUT_CTX" '"msg":"Fix the config"' "${_OUT_CTX[action_items]}"

# 21. Severity recorded in JSON.
assert_contains "out_action_item TUI: severity in _OUT_CTX" '"severity":"warning"' "${_OUT_CTX[action_items]}"

# 22-23. Second item appended; first item retained.
out_action_item "Second issue" "critical"
assert_contains "out_action_item TUI: first item retained after append" '"msg":"Fix the config"' "${_OUT_CTX[action_items]}"
assert_contains "out_action_item TUI: second item in _OUT_CTX" '"msg":"Second issue"' "${_OUT_CTX[action_items]}"

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "Results: Passed=${PASS} Failed=${FAIL}"
if [[ "${#FAILURES[@]}" -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
fi

[[ "$FAIL" -eq 0 ]]
