#!/usr/bin/env bash
# =============================================================================
# test_quota_probe_gating.sh — m21 bash-side quota probe gating tests
#
# Primary observable behavior: when claude is absent from the effective
# PROVIDER spec, _quota_probe must not invoke the claude binary at all.
# When claude is in the spec but TEKHTON_CLAUDE_TIER=api and
# QUOTA_PROBE_ALLOW_PAID is unset, the zero-turn and fallback probe kinds
# must not invoke claude (only the version probe may run).
#
# Each test uses a PATH-shim claude that writes its argv to CLAUDE_LOG (an
# exported env var). Asserts on that log: empty means claude never ran.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Exported so child processes (the claude shim) can find the log path.
export CLAUDE_LOG="$TMPDIR/claude_calls.log"

# --- Minimal pipeline globals required for sourcing lib/ files ---
export PROJECT_DIR="$TMPDIR"
export LOG_DIR="$TMPDIR/logs"
export LOG_FILE="$TMPDIR/test.log"
export TEKHTON_SESSION_DIR="$TMPDIR"
export TASK="quota probe gating test"
export MILESTONE_MODE=false
export _CURRENT_MILESTONE=""
export CAUSAL_LOG_ENABLED=false
export CAUSAL_LOG_FILE="$TMPDIR/causal.jsonl"
export QUOTA_RETRY_INTERVAL=300
export QUOTA_PROBE_MIN_INTERVAL=600
export QUOTA_PROBE_MAX_INTERVAL=1800
export _QUOTA_PAUSE_COUNT=0
export _QUOTA_TOTAL_PAUSE_TIME=0
export _QUOTA_PAUSED=false

mkdir -p "$LOG_DIR" "$TMPDIR/.claude"
touch "$LOG_FILE"

# Source common.sh for log/warn helpers.
source "${TEKHTON_HOME}/lib/common.sh"

# Source quota_probe.sh under test directly (avoids pulling in enter_quota_pause
# and TUI dependencies from quota.sh).
# shellcheck source=../lib/quota_probe.sh
source "${TEKHTON_HOME}/lib/quota_probe.sh"

# --- Test helpers ---
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

# make_shim_dir creates a fake claude binary under $TMPDIR/bin_<tag>/. The
# shim records each invocation to $CLAUDE_LOG (exported in the parent).
# Returns the directory path on stdout so callers can prepend it to PATH.
make_shim_dir() {
    local tag="${1:-default}"
    local dir="$TMPDIR/bin_${tag}"
    mkdir -p "$dir"
    # The shim appends the binary path and all args to CLAUDE_LOG, then exits
    # 0 with a valid version string so mode detection picks "version" mode.
    cat > "$dir/claude" <<'SHIM'
#!/usr/bin/env bash
# CLAUDE_LOG is inherited from the parent environment (exported).
if [ -n "${CLAUDE_LOG:-}" ]; then
    echo "claude $*" >> "$CLAUDE_LOG"
fi
echo "2.1.999 (Claude Code test shim)"
exit 0
SHIM
    chmod +x "$dir/claude"
    echo "$dir"
}

reset_probe_state() {
    _QUOTA_PROBE_MODE=""
    _QUOTA_PROBE_LAST_TS=0
    : > "$CLAUDE_LOG"
}

# Verify the shim infrastructure works before running real tests.
echo "=== Shim self-check ==="
SHIM_DIR=$(make_shim_dir "selfcheck")
OLD_PATH="$PATH"
PATH="$SHIM_DIR:$PATH"
: > "$CLAUDE_LOG"
# Directly call the shim and verify it writes to CLAUDE_LOG.
"$SHIM_DIR/claude" --version >/dev/null 2>&1 || true
if [ -s "$CLAUDE_LOG" ]; then
    echo "  PASS: shim writes to CLAUDE_LOG when called directly"
else
    echo "  FAIL: shim did not write to CLAUDE_LOG — test infrastructure broken"
    FAIL=$((FAIL + 1))
fi
PATH="$OLD_PATH"
: > "$CLAUDE_LOG"

# Also verify via PATH (how _quota_probe calls it).
PATH="$SHIM_DIR:$OLD_PATH"
: > "$CLAUDE_LOG"
command claude --version >/dev/null 2>&1 || true
if [ -s "$CLAUDE_LOG" ]; then
    echo "  PASS: shim writes to CLAUDE_LOG when called via PATH"
else
    echo "  FAIL: shim did not write via PATH — test infrastructure broken"
    FAIL=$((FAIL + 1))
fi
PATH="$OLD_PATH"

# =============================================================================
echo "=== Test A: chain-membership gate — claude absent from PROVIDER spec ==="
# Acceptance criterion 1 of m21: when PROVIDER=codex (no claude), _quota_probe
# must not invoke the claude binary at all.
# =============================================================================

SHIM_DIR=$(make_shim_dir "chaingate")
PATH="$SHIM_DIR:$OLD_PATH"

reset_probe_state
export PROVIDER="codex"
_QUOTA_PROBE_MODE="version"  # Force mode so detect doesn't run (avoids --version call during detection)

_quota_probe 2>/dev/null || true

assert "chain-membership gate: claude not called when PROVIDER=codex" \
    "$([ ! -s "$CLAUDE_LOG" ] && echo 0 || echo 1)"

# Confirm the gate is specific to the spec: claude SHOULD be called when
# PROVIDER=claude.
reset_probe_state
export PROVIDER="claude"
_QUOTA_PROBE_MODE="version"

_quota_probe 2>/dev/null || true

assert "baseline check: claude IS called when PROVIDER=claude" \
    "$([ -s "$CLAUDE_LOG" ] && echo 0 || echo 1)"

PATH="$OLD_PATH"
unset PROVIDER

# =============================================================================
echo "=== Test B: chain-membership gate — multi-provider spec without claude ==="
# PROVIDER=codex,qwen-local: still no claude → no probe.
# =============================================================================

SHIM_DIR=$(make_shim_dir "chaingate2")
PATH="$SHIM_DIR:$OLD_PATH"

reset_probe_state
export PROVIDER="codex,qwen-local"
_QUOTA_PROBE_MODE="version"

_quota_probe 2>/dev/null || true

assert "chain-membership gate: no probe when PROVIDER=codex,qwen-local" \
    "$([ ! -s "$CLAUDE_LOG" ] && echo 0 || echo 1)"

PATH="$OLD_PATH"
unset PROVIDER

# =============================================================================
echo "=== Test C: paid-tier gate — zero-turn probe skipped when TEKHTON_CLAUDE_TIER=api ==="
# Acceptance criterion 2 of m21: when TEKHTON_CLAUDE_TIER=api and
# QUOTA_PROBE_ALLOW_PAID is unset, the zero-turn probe must not call claude.
# =============================================================================

SHIM_DIR=$(make_shim_dir "paidtier_zt")
PATH="$SHIM_DIR:$OLD_PATH"

reset_probe_state
export PROVIDER="claude"
export TEKHTON_CLAUDE_TIER="api"
unset QUOTA_PROBE_ALLOW_PAID 2>/dev/null || true

# Force zero_turn mode so we specifically test that kind.
_QUOTA_PROBE_MODE="zero_turn"

_quota_probe 2>/dev/null || true

assert "paid-tier gate: zero-turn probe not called when tier=api and QUOTA_PROBE_ALLOW_PAID unset" \
    "$([ ! -s "$CLAUDE_LOG" ] && echo 0 || echo 1)"

PATH="$OLD_PATH"
unset PROVIDER TEKHTON_CLAUDE_TIER

# =============================================================================
echo "=== Test D: paid-tier gate — fallback probe skipped when TEKHTON_CLAUDE_TIER=api ==="
# =============================================================================

SHIM_DIR=$(make_shim_dir "paidtier_fb")
PATH="$SHIM_DIR:$OLD_PATH"

reset_probe_state
export PROVIDER="claude"
export TEKHTON_CLAUDE_TIER="api"
unset QUOTA_PROBE_ALLOW_PAID 2>/dev/null || true

_QUOTA_PROBE_MODE="fallback"
_QUOTA_PROBE_LAST_TS=1   # epoch start → elapsed > QUOTA_PROBE_MIN_INTERVAL

_quota_probe 2>/dev/null || true

assert "paid-tier gate: fallback probe not called when tier=api and QUOTA_PROBE_ALLOW_PAID unset" \
    "$([ ! -s "$CLAUDE_LOG" ] && echo 0 || echo 1)"

PATH="$OLD_PATH"
unset PROVIDER TEKHTON_CLAUDE_TIER

# =============================================================================
echo "=== Test E: paid-tier gate — version probe ALLOWED at api tier ==="
# Acceptance criterion 2 of m21: "The free claude --version liveness layer may
# still run" — ProbeVersion is zero-cost and must not be blocked.
# =============================================================================

SHIM_DIR=$(make_shim_dir "paidtier_ver")
PATH="$SHIM_DIR:$OLD_PATH"

reset_probe_state
export PROVIDER="claude"
export TEKHTON_CLAUDE_TIER="api"
unset QUOTA_PROBE_ALLOW_PAID 2>/dev/null || true

_QUOTA_PROBE_MODE="version"

_quota_probe 2>/dev/null || true

assert "paid-tier gate: version probe IS called at api tier (free probe stays active)" \
    "$([ -s "$CLAUDE_LOG" ] && echo 0 || echo 1)"

PATH="$OLD_PATH"
unset PROVIDER TEKHTON_CLAUDE_TIER

# =============================================================================
echo "=== Test F: QUOTA_PROBE_ALLOW_PAID=true restores all probes at api tier ==="
# Acceptance criterion 3 of m21: with QUOTA_PROBE_ALLOW_PAID=true, the
# pre-m21 layered probe behavior is fully restored.
# =============================================================================

SHIM_DIR=$(make_shim_dir "allowpaid_zt")
PATH="$SHIM_DIR:$OLD_PATH"

reset_probe_state
export PROVIDER="claude"
export TEKHTON_CLAUDE_TIER="api"
export QUOTA_PROBE_ALLOW_PAID="true"

_QUOTA_PROBE_MODE="zero_turn"

_quota_probe 2>/dev/null || true

assert "QUOTA_PROBE_ALLOW_PAID=true: zero-turn probe IS called at api tier" \
    "$([ -s "$CLAUDE_LOG" ] && echo 0 || echo 1)"

# Fallback.
SHIM_DIR=$(make_shim_dir "allowpaid_fb")
PATH="$SHIM_DIR:$OLD_PATH"

reset_probe_state
_QUOTA_PROBE_MODE="fallback"
_QUOTA_PROBE_LAST_TS=1

_quota_probe 2>/dev/null || true

assert "QUOTA_PROBE_ALLOW_PAID=true: fallback probe IS called at api tier" \
    "$([ -s "$CLAUDE_LOG" ] && echo 0 || echo 1)"

PATH="$OLD_PATH"
unset PROVIDER TEKHTON_CLAUDE_TIER QUOTA_PROBE_ALLOW_PAID

# =============================================================================
echo "=== Test G: subscription tier — all probes run without QUOTA_PROBE_ALLOW_PAID ==="
# The paid-tier gate is exclusive to tier=api; subscription tier must not be
# affected.
# =============================================================================

SHIM_DIR=$(make_shim_dir "subtier")
PATH="$SHIM_DIR:$OLD_PATH"

reset_probe_state
export PROVIDER="claude"
export TEKHTON_CLAUDE_TIER="subscription"
unset QUOTA_PROBE_ALLOW_PAID 2>/dev/null || true

_QUOTA_PROBE_MODE="zero_turn"

_quota_probe 2>/dev/null || true

assert "subscription tier: zero-turn probe IS called (gate only fires at api tier)" \
    "$([ -s "$CLAUDE_LOG" ] && echo 0 || echo 1)"

PATH="$OLD_PATH"
unset PROVIDER TEKHTON_CLAUDE_TIER

# =============================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
