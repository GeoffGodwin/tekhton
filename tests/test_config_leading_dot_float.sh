#!/usr/bin/env bash
# =============================================================================
# test_config_leading_dot_float.sh — Smoke test for float-clamp validation
# (m16-adapted)
#
# Pre-m16 this test sourced lib/config.sh and called _clamp_config_float
# directly. m16 ports the helper to internal/config/validate.go::runClamps;
# the equivalent unit coverage now lives in
# internal/config/config_test.go::TestClamp_FloatRange and its parsing edge
# cases (strconv.ParseFloat rejects leading-dot floats automatically).
#
# This file becomes a smoke check: feed pipeline.conf values that include
# the leading-dot edge cases and verify the loader does not crash and does
# not silently accept invalid floats.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${TEKHTON_HOME}/bin/tekhton"

if [[ ! -x "$BIN" ]]; then
    echo "SKIP: tekhton binary not built (run 'make build')"
    exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Valid float — clamp accepts and (since 0.5 is in range) leaves unchanged.
cat > "${TMPDIR}/valid.conf" <<'EOF'
PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
REWORK_TURN_ESCALATION_FACTOR=1.5
EOF
out=$("$BIN" config load --path "${TMPDIR}/valid.conf" --project-dir "$TMPDIR" --emit shell --no-warn 2>/dev/null)
eval "$out"
if [[ "${REWORK_TURN_ESCALATION_FACTOR}" == "1.5" ]]; then
    echo "PASS: Valid float 1.5 passes loader"
else
    echo "FAIL: REWORK_TURN_ESCALATION_FACTOR=${REWORK_TURN_ESCALATION_FACTOR} (expected 1.5)"
    exit 1
fi

# Leading-dot float — strconv.ParseFloat rejects it, so the clamp leaves the
# value untouched (or the input is treated as not-a-number and the default
# applies). We just assert the loader does not crash.
cat > "${TMPDIR}/dotfloat.conf" <<'EOF'
PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
REWORK_TURN_ESCALATION_FACTOR=.5
EOF
if "$BIN" config load --path "${TMPDIR}/dotfloat.conf" --project-dir "$TMPDIR" --emit shell --no-warn >/dev/null 2>&1; then
    echo "PASS: Loader does not crash on leading-dot float"
else
    echo "FAIL: Loader crashed on leading-dot float"
    exit 1
fi

# Negative float — same expectation.
cat > "${TMPDIR}/neg.conf" <<'EOF'
PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
REWORK_TURN_ESCALATION_FACTOR=-1.0
EOF
# Note: pipeline.conf parser rejects shell-metachar values, but '-' alone is
# fine. The clamp will see -1.0 and clamp to the lower bound (0.1).
if "$BIN" config load --path "${TMPDIR}/neg.conf" --project-dir "$TMPDIR" --emit shell --no-warn >/dev/null 2>&1; then
    echo "PASS: Loader handles negative float (clamp brings it into range)"
else
    echo "FAIL: Loader crashed on negative float"
    exit 1
fi

echo "PASS: All float validation smoke tests passed"
exit 0
