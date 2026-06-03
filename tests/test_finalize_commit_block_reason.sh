#!/usr/bin/env bash
# TIMEOUT_SECS=30
# =============================================================================
# test_finalize_commit_block_reason.sh — m41 Goal 3
#
# Asserts that _hook_commit names the actual block reason recorded by
# trip_commit_gate instead of the contradictory FINAL_CHECK_RESULT=0 /
# persisted=1 pair the previous diagnostic produced. The sentinel format
# (lib/common.sh::trip_commit_gate) is two lines:
#     1) the exit code (`1`)
#     2) `# <reason>` (e.g. `# coder_did_not_produce_summary`)
# `_final_check_reason_read` returns the reason with the `# ` marker
# stripped and whitespace trimmed; `_hook_commit` prints it in the
# blocked-commit warning so the operator can recover without grepping
# logs.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0 FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/finalize_commit.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export TEKHTON_DIR="$TMP/.tekhton"
mkdir -p "$TEKHTON_DIR"

# Stub git so a stray commit attempt is detectable via a flag FILE (the $()
# subshell can't propagate a variable back).
_GIT_FLAG="$TEKHTON_DIR/.git_called_flag"
git() { touch "$_GIT_FLAG"; return 0; }

# =============================================================================
echo "=== _final_check_reason_read: absent sentinel returns empty ==="
rm -f "$TEKHTON_DIR/.final_check_result"
result=$(_final_check_reason_read)
if [[ -z "$result" ]]; then
    pass "1.1: empty reason when sentinel absent"
else
    fail "1.1: expected empty, got '$result'"
fi

# =============================================================================
echo "=== _final_check_reason_read: parses '# reason' second line ==="
trip_commit_gate "coder_did_not_produce_summary"
result=$(_final_check_reason_read)
if [[ "$result" == "coder_did_not_produce_summary" ]]; then
    pass "2.1: reason parsed with '# ' marker stripped"
else
    fail "2.1: expected 'coder_did_not_produce_summary', got '$result'"
fi

# =============================================================================
echo "=== _final_check_reason_read: tolerates '#reason' (no space) ==="
rm -f "$TEKHTON_DIR/.final_check_result"
printf '1\n#tight_marker\n' > "$TEKHTON_DIR/.final_check_result"
result=$(_final_check_reason_read)
if [[ "$result" == "tight_marker" ]]; then
    pass "3.1: '#' without trailing space is stripped"
else
    fail "3.1: expected 'tight_marker', got '$result'"
fi

# =============================================================================
echo "=== _final_check_reason_read: trims surrounding whitespace ==="
rm -f "$TEKHTON_DIR/.final_check_result"
printf '1\n#   padded_reason   \n' > "$TEKHTON_DIR/.final_check_result"
result=$(_final_check_reason_read)
if [[ "$result" == "padded_reason" ]]; then
    pass "4.1: whitespace trimmed from both ends"
else
    fail "4.1: expected 'padded_reason', got '$result'"
fi

# =============================================================================
echo "=== _hook_commit: prints the recorded reason in blocked warning ==="
rm -f "$_GIT_FLAG"
rm -f "$TEKHTON_DIR/.final_check_result"
trip_commit_gate "completion_gate_failed_substantive_work_only"
unset FINAL_CHECK_RESULT
output=$(_hook_commit 0 2>&1) || true

if [[ ! -f "$_GIT_FLAG" ]]; then
    pass "5.1: git not called when sentinel records a reason"
else
    fail "5.1: git was called despite recorded reason"
fi

if echo "$output" | grep -q "Commit blocked: completion_gate_failed_substantive_work_only"; then
    pass "5.2: blocked warning names the actual reason"
else
    fail "5.2: missing reason in blocked warning; got: $output"
fi

# The historical contradiction (FINAL_CHECK_RESULT=0, persisted=1) must
# NOT appear in operator-facing output — it migrated to log_verbose.
if echo "$output" | grep -qE 'FINAL_CHECK_RESULT=0, persisted=1'; then
    fail "5.3: legacy 'FINAL_CHECK_RESULT=0, persisted=1' contradiction is back in operator output"
else
    pass "5.3: legacy 'FINAL_CHECK_RESULT=0, persisted=1' contradiction is gone from operator output"
fi

# The sentinel path is named so operators know where to look.
if echo "$output" | grep -qF ".final_check_result"; then
    pass "5.4: blocked warning points the operator to the sentinel file"
else
    fail "5.4: blocked warning missing sentinel path; got: $output"
fi

# =============================================================================
echo "=== _hook_commit: falls back gracefully when reason line is missing ==="
# Edge case: someone wrote a non-conforming sentinel with no `# reason`
# line. _hook_commit still has to block AND emit a generic blocked
# warning rather than printing an empty reason or crashing.
rm -f "$_GIT_FLAG"
printf '1\n' > "$TEKHTON_DIR/.final_check_result"
unset FINAL_CHECK_RESULT
output=$(_hook_commit 0 2>&1) || true

if [[ ! -f "$_GIT_FLAG" ]]; then
    pass "6.1: git not called when sentinel has no reason line"
else
    fail "6.1: git was called for reasonless failure sentinel"
fi

if echo "$output" | grep -qE "Commit blocked: final checks failed"; then
    pass "6.2: generic 'final checks failed' fallback when reason absent"
else
    fail "6.2: missing generic fallback warning; got: $output"
fi

# Don't print "Commit blocked: " followed by empty content — the reason
# fallback is what guards against that visual sin.
if echo "$output" | grep -qE 'Commit blocked: *\(see'; then
    fail "6.3: 'Commit blocked: (see ...)' with empty reason slipped through"
else
    pass "6.3: empty-reason rendering avoided"
fi

# =============================================================================
echo "=== _hook_commit: in-memory FINAL_CHECK_RESULT path also surfaces reason ==="
# When _hook_commit and _hook_final_checks share a shell (legacy test path),
# FINAL_CHECK_RESULT is set in-process AND the sentinel was written. The
# reason-read still applies.
rm -f "$_GIT_FLAG"
rm -f "$TEKHTON_DIR/.final_check_result"
trip_commit_gate "tester_did_not_produce_report"
output=$(FINAL_CHECK_RESULT=1 _hook_commit 0 2>&1) || true

if echo "$output" | grep -q "Commit blocked: tester_did_not_produce_report"; then
    pass "7.1: in-memory FAIL path also prints recorded reason"
else
    fail "7.1: in-memory path missed reason; got: $output"
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
