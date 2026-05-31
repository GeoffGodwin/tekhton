#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# tests/test_buildfix_against_go_gate.sh — m31.1 cross-seam coverage
#
# Asserts that stages/coder_buildfix.sh::_bf_read_raw_errors consumes the
# BUILD_RAW_ERRORS.txt stream produced by the Go gate (m31.1) and that the
# m17 classifier (internal/errors) categorises the failure correctly.
#
# The m31.1 contract: the Go gate's raw-stream format is byte-equivalent to
# the bash gate's. The m128 build-fix loop and the m17 classifier both
# consume BUILD_RAW_ERRORS.txt; regressions on either side surface here.
# =============================================================================

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_BIN="${TEKHTON_BIN:-${REPO_ROOT}/bin/tekhton}"

PASS=0
FAIL=0
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
pass() { PASS=$((PASS+1)); }

if ! command -v go >/dev/null 2>&1; then
    printf 'SKIP test_buildfix_against_go_gate: go toolchain not found\n'
    exit 0
fi
if [[ ! -x "$TEKHTON_BIN" ]]; then
    if ! (cd "$REPO_ROOT" && make build >/dev/null 2>&1); then
        printf 'SKIP test_buildfix_against_go_gate: make build failed\n'
        exit 0
    fi
fi

# --- Drive the Go gate to produce BUILD_RAW_ERRORS.txt --------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "${tmp}/.tekhton"

env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    TMPDIR="$tmp" \
    TEKHTON_DIR=".tekhton" \
    PROJECT_DIR="$tmp" \
    ANALYZE_CMD="printf 'error TS2304: cannot find name foo\\n'" \
    ANALYZE_ERROR_PATTERN="error" \
    "$TEKHTON_BIN" gate build --stage-label post-coder \
    >/dev/null 2>&1 || true

raw="${tmp}/.tekhton/BUILD_RAW_ERRORS.txt"
md="${tmp}/.tekhton/BUILD_ERRORS.md"
if [[ -f "$raw" ]]; then
    pass
else
    fail "Go gate did not produce BUILD_RAW_ERRORS.txt at $raw"
fi
if [[ -f "$md" ]]; then
    pass
else
    fail "Go gate did not produce BUILD_ERRORS.md at $md"
fi

# --- Exercise _bf_read_raw_errors against the Go-written stream ----------
# Source the helpers that depend on lib/prompts.sh's _safe_read_file in
# isolation. stages/coder_buildfix_helpers.sh has the count + tail helpers
# the m128 loop uses.
export TEKHTON_HOME="$REPO_ROOT"
export BUILD_RAW_ERRORS_FILE="$raw"
export BUILD_ERRORS_FILE="$md"

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/prompts.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/prompts_io.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/stages/coder_buildfix_helpers.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/stages/coder_buildfix.sh"

# _bf_read_raw_errors should return the raw stream verbatim (the m31.1
# byte-identical contract). Compare against the file contents.
expected_stream=$(cat "$raw")
got_stream=$(_bf_read_raw_errors)
if [[ "$got_stream" == *"$expected_stream"* ]]; then
    pass
else
    fail "_bf_read_raw_errors output did not contain the Go-written stream"
    echo "--- expected substring ---" >&2
    printf '%s\n' "$expected_stream" >&2
    echo "--- got ---" >&2
    printf '%s\n' "$got_stream" >&2
fi

# _bf_count_errors should report at least one error.
err_count=$(_bf_count_errors "$raw")
if [[ "$err_count" -ge 1 ]]; then
    pass
else
    fail "_bf_count_errors returned 0 against Go-written stream"
fi

# --- Exercise the m17 classifier against the same stream ------------------
# `tekhton diagnose classify --mode routing` returns one of the four M127
# routing tokens (code_dominant / noncode_dominant / mixed_uncertain /
# unknown_only). A TS2304 line is code-dominant.
routing=$("$TEKHTON_BIN" diagnose classify --mode routing < "$raw" 2>/dev/null || true)
case "$routing" in
    code_dominant)
        pass
        ;;
    *)
        fail "diagnose classify returned $routing for code error; expected code_dominant"
        ;;
esac

echo ""
echo "test_buildfix_against_go_gate: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
