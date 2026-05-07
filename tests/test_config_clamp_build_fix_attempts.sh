#!/usr/bin/env bash
# Test: M136 BUILD_FIX_MAX_ATTEMPTS clamp (m16-adapted)
#
# Pre-m16 this test grep'd lib/config_defaults.sh for the
# `_clamp_config_value BUILD_FIX_MAX_ATTEMPTS 20` line. m16 ports clamps to
# internal/config/validate.go::intClamps; the equivalent assertion now runs
# the loader against an out-of-range input and verifies the clamped value.
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
PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
BUILD_FIX_MAX_ATTEMPTS=999
EOF

out=$("$BIN" config load --path "${TMPDIR}/pipeline.conf" --project-dir "$TMPDIR" --emit shell --no-warn 2>/dev/null)
eval "$out"

if [[ "${BUILD_FIX_MAX_ATTEMPTS}" == "20" ]]; then
    echo "PASS: BUILD_FIX_MAX_ATTEMPTS clamped to 20 (out-of-range input → cap)"
    exit 0
else
    echo "FAIL: BUILD_FIX_MAX_ATTEMPTS=${BUILD_FIX_MAX_ATTEMPTS} (expected 20)"
    exit 1
fi
