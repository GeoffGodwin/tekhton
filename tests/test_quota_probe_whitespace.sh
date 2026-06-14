#!/usr/bin/env bash
# =============================================================================
# test_quota_probe_whitespace.sh — whitespace trim coverage for
# _quota_probe_spec_includes_claude (m22 reviewer gap)
#
# Primary observable behavior: _quota_probe_spec_includes_claude must correctly
# identify "claude" even when the PROVIDER spec contains spaces around commas
# (e.g. "codex, claude"). The trim logic at lib/quota_probe.sh:69-70 is the
# mechanism; these tests exercise it directly.
#
# Also confirms _quota_fmt_duration at exactly 3600s returns "1h" (pure-hours
# branch, zero minutes — the second reviewer gap).
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Minimal pipeline globals required for sourcing lib/ files.
export PROJECT_DIR="$TMPDIR"
export LOG_DIR="$TMPDIR/logs"
export LOG_FILE="$TMPDIR/test.log"
export TEKHTON_SESSION_DIR="$TMPDIR"
export TASK="quota probe whitespace test"
export MILESTONE_MODE=false
export _CURRENT_MILESTONE=""
export CAUSAL_LOG_ENABLED=false
export CAUSAL_LOG_FILE="$TMPDIR/causal.jsonl"
export QUOTA_RETRY_INTERVAL=300
export QUOTA_PROBE_MIN_INTERVAL=600
export QUOTA_PROBE_MAX_INTERVAL=1800

mkdir -p "$LOG_DIR" "$TMPDIR/.claude"
touch "$LOG_FILE"

# Source only what we need: common.sh for log(), quota_probe.sh under test.
# shellcheck source=../lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=../lib/quota_probe.sh
source "${TEKHTON_HOME}/lib/quota_probe.sh"

PASS=0
FAIL=0

assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# Helper: returns 0 when _quota_probe_spec_includes_claude reports true (exit 0).
includes_claude() {
    _quota_probe_spec_includes_claude && echo 0 || echo 1
}

# Helper: returns 0 when _quota_probe_spec_includes_claude reports false (exit 1).
excludes_claude() {
    _quota_probe_spec_includes_claude && echo 1 || echo 0
}

# =============================================================================
echo "=== _quota_probe_spec_includes_claude: whitespace-padded entries ==="
# These tests target the trim logic at lib/quota_probe.sh:69-70.
# Before the m22 fix, the function used unquoted word-splitting which could
# not handle spaces; the IFS-read + trim expansion is the new path.
# =============================================================================

# Space after comma: leading whitespace on "claude" token.
export PROVIDER="codex, claude"
assert 'PROVIDER="codex, claude" (space after comma) includes claude' \
    "$(includes_claude)"

# Space before comma: trailing whitespace on "codex" token.
export PROVIDER="codex ,claude"
assert 'PROVIDER="codex ,claude" (space before comma) includes claude' \
    "$(includes_claude)"

# Spaces around comma: both sides padded.
export PROVIDER="codex , claude"
assert 'PROVIDER="codex , claude" (spaces around comma) includes claude' \
    "$(includes_claude)"

# Leading whitespace on single-entry spec.
export PROVIDER=" claude"
assert 'PROVIDER=" claude" (leading space, single entry) includes claude' \
    "$(includes_claude)"

# Trailing whitespace on single-entry spec.
export PROVIDER="claude "
assert 'PROVIDER="claude " (trailing space, single entry) includes claude' \
    "$(includes_claude)"

# Both leading and trailing whitespace on single-entry spec.
export PROVIDER=" claude "
assert 'PROVIDER=" claude " (leading and trailing space) includes claude' \
    "$(includes_claude)"

# Claude in the middle of a three-provider spec with spaces everywhere.
export PROVIDER="codex , claude , qwen-local"
assert 'PROVIDER="codex , claude , qwen-local" (claude in middle with spaces) includes claude' \
    "$(includes_claude)"

# Negative: whitespace-padded non-claude entries — must NOT match.
export PROVIDER="codex , qwen-local"
assert 'PROVIDER="codex , qwen-local" (no claude, padded non-claude entries) excludes claude' \
    "$(excludes_claude)"

# Negative: a token that merely contains "claude" as a substring must not match.
export PROVIDER="codex , notclaude"
assert 'PROVIDER="codex , notclaude" (substring, not exact) excludes claude' \
    "$(excludes_claude)"

unset PROVIDER

# =============================================================================
echo ""
echo "=== _quota_fmt_duration: 3600s boundary (pure-hours, zero minutes) ==="
# The reviewer noted no direct test for the exact 3600s input — the branch
# where h>0 and m==0 emits "${h}h" without a minutes component.
# =============================================================================

assert "_quota_fmt_duration 3600 → 1h (not 1h0m)" \
    "$([ "$(_quota_fmt_duration 3600)" = "1h" ] && echo 0 || echo 1)"

assert "_quota_fmt_duration 7200 → 2h" \
    "$([ "$(_quota_fmt_duration 7200)" = "2h" ] && echo 0 || echo 1)"

# 3601s: h=1, m=0, sec=1 — seconds omitted per docstring, pure-hours branch.
assert "_quota_fmt_duration 3601 → 1h (seconds omitted in pure-hours branch)" \
    "$([ "$(_quota_fmt_duration 3601)" = "1h" ] && echo 0 || echo 1)"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
