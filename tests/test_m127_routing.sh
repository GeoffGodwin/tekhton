#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_m127_routing.sh — Confidence-based mixed-log routing tests (M127)
#
# Covers:
#   _is_non_diagnostic_line          — allow-list-first noise filter
#   has_explicit_code_errors         — code evidence detector
#   classify_build_errors_with_stats — multi-line stats classifier
#   classify_routing_decision        — four-token routing emitter +
#                                      LAST_BUILD_CLASSIFICATION export
#   _bf_emit_routing_diagnosis       — BUILD_ROUTING_DIAGNOSIS.md writer
#   has_only_noncode_errors          — bifl-tracker shape (env+noise) bypass
#
# Acceptance criteria mapped here per m127-mixed-log-classification-hardening.md.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
export TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/error_patterns.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/prompts.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/stages/coder_buildfix.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# _is_non_diagnostic_line — allow-list precedence
# =============================================================================
echo "=== _is_non_diagnostic_line allow-list precedence ==="

if _is_non_diagnostic_line "npm warn config production Use --omit=dev instead"; then
    pass
else
    fail "Plain 'npm warn' line should be filtered as noise"
fi

# Inversion case (acceptance: test_filter_does_not_drop_failure_lines):
# allow-list MUST run before deny-list.
if ! _is_non_diagnostic_line "npm warn: TS2304: Cannot find name 'foo'"; then
    pass
else
    fail "npm warn line containing TS2304 must NOT be filtered (allow-list precedence)"
fi
if ! _is_non_diagnostic_line "[1/8] timeout while connecting"; then
    pass
else
    fail "Progress-line shape with 'timeout' must NOT be filtered"
fi
if ! _is_non_diagnostic_line "Serving HTML report at http://h: error TS2345"; then
    pass
else
    fail "Report-serving line containing 'error' must NOT be filtered"
fi
if ! _is_non_diagnostic_line "ECONNREFUSED 127.0.0.1:5432"; then
    pass
else
    fail "ECONNREFUSED line must NOT be filtered"
fi
if ! _is_non_diagnostic_line "Test failed: assertion mismatch"; then
    pass
else
    fail "'failed' line must NOT be filtered"
fi

# Deny-list path (no failure terms present)
if _is_non_diagnostic_line "Serving HTML report at http://localhost:9323"; then
    pass
else
    fail "Report-serving line without failure terms should be filtered"
fi
if _is_non_diagnostic_line "Press Ctrl+C to quit."; then
    pass
else
    fail "Press Ctrl+C to quit line should be filtered"
fi
if _is_non_diagnostic_line "[3/8] Resolving dependencies"; then
    pass
else
    fail "[3/8] progress line should be filtered"
fi
if _is_non_diagnostic_line "    "; then
    pass
else
    fail "Whitespace-only line should be filtered"
fi

# =============================================================================
# has_explicit_code_errors
# =============================================================================
echo "=== has_explicit_code_errors ==="

if has_explicit_code_errors "error TS2304: Cannot find name 'foo'"; then
    pass
else
    fail "TS2304 line should yield explicit code evidence"
fi
if ! has_explicit_code_errors "ECONNREFUSED 127.0.0.1:5432"; then
    pass
else
    fail "ECONNREFUSED alone should NOT yield code evidence"
fi
if ! has_explicit_code_errors "some completely unknown blob with no recognized signature"; then
    pass
else
    fail "Unmatched line must NOT count as code evidence (M127 fix)"
fi
if ! has_explicit_code_errors ""; then
    pass
else
    fail "Empty input must return 1"
fi

# =============================================================================
# classify_build_errors_with_stats — explicit unknown semantics
# =============================================================================
echo "=== classify_build_errors_with_stats ==="

stats_pure=$(classify_build_errors_with_stats "ECONNREFUSED 127.0.0.1:5432")
if echo "$stats_pure" | grep -q "^service_dep|"; then
    pass
else
    fail "Stats: pure noncode missing service_dep record: ${stats_pure}"
fi
field_count=$(echo "$stats_pure" | head -1 | awk -F'|' '{print NF}')
if [[ "$field_count" -eq 8 ]]; then
    pass
else
    fail "Stats record should have 8 fields, got ${field_count}: ${stats_pure}"
fi

stats_with_unmatched=$(classify_build_errors_with_stats "ECONNREFUSED 127.0.0.1:5432
some unknown line with no signature
another unknown phrase here")
unmatched_field=$(echo "$stats_with_unmatched" | head -1 | awk -F'|' '{print $8}')
if [[ "$unmatched_field" -eq 2 ]]; then
    pass
else
    fail "Stats: expected unmatched_lines=2, got ${unmatched_field}: ${stats_with_unmatched}"
fi
# Critical M127 invariant: stats helper does NOT emit code records for unknowns.
if ! echo "$stats_with_unmatched" | grep -q "^code|"; then
    pass
else
    fail "Stats helper must NOT emit code record for unmatched lines (M127): ${stats_with_unmatched}"
fi

# =============================================================================
# classify_routing_decision — token vocabulary + LAST_BUILD_CLASSIFICATION
# =============================================================================
# Helper: validate token + export contract together. The export from the
# function body lives in the command-substitution subshell, so we re-invoke
# the function in-shell (with stdout discarded) to check the export.
_check_routing() {
    local input="$1" expected="$2" label="$3"
    local got
    got=$(classify_routing_decision "$input")
    if [[ "$got" == "$expected" ]]; then
        pass
    else
        fail "${label}: expected ${expected}, got ${got}"
    fi
    unset LAST_BUILD_CLASSIFICATION
    classify_routing_decision "$input" > /dev/null
    if [[ "${LAST_BUILD_CLASSIFICATION:-}" == "$expected" ]]; then
        pass
    else
        fail "${label}: LAST_BUILD_CLASSIFICATION expected ${expected}, got '${LAST_BUILD_CLASSIFICATION:-<unset>}'"
    fi
}

echo "=== classify_routing_decision: code_dominant ==="
_check_routing "error TS2304: Cannot find name 'foo'" "code_dominant" "pure code"

# test_classify_routing_code_dominant_mixed
mixed_code_noise="error TS2345: Type mismatch
error TS2304: Cannot find name 'bar'
npm warn deprecated foo
some unmatched banner
[1/8] running"
_check_routing "$mixed_code_noise" "code_dominant" "code+noise"

echo "=== classify_routing_decision: noncode_dominant ==="
# test_classify_routing_noncode_dominant_noisy_timeout — realistic fixture
fixture_content=$(cat "${TEKHTON_HOME}/tests/fixtures/ui_timeout_noisy_output.txt")
_check_routing "$fixture_content" "noncode_dominant" "noisy UI timeout fixture"

_check_routing "ECONNREFUSED 127.0.0.1:5432
ECONNREFUSED 127.0.0.1:6379
Cannot find module 'express'" "noncode_dominant" "pure multi-noncode"

echo "=== classify_routing_decision: mixed_uncertain ==="
# test_classify_routing_mixed_uncertain
mixed_in="error TS2304: Cannot find name 'foo'
ECONNREFUSED 127.0.0.1:5432
ECONNREFUSED 127.0.0.1:6379"
_check_routing "$mixed_in" "mixed_uncertain" "code(1)+noncode(2)"

echo "=== classify_routing_decision: unknown_only ==="
# test_classify_routing_unknown_only
unknown_in="completely unrecognised banner one
another mystery line
yet another unknown phrase"
_check_routing "$unknown_in" "unknown_only" "all-unknown"

# Empty input → unknown_only via export
_check_routing "" "unknown_only" "empty input"

echo "=== Token vocabulary restricted to four values ==="
for input in "" "error TS2345" "ECONNREFUSED 127.0.0.1:5432" "unknown banner"; do
    tok=$(classify_routing_decision "$input")
    case "$tok" in
        code_dominant|noncode_dominant|mixed_uncertain|unknown_only) pass ;;
        *) fail "Token '${tok}' not in restricted vocabulary" ;;
    esac
done

# =============================================================================
# has_only_noncode_errors — bifl-tracker class fix
# =============================================================================
echo "=== has_only_noncode_errors: env+noise → bypass (M127 fix) ==="
bifl_shape="ECONNREFUSED 127.0.0.1:5432
some unrecognized banner
another unknown phrase"
if has_only_noncode_errors "$bifl_shape"; then
    pass
else
    fail "M127 fix: env-only failure plus noise should bypass (return 0)"
fi

# =============================================================================
# _bf_emit_routing_diagnosis — BUILD_ROUTING_DIAGNOSIS.md writer
# =============================================================================
echo "=== _bf_emit_routing_diagnosis writes BUILD_ROUTING_DIAGNOSIS.md ==="

_TMP_TEKHTON=$(mktemp -d)
trap 'rm -rf "$_TMP_TEKHTON"' EXIT
mkdir -p "$_TMP_TEKHTON/.tekhton"
export BUILD_ROUTING_DIAGNOSIS_FILE="${_TMP_TEKHTON}/.tekhton/BUILD_ROUTING_DIAGNOSIS.md"

mu_in="error TS2304: Cannot find name 'foo'
ECONNREFUSED 127.0.0.1:5432
ECONNREFUSED 127.0.0.1:6379"

_bf_emit_routing_diagnosis "$mu_in"

if [[ -f "${BUILD_ROUTING_DIAGNOSIS_FILE}" ]]; then
    pass
else
    fail "_bf_emit_routing_diagnosis should write ${BUILD_ROUTING_DIAGNOSIS_FILE}"
fi
if grep -q "Routing Decision" "${BUILD_ROUTING_DIAGNOSIS_FILE}" 2>/dev/null; then
    pass
else
    fail "Diagnosis file missing 'Routing Decision' section"
fi
if grep -q "Top Diagnoses" "${BUILD_ROUTING_DIAGNOSIS_FILE}" 2>/dev/null; then
    pass
else
    fail "Diagnosis file missing 'Top Diagnoses' section"
fi
if grep -q "PostgreSQL not running" "${BUILD_ROUTING_DIAGNOSIS_FILE}" 2>/dev/null; then
    pass
else
    fail "Diagnosis file should include service_dep diagnosis text"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "--------------------------------------"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "--------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "M127 routing tests passed"
