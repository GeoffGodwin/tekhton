#!/usr/bin/env bash
# Test: Runtime CI environment auto-detection (m138 → m16 wedge)
#
# Pre-m16 the CI helpers (_detect_runtime_ci_environment, _get_ci_platform_name,
# _apply_ci_ui_gate_defaults) lived in lib/config_defaults_ci.sh and were
# exercised by sourcing that file directly. m16 ports the logic to
# internal/config/ci.go and routes it through `tekhton config load`.
#
# This test now drives the Go binary: each case writes a minimal pipeline.conf,
# invokes `tekhton config load --emit shell` with controlled CI env vars, and
# asserts the resulting TEKHTON_UI_GATE_FORCE_NONINTERACTIVE +
# TEKHTON_CI_ENVIRONMENT_DETECTED values match the m138 contract.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${TEKHTON_HOME}/bin/tekhton"

if [[ ! -x "$BIN" ]]; then
    echo "SKIP: tekhton binary not built (run 'make build')"
    exit 0
fi

PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Shared minimal pipeline.conf — required keys only. Each test reuses it.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
cat > "${TMPDIR}/min.conf" <<'EOF'
PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="echo ok"
EOF
cat > "${TMPDIR}/explicit.conf" <<'EOF'
PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="echo ok"
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0
EOF

# Run the loader with a clean env populated by the args; return the value of
# one resolved key. Args after KEY are exported only for this single
# invocation, isolating CI signals.
# Usage: _read CONF KEY [VAR=value ...]
_read() {
    local conf="$1" key="$2"; shift 2
    local payload
    payload=$(env -i PATH="$PATH" HOME="$HOME" "$@" \
        "$BIN" config load --path "$conf" --project-dir "$TMPDIR" \
        --emit shell --no-warn 2>/dev/null) || return 1
    (
        eval "$payload"
        eval "printf '%s' \"\${${key}-}\""
    )
}

# Detect-only check (does the loader see any CI signal?). Mirrors
# _detect_runtime_ci_environment's pure return-code semantics.
_detected() {
    local conf="$1"; shift
    local got
    got=$(_read "$conf" TEKHTON_CI_ENVIRONMENT_DETECTED "$@") || return 1
    [[ "$got" == "1" ]]
}

# Read the human-readable platform name. The Go side carries it on the JSON
# output so use that path here. Returns empty string when no CI is detected.
# Usage: _platform CONF [VAR=value ...]
_platform() {
    local conf="$1" json line; shift
    json=$(env -i PATH="$PATH" HOME="$HOME" "$@" \
        "$BIN" config load --path "$conf" --project-dir "$TMPDIR" \
        --emit json --no-warn 2>/dev/null) || return 1
    line=$(printf '%s' "$json" | grep -oE '"ci_platform":[[:space:]]*"[^"]*"' | head -1 || true)
    [[ -z "$line" ]] && { echo ""; return 0; }
    printf '%s' "$line" | sed -E 's/.*"ci_platform":[[:space:]]*"([^"]*)".*/\1/'
}

echo "=== T1: No CI vars set → no detection ==="
if _detected "${TMPDIR}/min.conf"; then
    fail "T1: expected no CI, got detection=1"
else
    pass "T1: no CI signals → detected=0"
fi
out=$(_platform "${TMPDIR}/min.conf")
[[ -z "$out" ]] && pass "T1: platform name empty" || fail "T1: platform expected empty, got '$out'"

echo "=== T2: GITHUB_ACTIONS=true → GitHub Actions ==="
_detected "${TMPDIR}/min.conf" GITHUB_ACTIONS=true && pass "T2: detected" || fail "T2: not detected"
out=$(_platform "${TMPDIR}/min.conf" GITHUB_ACTIONS=true)
[[ "$out" == "GitHub Actions" ]] && pass "T2: platform name 'GitHub Actions'" || fail "T2: platform expected 'GitHub Actions', got '$out'"

echo "=== T3: GITLAB_CI=true → GitLab CI ==="
_detected "${TMPDIR}/min.conf" GITLAB_CI=true && pass "T3: detected" || fail "T3: not detected"
out=$(_platform "${TMPDIR}/min.conf" GITLAB_CI=true)
[[ "$out" == "GitLab CI" ]] && pass "T3: platform name 'GitLab CI'" || fail "T3: platform expected 'GitLab CI', got '$out'"

echo "=== T4: CIRCLECI=true → CircleCI ==="
out=$(_platform "${TMPDIR}/min.conf" CIRCLECI=true)
[[ "$out" == "CircleCI" ]] && pass "T4: CircleCI" || fail "T4: got '$out'"

echo "=== T5: JENKINS_URL non-empty → Jenkins ==="
out=$(_platform "${TMPDIR}/min.conf" JENKINS_URL=http://j.example.com/)
[[ "$out" == "Jenkins" ]] && pass "T5: Jenkins" || fail "T5: got '$out'"

echo "=== T6: CI=true → CI (generic) ==="
out=$(_platform "${TMPDIR}/min.conf" CI=true)
[[ "$out" == "CI (generic)" ]] && pass "T6: CI (generic)" || fail "T6: got '$out'"

echo "=== T7: CI detected + key absent → auto-elevate to 1 ==="
out=$(_read "${TMPDIR}/min.conf" TEKHTON_UI_GATE_FORCE_NONINTERACTIVE GITHUB_ACTIONS=true)
[[ "$out" == "1" ]] && pass "T7: TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1" || fail "T7: got '$out'"
out=$(_read "${TMPDIR}/min.conf" TEKHTON_CI_ENVIRONMENT_DETECTED GITHUB_ACTIONS=true)
[[ "$out" == "1" ]] && pass "T7: TEKHTON_CI_ENVIRONMENT_DETECTED=1" || fail "T7: got '$out'"

echo "=== T8: Explicit pipeline.conf =0 wins over CI detection ==="
out=$(_read "${TMPDIR}/explicit.conf" TEKHTON_UI_GATE_FORCE_NONINTERACTIVE GITHUB_ACTIONS=true)
[[ "$out" == "0" ]] && pass "T8: explicit =0 honoured" || fail "T8: got '$out'"
# When the user explicitly sets the key, the env-detected flag still reports
# the underlying CI signal so downstream diagnostics (gates_ui_helpers.sh)
# can still annotate the run.
out=$(_read "${TMPDIR}/explicit.conf" TEKHTON_CI_ENVIRONMENT_DETECTED GITHUB_ACTIONS=true)
[[ "$out" == "1" ]] && pass "T8: detection flag still records CI" || fail "T8: got '$out'"

echo "=== T9: No CI + no conf key → defaults to 0 ==="
out=$(_read "${TMPDIR}/min.conf" TEKHTON_UI_GATE_FORCE_NONINTERACTIVE)
[[ "$out" == "0" ]] && pass "T9: defaults to 0 outside CI" || fail "T9: got '$out'"
out=$(_read "${TMPDIR}/min.conf" TEKHTON_CI_ENVIRONMENT_DETECTED)
[[ "$out" == "0" ]] && pass "T9: detection flag = 0" || fail "T9: got '$out'"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
