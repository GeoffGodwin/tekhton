#!/usr/bin/env bash
# =============================================================================
# test_config.sh — Smoke test for the m16 config wedge.
#
# Pre-m16 this file exercised the bash _clamp_config_float helper directly.
# m16 ports the clamp logic to internal/config (Go); the equivalent unit
# coverage now lives in internal/config/config_test.go::TestClamp_FloatRange
# and TestClamp_IntegerExceedsCap.
#
# This file becomes a thin smoke test: build the binary, run a config-load
# round trip on a fixture, and assert the loader produces sourceable output.
# Detailed clamp behavior is covered by the Go-side tests + the parity
# script (scripts/config-parity-check.sh).
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

cat > "${TMPDIR}/pipeline.conf" <<'EOF'
PROJECT_NAME="test"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="echo ok"
REWORK_TURN_ESCALATION_FACTOR=99.0
EOF

# Round trip through the loader and source the result.
out=$("$BIN" config load --path "${TMPDIR}/pipeline.conf" --project-dir "$TMPDIR" --emit shell --no-warn 2>/dev/null)
eval "$out"

# Float-clamp from out-of-range value (99.0 → 10.0) — proves the clamp pipeline runs.
if [[ "${REWORK_TURN_ESCALATION_FACTOR:-}" == "10.0" ]]; then
    echo "PASS: REWORK_TURN_ESCALATION_FACTOR clamped to 10.0"
else
    echo "FAIL: REWORK_TURN_ESCALATION_FACTOR=${REWORK_TURN_ESCALATION_FACTOR:-<unset>} (expected 10.0)"
    exit 1
fi

# Int-clamp behavior is asserted by scripts/config-parity-check.sh and
# internal/config Go tests; this smoke test only exercises the source path.
echo "All config tests passed (smoke check; detailed coverage in Go tests + parity script)"
