#!/usr/bin/env bash
# TIMEOUT_SECS=30
# =============================================================================
# test_final_checks_commit_gate.sh — gate on .final_check_result sentinel
#
# Covers task #46: _hook_commit must refuse to run when _hook_final_checks
# recorded a failure in .tekhton/.final_check_result, AND must proceed
# normally when the sentinel records success (or is absent).
#
# Each finalize hook runs in its own bash subprocess under the Go orchestrator
# shim, so the in-memory FINAL_CHECK_RESULT set by _hook_final_checks doesn't
# survive to _hook_commit. The sentinel file is the bridge between them.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0 FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Source only what's needed to expose _final_check_result_read without
# pulling in the whole finalize stack (which expects a real project tree).
# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/finalize_commit.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export TEKHTON_DIR="$TMP/.tekhton"
mkdir -p "$TEKHTON_DIR"

echo "=== _final_check_result_read: sentinel absent → 0 ==="
result=$(_final_check_result_read)
if [[ "$result" == "0" ]]; then
    pass "1.1: absent sentinel returns 0"
else
    fail "1.1: absent sentinel returned '$result' (want 0)"
fi

echo "=== _final_check_result_read: sentinel says 0 → 0 ==="
echo "0" > "$TEKHTON_DIR/.final_check_result"
result=$(_final_check_result_read)
if [[ "$result" == "0" ]]; then
    pass "2.1: zero sentinel returns 0"
else
    fail "2.1: zero sentinel returned '$result'"
fi

echo "=== _final_check_result_read: sentinel says non-zero → non-zero ==="
echo "1" > "$TEKHTON_DIR/.final_check_result"
result=$(_final_check_result_read)
if [[ "$result" == "1" ]]; then
    pass "3.1: failure sentinel returns 1"
else
    fail "3.1: failure sentinel returned '$result' (want 1)"
fi

echo "=== _final_check_result_read: handles trailing whitespace ==="
printf '2\n  \n' > "$TEKHTON_DIR/.final_check_result"
result=$(_final_check_result_read)
if [[ "$result" == "2" ]]; then
    pass "4.1: whitespace-around value parsed correctly"
else
    fail "4.1: got '$result' (want 2)"
fi

echo "=== _final_check_result_read: empty file → 0 ==="
: > "$TEKHTON_DIR/.final_check_result"
result=$(_final_check_result_read)
if [[ "$result" == "0" ]]; then
    pass "5.1: empty sentinel returns 0 (defensive default)"
else
    fail "5.1: empty sentinel returned '$result'"
fi

# Source finalize_core_hooks for _hook_final_checks gate behavior. Stub
# run_final_checks so the test doesn't actually invoke TEST_CMD.
# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/finalize_core_hooks.sh"

echo "=== _hook_final_checks: failure writes sentinel ==="
run_final_checks() { return 7; }  # fake failure
rm -f "$TEKHTON_DIR/.final_check_result"
SKIP_FINAL_CHECKS=false _PREFLIGHT_TESTS_PASSED=false \
    _hook_final_checks 0 >/dev/null 2>&1 || true
if [[ -f "$TEKHTON_DIR/.final_check_result" ]]; then
    val=$(tr -d '[:space:]' < "$TEKHTON_DIR/.final_check_result")
    if [[ "$val" == "7" ]]; then
        pass "6.1: failure persists exit code (7) to sentinel"
    else
        fail "6.1: sentinel contains '$val' (want 7)"
    fi
else
    fail "6.1: sentinel file not created on failure"
fi

echo "=== _hook_final_checks: success leaves sentinel absent ==="
run_final_checks() { return 0; }  # fake success
rm -f "$TEKHTON_DIR/.final_check_result"
SKIP_FINAL_CHECKS=false _PREFLIGHT_TESTS_PASSED=false \
    _hook_final_checks 0 >/dev/null 2>&1 || true
if [[ -f "$TEKHTON_DIR/.final_check_result" ]]; then
    val=$(tr -d '[:space:]' < "$TEKHTON_DIR/.final_check_result")
    fail "7.1: sentinel file exists on success (contains '$val'); should be absent"
else
    pass "7.1: sentinel absent after a clean run"
fi

echo "=== _hook_final_checks: SKIP_FINAL_CHECKS=true records 1 ==="
# SKIP path treats the skipped check as a failure so the commit gate still trips
rm -f "$TEKHTON_DIR/.final_check_result"
SKIP_FINAL_CHECKS=true _hook_final_checks 0 >/dev/null 2>&1 || true
if [[ -f "$TEKHTON_DIR/.final_check_result" ]]; then
    pass "8.1: SKIP_FINAL_CHECKS writes failure sentinel (commit gate trips)"
else
    fail "8.1: SKIP_FINAL_CHECKS should still write a failure sentinel"
fi

# Integration: _hook_commit reads the sentinel and blocks when non-zero.
# Use a flag FILE (not a variable) to detect git invocations from the
# subshell created by $() — variable writes in a subshell don't propagate
# back to the parent, but file-system changes do.
_GIT_FLAG="$TEKHTON_DIR/.git_called_flag"
git() { touch "$_GIT_FLAG"; return 0; }

echo "=== _hook_commit: persisted sentinel blocks commit ==="
rm -f "$_GIT_FLAG"
echo "1" > "$TEKHTON_DIR/.final_check_result"
unset FINAL_CHECK_RESULT
output=$(_hook_commit 0 2>&1) || true
if [[ ! -f "$_GIT_FLAG" ]]; then
    pass "9.1: git not called when persisted sentinel records failure"
else
    fail "9.1: git was called despite persisted failure sentinel"
fi
if echo "$output" | grep -q "Commit blocked"; then
    pass "9.2: 'Commit blocked' warning emitted"
else
    fail "9.2: expected 'Commit blocked' in output, got: $output"
fi

echo "=== _hook_commit: in-memory FINAL_CHECK_RESULT blocks commit ==="
rm -f "$_GIT_FLAG"
rm -f "$TEKHTON_DIR/.final_check_result"
output=$(FINAL_CHECK_RESULT=1 _hook_commit 0 2>&1) || true
if [[ ! -f "$_GIT_FLAG" ]]; then
    pass "10.1: git not called when in-memory FINAL_CHECK_RESULT is non-zero"
else
    fail "10.1: git was called despite FINAL_CHECK_RESULT=1"
fi
if echo "$output" | grep -q "Commit blocked"; then
    pass "10.2: 'Commit blocked' warning emitted for in-memory path"
else
    fail "10.2: expected 'Commit blocked' in output, got: $output"
fi

echo "=== _hook_commit: non-zero exit_code bypasses commit silently ==="
rm -f "$_GIT_FLAG"
rm -f "$TEKHTON_DIR/.final_check_result"
unset FINAL_CHECK_RESULT
_hook_commit 1 >/dev/null 2>&1 || true
if [[ ! -f "$_GIT_FLAG" ]]; then
    pass "11.1: git not called when exit_code is non-zero (expected early return)"
else
    fail "11.1: git was called for non-zero exit_code"
fi

echo "=== trip_commit_gate writes sentinel + commit hook reads as failure ==="
# trip_commit_gate is defined in lib/common.sh; the synthesize-fallback paths
# (stages/review.sh, stages/coder.sh, stages/tester_validation.sh) call it
# when an agent didn't produce its expected report. Sentinel makes
# _hook_commit refuse — closes the rubber-stamp loophole for #49.
rm -f "$TEKHTON_DIR/.final_check_result"
trip_commit_gate "reviewer_did_not_produce_report"
if [[ -f "$TEKHTON_DIR/.final_check_result" ]]; then
    val=$(head -1 "$TEKHTON_DIR/.final_check_result" | tr -d '[:space:]')
    if [[ "$val" == "1" ]]; then
        pass "12.1: trip_commit_gate writes sentinel with exit code 1"
    else
        fail "12.1: sentinel first line is '$val' (want 1)"
    fi
    if grep -q "reviewer_did_not_produce_report" "$TEKHTON_DIR/.final_check_result"; then
        pass "12.2: trip_commit_gate records the reason"
    else
        fail "12.2: sentinel missing reason"
    fi
else
    fail "12.1: trip_commit_gate did not create the sentinel"
fi
# Now confirm _hook_commit reads it correctly via the read helper.
result=$(_final_check_result_read)
if [[ "$result" == "1" ]]; then
    pass "12.3: _final_check_result_read parses trip_commit_gate output as 1"
else
    fail "12.3: read returned '$result' instead of 1"
fi

echo "=== _hook_final_checks does NOT erase a stage-side trip ==="
# Regression for the M23 hollow-commit bug: stages call trip_commit_gate
# during the pipeline (e.g. coder's missing-CODER_SUMMARY synthesize path),
# then much later _hook_final_checks runs in the finalize chain. Previously
# _hook_final_checks rm -f'd the sentinel at entry, wiping the stage's
# trip and letting the commit gate proceed. Pipeline-start cleanup now
# lives in stages/intake.sh; _hook_final_checks must NOT clear.
rm -f "$TEKHTON_DIR/.final_check_result"
trip_commit_gate "coder_did_not_produce_summary"  # simulate stage trip
run_final_checks() { return 0; }  # simulate final tests passing
SKIP_FINAL_CHECKS=false _PREFLIGHT_TESTS_PASSED=false \
    _hook_final_checks 0 >/dev/null 2>&1 || true
if [[ -f "$TEKHTON_DIR/.final_check_result" ]]; then
    val=$(tr -d '[:space:]' < "$TEKHTON_DIR/.final_check_result" 2>/dev/null | head -c 1)
    if [[ "$val" == "1" ]]; then
        pass "14.1: stage-side sentinel survives _hook_final_checks when final tests pass"
    else
        fail "14.1: sentinel present but value=$val (want 1)"
    fi
    if grep -q "coder_did_not_produce_summary" "$TEKHTON_DIR/.final_check_result"; then
        pass "14.2: original stage reason preserved"
    else
        fail "14.2: stage reason was lost"
    fi
else
    fail "14.1: stage-side sentinel was erased by _hook_final_checks (M23 regression)"
fi

echo "=== trip_commit_gate is idempotent (preserves first reason) ==="
# Start from a known state — previous test cases may have written
# different reasons via trip_commit_gate or its wrappers.
rm -f "$TEKHTON_DIR/.final_check_result"
trip_commit_gate "first_reason_set"
trip_commit_gate "second_reason_should_not_overwrite"
if grep -q "first_reason_set" "$TEKHTON_DIR/.final_check_result" \
   && ! grep -q "second_reason_should_not_overwrite" "$TEKHTON_DIR/.final_check_result"; then
    pass "13.1: subsequent trip calls preserve first reason"
else
    fail "13.1: second trip overwrote the first reason"
fi

echo "=== _write_commit_decision writes the sentinel ==="
# Covers the 2026-05 finalize reordering fix: _hook_commit must
# persist its decision so downstream completion hooks (mark_done,
# cleanup_milestone, clear_state) know whether the user actually
# committed. Without this sentinel a declined prompt looks identical
# to a successful run from the manifest's perspective.
rm -f "$TEKHTON_DIR/.commit_decision"
_write_commit_decision "committed"
if [[ -f "$TEKHTON_DIR/.commit_decision" ]]; then
    val=$(tr -d '[:space:]' < "$TEKHTON_DIR/.commit_decision")
    if [[ "$val" == "committed" ]]; then
        pass "15.1: _write_commit_decision committed wrote sentinel"
    else
        fail "15.1: sentinel content is '$val' (want committed)"
    fi
else
    fail "15.1: _write_commit_decision did not create sentinel"
fi

# Overwrite semantics: writing "declined" must replace, not append.
_write_commit_decision "declined"
val=$(tr -d '[:space:]' < "$TEKHTON_DIR/.commit_decision")
if [[ "$val" == "declined" ]]; then
    pass "15.2: _write_commit_decision overwrites previous value"
else
    fail "15.2: expected 'declined', got '$val'"
fi

# Pipeline-start cleanup (stages/intake.sh) wipes the sentinel — verify
# the path matches the directory _write_commit_decision wrote into.
expected_path="${TEKHTON_DIR:-.tekhton}/.commit_decision"
if [[ "$expected_path" != /* ]] && [[ -n "${PROJECT_DIR:-}" ]]; then
    expected_path="${PROJECT_DIR}/${expected_path}"
fi
if [[ -f "$expected_path" ]]; then
    pass "15.3: sentinel path matches stages/intake.sh cleanup target"
else
    fail "15.3: sentinel path mismatch — wrote elsewhere than ${expected_path}"
fi

echo "=== _run_commit_bookkeeping invocation contract ==="
# Locks the bash → Go bridge added to fix the "post-commit working tree
# not clean" gap (2026-05). _hook_commit's y/e branches must call
# `tekhton commit-bookkeeping` BEFORE _do_git_commit so the manifest +
# milestone-file mutations are captured in the same commit.
_TB_LOG="$TEKHTON_DIR/.tekhton_bin_calls"
rm -f "$_TB_LOG"

# Stub the tekhton binary to record its argv instead of executing.
TEKHTON_BIN="$TMP/tekhton-stub"
cat > "$TEKHTON_BIN" <<'STUB'
#!/usr/bin/env bash
# Append all args to the capture log. Best-effort: silent on success.
printf '%s\n' "$*" >> "${_TB_LOG_PATH}"
exit 0
STUB
chmod +x "$TEKHTON_BIN"
export TEKHTON_BIN _TB_LOG_PATH="$_TB_LOG"

PROJECT_DIR_BAK="${PROJECT_DIR:-}"
PROJECT_DIR="$TMP" MILESTONE_MODE=true _CURRENT_MILESTONE="m23" \
    _CACHED_DISPOSITION="COMPLETE_AND_CONTINUE" _run_commit_bookkeeping
PROJECT_DIR="$PROJECT_DIR_BAK"

if [[ -f "$_TB_LOG" ]]; then
    pass "16.1: _run_commit_bookkeeping invoked TEKHTON_BIN"
else
    fail "16.1: stub binary was not invoked"
fi

if grep -q "commit-bookkeeping" "$_TB_LOG"; then
    pass "16.2: argv contains 'commit-bookkeeping' subcommand"
else
    fail "16.2: subcommand name missing from argv: $(cat "$_TB_LOG" 2>/dev/null)"
fi

if grep -q -- "--milestone m23" "$_TB_LOG"; then
    pass "16.3: argv threads milestone id"
else
    fail "16.3: milestone id missing: $(cat "$_TB_LOG" 2>/dev/null)"
fi

if grep -q -- "--milestone-disposition COMPLETE_AND_CONTINUE" "$_TB_LOG"; then
    pass "16.4: argv threads disposition for shouldRunOnCompletion gate"
else
    fail "16.4: disposition missing: $(cat "$_TB_LOG" 2>/dev/null)"
fi

# Non-milestone runs (--task, --human) must short-circuit. Without this
# guard the bookkeeping subcommand would fire on every successful
# commit, even when no milestone is in scope — confusing operators and
# wasting a fork+exec.
rm -f "$_TB_LOG"
MILESTONE_MODE=false _CURRENT_MILESTONE="" _run_commit_bookkeeping
if [[ ! -s "$_TB_LOG" ]]; then
    pass "16.5: non-milestone run skips bookkeeping invocation"
else
    fail "16.5: stub was invoked despite MILESTONE_MODE=false: $(cat "$_TB_LOG")"
fi

echo ""
echo "=== Summary ==="
echo "Passed: $PASS, Failed: $FAIL"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
