#!/usr/bin/env bash
# Test: Verify NON_BLOCKING_LOG fixes
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
TIMESTAMP="20260315_100000"
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "$LOG_DIR"

# Stub functions
log() { :; }
warn() { :; }
error() { :; }
success() { :; }

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# === Fix #1: lib/dashboard.sh deleted in m33.1 (ported to internal/dashboard/) ===
# Pre-m33.1 checked the bash file's line count; post-m33.1 the file is gone.
# Sanity-check the shim file replacement is reasonably sized instead.
if [[ -f "${TEKHTON_HOME}/lib/dashboard_shim.sh" ]]; then
    line_count=$(wc -l < "${TEKHTON_HOME}/lib/dashboard_shim.sh")
    [[ "$line_count" -lt 200 ]] || fail "lib/dashboard_shim.sh exceeded budget (actual: $line_count)"
    pass "Fix #1: lib/dashboard_shim.sh line count acceptable ($line_count lines)"
else
    fail "m33.1: lib/dashboard_shim.sh missing"
fi

# === Fix #2: sync function shim still exported by dashboard_shim.sh ===
provides_comment=$(sed -n '/^# Provides:/,/^[^#]/p' "${TEKHTON_HOME}/lib/dashboard_shim.sh" | head -20)
# m33.1: shim file doesn't carry a Provides: comment; verify the function
# is still defined as a shim.
if grep -q '^sync_dashboard_static_files()' "${TEKHTON_HOME}/lib/dashboard_shim.sh"; then
    pass "Fix #2: sync_dashboard_static_files shim still defined"
else
    fail "sync_dashboard_static_files shim missing from dashboard_shim.sh"
fi

# === Fix #3: double _copy_static_files call ===
# Check that sync_dashboard_static_files is only called in the else branch (not after init_dashboard)
# The fix moves sync from always-executed to conditional (else branch)
# m20: dashboard sync logic still lives in tekhton-legacy.sh until Phase 5
# ports the dashboard subsystem to Go.
dashboard_flow=$(grep -B5 -A10 "if is_dashboard_enabled" "${TEKHTON_HOME}/tekhton-legacy.sh" | grep -c "else.*sync_dashboard_static_files" || echo "0")
if grep -A10 "if \[\[ ! -d.*local_dash_dir" "${TEKHTON_HOME}/tekhton-legacy.sh" | grep -q "else"; then
    pass "Fix #3: sync_dashboard_static_files moved to else branch (redundant copy fixed)"
else
    fail "sync_dashboard_static_files not in else branch"
fi

# === Fix #4: lib/diagnose.sh extraction ===
diagnose_lines=$(wc -l < "${TEKHTON_HOME}/lib/diagnose.sh")
[[ "$diagnose_lines" -lt 300 ]] || fail "lib/diagnose.sh not extracted (still $diagnose_lines lines)"
[[ -f "${TEKHTON_HOME}/lib/diagnose_helpers.sh" ]] || fail "lib/diagnose_helpers.sh not created"
pass "Fix #4: lib/diagnose.sh extracted to helpers module"

# === Fix #5: dead _detect_recurring_failures call ===
# The first call (line ~114 in diagnose.sh) should be removed
# Check that _detect_recurring_failures is not called with empty DIAG_CLASSIFICATION
# Check that DIAG_CLASSIFICATION="" initialization was removed from diagnose.sh
dead_call=$(grep -c 'DIAG_CLASSIFICATION=""' "${TEKHTON_HOME}/lib/diagnose.sh" 2>/dev/null || true)
dead_call="${dead_call//[!0-9]/}"
: "${dead_call:=0}"
[[ "$dead_call" -eq 0 ]] || fail "Dead code with empty DIAG_CLASSIFICATION still present"
pass "Fix #5: dead _detect_recurring_failures call removed"

# === Fix #6: post-archive context comment ===
# Check that _hook_failure_context has a comment about post-archive execution
hook_comment=$(grep -A5 "_hook_failure_context" "${TEKHTON_HOME}/lib/finalize.sh" "${TEKHTON_HOME}/lib/finalize_dashboard_hooks.sh" 2>/dev/null | grep -i "archive\|causal" || echo "")
[[ -n "$hook_comment" ]] || fail "No comment about post-archive context in _hook_failure_context"
pass "Fix #6: post-archive context comment added"

# === Fix #7: verdict type filter ===
# Check that _rule_review_loop filters for CHANGES_REQUIRED verdict type
verdict_filter=$(grep -A10 "_rule_review_loop" "${TEKHTON_HOME}/lib/diagnose_rules.sh" | grep -i "changes_required\|verdict.*type" || echo "")
[[ -n "$verdict_filter" ]] || fail "No verdict type filter in _rule_review_loop"
pass "Fix #7: verdict type filter added to _rule_review_loop"

# === Fix #8: hard-coded fallback ===
# Check that _DIAG_REVIEW_CYCLES is used instead of hard-coded "3"
hardcoded=$(grep "_rule_review_loop" -A20 "${TEKHTON_HOME}/lib/diagnose_rules.sh" | grep -c '"3 times"' || true)
hardcoded="${hardcoded//[!0-9]/}"
: "${hardcoded:=0}"
[[ "$hardcoded" -eq 0 ]] || fail "Hard-coded fallback '3 times' still present"
pass "Fix #8: hard-coded fallback removed or replaced with _DIAG_REVIEW_CYCLES"

# === Fix #9: QUOTA_PAUSED state ===
# Check that QUOTA_PAUSED is added to valid states in lib/state.sh
quota_paused=$(grep -c "QUOTA_PAUSED" "${TEKHTON_HOME}/lib/state.sh" || echo "0")
[[ "$quota_paused" -ge 1 ]] || fail "QUOTA_PAUSED not added to lib/state.sh"
pass "Fix #9: QUOTA_PAUSED added to valid pipeline states"

# === Fix #10: security delimiters ===
# Check that BEGIN/END FILE CONTENT delimiters are added to security_rework.prompt.md
security_file="${TEKHTON_HOME}/prompts/security_rework.prompt.md"
begin_delim=$(grep -c "BEGIN FILE CONTENT" "$security_file" || echo "0")
end_delim=$(grep -c "END FILE CONTENT" "$security_file" || echo "0")
[[ "$begin_delim" -gt 0 && "$end_delim" -gt 0 ]] || fail "Security delimiters not added to security_rework.prompt.md"
pass "Fix #10: security delimiters added to security_rework.prompt.md"

# === Fix #11: health_checks.sh extraction ===
health_checks_lines=$(wc -l < "${TEKHTON_HOME}/lib/health_checks.sh")
[[ "$health_checks_lines" -lt 300 ]] || fail "lib/health_checks.sh not extracted (still $health_checks_lines lines)"
[[ -f "${TEKHTON_HOME}/lib/health_checks_infra.sh" ]] || fail "lib/health_checks_infra.sh not created"
pass "Fix #11: health_checks.sh extracted to infra module"

# === Fix #12: duplicate dimension-check loop ===
# Check that a shared _run_dimension_checks helper exists
helper_exists=$(grep -c "_run_dimension_checks" "${TEKHTON_HOME}/lib/health.sh" || echo "0")
[[ "$helper_exists" -ge 1 ]] || fail "Shared _run_dimension_checks helper not found"
pass "Fix #12: shared _run_dimension_checks helper implemented"

# === Fix #13: stale dashboard health data (m33.1: now invoked via tekhton dashboard emit health) ===
reassess_hook=$(grep -A20 "_hook_health_reassess" "${TEKHTON_HOME}/lib/finalize.sh" "${TEKHTON_HOME}/lib/finalize_dashboard_hooks.sh" 2>/dev/null | grep -cE 'emit_dashboard_health|_td_run health' || true)
reassess_hook="${reassess_hook//[!0-9]/}"
: "${reassess_hook:=0}"
[[ "${reassess_hook}" -gt 0 ]] || fail "dashboard health emit not called in _hook_health_reassess"
pass "Fix #13: dashboard health data emission added to reassessment hook"

# === Fix #14: copyStaticFiles docstring (m33.1: moved to internal/dashboard) ===
docstring=$(grep -B5 "func copyStaticFiles" "${TEKHTON_HOME}/internal/dashboard/dashboard.go" | grep -i "overwrite\|copy\|idempotent")
echo "$docstring" | grep -qi "idempotent\|always\|overwrite\|copies" || fail "copyStaticFiles docstring not fixed"
pass "Fix #14: copyStaticFiles docstring carries copy-behavior note"

# === Fix #15: trendArrow ordering assumption ===
# Check that ordering assumption is documented or validated in app.js
trendArrow=$(grep -B5 -A5 "trendArrow" "${TEKHTON_HOME}/templates/watchtower/app.js" | grep -i "recent\|order\|oldest\|newest" || echo "")
[[ -n "$trendArrow" ]] || fail "trendArrow ordering assumption not documented"
pass "Fix #15: trendArrow ordering assumption documented/validated"

# === Fix #16: fragile JSON construction (m33.1: now typed via DashboardRunStateV1) ===
# Pre-m33.1 checked that bash emit used explicit waiting_for:null conditional.
# Post-m33.1 the typed Go struct uses *string with `null` marshalling; the
# parity gate validates the on-disk shape.
if grep -qE 'WaitingFor +\*string' "${TEKHTON_HOME}/internal/proto/dashboard_v1.go"; then
    pass "Fix #16: JSON construction uses typed *string (nullable)"
else
    fail "DashboardRunStateV1.WaitingFor not typed as *string"
fi

# === Fix #17: lib/causality.sh extraction ===
causality_lines=$(wc -l < "${TEKHTON_HOME}/lib/causality.sh")
[[ "$causality_lines" -lt 400 ]] || fail "lib/causality.sh not extracted (still $causality_lines lines)"
[[ -f "${TEKHTON_HOME}/lib/causality_query.sh" ]] || fail "lib/causality_query.sh not created"
pass "Fix #17: lib/causality.sh extracted to query module"

# === Fix #18: causal log archive timing ===
# Check for comment in _hook_failure_context about archive timing
archive_comment=$(grep -B5 -A10 "_hook_failure_context" "${TEKHTON_HOME}/lib/finalize.sh" "${TEKHTON_HOME}/lib/finalize_dashboard_hooks.sh" 2>/dev/null | grep -i "archive" || echo "")
[[ -n "$archive_comment" ]] || fail "No comment about causal log archive timing"
pass "Fix #18: causal log archive timing comment added"

# === Fix #19: trace_effect_chain broad match ===
# Check that trace_effect_chain has documentation of the limitation
trace_effect=$(grep -B2 -A5 "trace_effect_chain" "${TEKHTON_HOME}/lib/causality_query.sh" | grep -i "limitation\|broad\|match" || echo "")
[[ -n "$trace_effect" ]] || fail "trace_effect_chain limitation not documented"
pass "Fix #19: trace_effect_chain limitation documented"

# === Fix #20: m33.1 — dashboard sourcing now via dashboard_shim.sh ===
sourcing=$(grep "source.*dashboard_parsers" "${TEKHTON_HOME}/lib/dashboard_shim.sh" | grep "TEKHTON_HOME" || echo "")
[[ -n "$sourcing" ]] || fail "dashboard_shim.sh does not source dashboard_parsers.sh via TEKHTON_HOME"
pass "Fix #20: dashboard_shim.sh uses TEKHTON_HOME sourcing pattern"

# === Fix #21: _STAGE_BUDGET[intake] assignment ===
# m20: stage-budget assignment still lives in tekhton-legacy.sh.
intake_budget=$(grep "_STAGE_BUDGET\[intake\]" "${TEKHTON_HOME}/tekhton-legacy.sh" || echo "")
[[ -n "$intake_budget" ]] || fail "_STAGE_BUDGET[intake] not assigned in tekhton-legacy.sh"
pass "Fix #21: _STAGE_BUDGET[intake] assigned in tekhton-legacy.sh"

# === Fix #22: .claude/dashboard gitignore ===
# Check that .claude/dashboard pattern is in pipeline.conf.example or gitignore handling
gitignore_pattern=$(grep -r "\.claude/dashboard" "${TEKHTON_HOME}/templates/" || echo "")
[[ -n "$gitignore_pattern" ]] || fail ".claude/dashboard not added to gitignore patterns"
pass "Fix #22: .claude/dashboard gitignore pattern added"

# === Fix #23: post-m21 — orchestrator moved to Go ===
# The historic bash hook registry + finalize_run loop is gone; the canonical
# hook ordering test now lives at internal/finalize/orchestrator_test.go
# (TestHookOrder_MatchesBashRegistration). Verify that test file exists.
[[ -f "${TEKHTON_HOME}/internal/finalize/orchestrator_test.go" ]] \
    || fail "post-m21: internal/finalize/orchestrator_test.go missing — Go orchestrator's hook-order guard is the canonical test"
pass "Fix #23: post-m21 — internal/finalize/orchestrator_test.go is the canonical hook-order test"

# === Fix #24: post-m21 — hook letter labeling obsolete ===
# Bash hook letter labels (# a. _hook_final_checks, # b. _hook_drift_artifacts,
# ...) were a hook-registry convention in the pre-m21 lib/finalize.sh. The
# registry moved to internal/finalize/orchestrator.go's hookOrder list; the
# bash labels no longer exist or apply. Verify the Go canonical list is
# present.
go_order=$(grep -c '"_hook_' "${TEKHTON_HOME}/internal/finalize/orchestrator.go" || echo 0)
if [[ "$go_order" -lt 26 ]]; then
    fail "post-m21: internal/finalize/orchestrator.go hookOrder has ${go_order} entries (expected 26)"
fi
pass "Fix #24: post-m21 — Go hookOrder list defines all 26 hooks"

# === Fix #25: _detect_dockerfile_langs nullglob ===
# Check that nullglob is set before the Dockerfile iteration
nullglob=$(grep -B5 "_detect_dockerfile_langs" "${TEKHTON_HOME}/lib/detect_ci.sh" | grep "nullglob" || echo "")
[[ -n "$nullglob" ]] || fail "nullglob not set for _detect_dockerfile_langs"
pass "Fix #25: nullglob set for _detect_dockerfile_langs"

echo ""
echo "All NON_BLOCKING_LOG fixes verified successfully!"
