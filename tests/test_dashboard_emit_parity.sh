#!/usr/bin/env bash
# =============================================================================
# test_dashboard_emit_parity.sh — m33.1 contract gate.
#
# Drives `tekhton dashboard emit <kind>` against synthesized fixtures and
# asserts the emitted JS files carry the expected JSON shape. Pre-m33.1
# this contract lived implicitly across multiple bash-internal tests
# (test_dashboard_data.sh, test_m38_dashboard_coverage.sh, etc.); m33.1
# collapses them into this single Go-binary-driven gate.
#
# Three scenarios are covered:
#   - single-success: full pipeline run, no parallel teams
#   - multi-stage-failure: partial run failing at the security stage
#   - parallel-teams: M37 parallel-mode with two team ids
#
# Bash baselines are NOT captured byte-for-byte in this milestone (the
# bash emitters had per-run timestamps and shell-quoting quirks that would
# require parallel maintenance). Instead this gate asserts structural
# properties on the Go output. m33.2 may layer byte-identical comparison
# on top once the bash parsers also move to Go.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${TEKHTON_BIN:-${TEKHTON_HOME}/bin/tekhton}"

if [[ ! -x "$BIN" ]]; then
    echo "SKIP: tekhton binary not built (run 'make build')"
    exit 0
fi

PASS=0
FAIL=0
FAILED=()

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); FAILED+=("$*"); }

assert_contains() {
    local label="$1" file="$2" needle="$3"
    if grep -q -- "$needle" "$file"; then
        pass "$label"
    else
        fail "$label — $file missing $needle"
    fi
}

assert_not_contains() {
    local label="$1" file="$2" needle="$3"
    if ! grep -q -- "$needle" "$file"; then
        pass "$label"
    else
        fail "$label — $file unexpectedly contains $needle"
    fi
}

# -----------------------------------------------------------------------------
# Scenario 1: single-success — a typical completed-pipeline emission.
# -----------------------------------------------------------------------------
scenario_single_success() {
    echo "=== Scenario 1: single-success ==="
    local tmp
    tmp=$(mktemp -d)

    "$BIN" dashboard init --project-dir "$tmp" >/dev/null

    # Drive run-state with a populated active milestone.
    _CURRENT_MILESTONE=m33.1 _CURRENT_MILESTONE_TITLE="Dashboard Emitters" \
        PIPELINE_STATUS=success CURRENT_STAGE=complete \
        START_AT_TS=2026-05-29T16:00:00Z \
        _STAGE_STATUS_intake=pass _STAGE_TURNS_intake=2 _STAGE_BUDGET_intake=10 _STAGE_DURATION_intake=12 \
        _STAGE_STATUS_coder=pass _STAGE_TURNS_coder=18 _STAGE_BUDGET_coder=60 _STAGE_DURATION_coder=420 \
        DASHBOARD_REFRESH_INTERVAL=5 \
        "$BIN" dashboard emit run-state --project-dir "$tmp" >/dev/null

    local rs="$tmp/.claude/dashboard/data/run_state.js"
    [[ -f "$rs" ]] || { fail "run_state.js missing"; rm -rf "$tmp"; return; }
    assert_contains "scenario1: run_state.js has TK_RUN_STATE" "$rs" 'window.TK_RUN_STATE'
    assert_contains "scenario1: run_state.js shows success" "$rs" '"pipeline_status":"success"'
    assert_contains "scenario1: run_state.js carries active_milestone" "$rs" '"id":"m33.1"'
    assert_contains "scenario1: run_state.js stage map populated" "$rs" '"intake":'
    assert_contains "scenario1: run_state.js parallel_mode false" "$rs" '"parallel_mode":false'

    # Emit other simple kinds (no fixture data needed) and verify shape.
    "$BIN" dashboard emit milestones --project-dir "$tmp" >/dev/null
    "$BIN" dashboard emit health --project-dir "$tmp" >/dev/null
    "$BIN" dashboard emit security --project-dir "$tmp" >/dev/null
    "$BIN" dashboard emit reports --project-dir "$tmp" >/dev/null
    "$BIN" dashboard emit metrics --project-dir "$tmp" >/dev/null
    "$BIN" dashboard emit notes --project-dir "$tmp" >/dev/null
    "$BIN" dashboard emit inbox --project-dir "$tmp" >/dev/null
    "$BIN" dashboard emit action-items --project-dir "$tmp" >/dev/null
    "$BIN" dashboard emit diagnosis --project-dir "$tmp" >/dev/null
    "$BIN" dashboard emit draft-milestones --project-dir "$tmp" >/dev/null

    for kind in milestones health security reports metrics notes inbox action_items diagnosis draft_milestones; do
        local f="$tmp/.claude/dashboard/data/${kind}.js"
        if [[ -f "$f" ]]; then
            pass "scenario1: $kind.js generated"
        else
            fail "scenario1: $kind.js missing"
        fi
    done

    # Default health → available=false.
    assert_contains "scenario1: health.js available=false" "$tmp/.claude/dashboard/data/health.js" '"available":false'
    # Empty security → findings:[]
    assert_contains "scenario1: security.js empty findings" "$tmp/.claude/dashboard/data/security.js" '"findings":\[\]'

    rm -rf "$tmp"
}

# -----------------------------------------------------------------------------
# Scenario 2: multi-stage failure — pipeline fails at security stage.
# -----------------------------------------------------------------------------
scenario_multi_stage_failure() {
    echo "=== Scenario 2: multi-stage-failure ==="
    local tmp
    tmp=$(mktemp -d)
    "$BIN" dashboard init --project-dir "$tmp" >/dev/null

    # Plant a fake security report so the emitter has findings to extract.
    mkdir -p "$tmp/.tekhton"
    cat > "$tmp/.tekhton/SECURITY_REPORT.md" << 'EOF'
# Security Review

## Findings
- Severity: HIGH (A01) — sensitive data exposure in login flow
- Severity: MEDIUM — outdated dependency
EOF

    PIPELINE_STATUS=failed CURRENT_STAGE=security \
        _STAGE_STATUS_intake=pass _STAGE_STATUS_coder=pass _STAGE_STATUS_security=failed \
        "$BIN" dashboard emit run-state --project-dir "$tmp" >/dev/null
    "$BIN" dashboard emit security --project-dir "$tmp" >/dev/null

    local rs="$tmp/.claude/dashboard/data/run_state.js"
    local sec="$tmp/.claude/dashboard/data/security.js"
    assert_contains "scenario2: pipeline_status failed" "$rs" '"pipeline_status":"failed"'
    assert_contains "scenario2: current_stage security" "$rs" '"current_stage":"security"'
    assert_contains "scenario2: security.js has HIGH finding" "$sec" '"severity":"HIGH"'
    assert_contains "scenario2: security.js has OWASP A01" "$sec" '"category":"A01"'

    rm -rf "$tmp"
}

# -----------------------------------------------------------------------------
# Scenario 3: parallel-teams (M37) — two teams in run_state.
# -----------------------------------------------------------------------------
scenario_parallel_teams() {
    echo "=== Scenario 3: parallel-teams ==="
    local tmp
    tmp=$(mktemp -d)
    "$BIN" dashboard init --project-dir "$tmp" >/dev/null

    _PARALLEL_TEAMS="t1 t2" \
        _TEAM_MILESTONE_t1=m33.1 _TEAM_MILESTONE_TITLE_t1="Dashboard Emitters" \
        _TEAM_STAGE_t1=coder _TEAM_STATUS_t1=running _TEAM_STARTED_t1=2026-05-29T16:00:00Z \
        _TEAM_MILESTONE_t2=m33.2 _TEAM_MILESTONE_TITLE_t2="Dashboard Parsers" \
        _TEAM_STAGE_t2=reviewer _TEAM_STATUS_t2=running _TEAM_STARTED_t2=2026-05-29T16:05:00Z \
        _TEAM_STAGE_STATUS_t1_coder=active _TEAM_STAGE_TURNS_t1_coder=8 \
        _TEAM_STAGE_STATUS_t2_reviewer=pass _TEAM_STAGE_TURNS_t2_reviewer=3 \
        PIPELINE_STATUS=running CURRENT_STAGE=coder \
        "$BIN" dashboard emit run-state --project-dir "$tmp" >/dev/null

    local rs="$tmp/.claude/dashboard/data/run_state.js"
    assert_contains "scenario3: parallel_mode true" "$rs" '"parallel_mode":true'
    assert_contains "scenario3: teams.t1 present" "$rs" '"t1":'
    assert_contains "scenario3: teams.t2 present" "$rs" '"t2":'
    assert_contains "scenario3: t1 milestone m33.1" "$rs" '"id":"m33.1"'
    assert_contains "scenario3: t2 milestone m33.2" "$rs" '"id":"m33.2"'

    rm -rf "$tmp"
}

scenario_single_success
scenario_multi_stage_failure
scenario_parallel_teams

echo "========================================"
echo "dashboard_emit_parity: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
fi
exit 0
