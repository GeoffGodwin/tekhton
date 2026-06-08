#!/usr/bin/env bash
# Shim-boundary regression guard for m02: stages-consume-provider migration.
#
# Asserts the structural completion of m02 without requiring a live Claude
# binary or a real project. Three checks:
#
#   1. grep -nE 'internal/supervisor' internal/stages/ returns zero matches
#      (no stage package imports supervisor after the migration).
#   2. grep -nE 'Provider provider.Provider' internal/stages/*/config.go
#      returns exactly 8 matches (one per migrated stage).
#   3. internal/runner/runner.go carries a Provider field and runner.New()
#      wires it to a non-nil value (verified by the Go unit test added in m02).
#
# Self-skips when the Go binary is not built (same pattern as other
# shim-boundary tests in this directory). Does NOT spin up real agents.
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# --- skip guard -----------------------------------------------------------
TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"
if [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "SKIP: tekhton binary not built at ${TEKHTON_BIN} — run 'make build' first"
    exit 0
fi

# --- Check 1: no supervisor imports in stages ----------------------------
SUPERVISOR_LINES=""
SUPERVISOR_LINES=$(grep -rnE 'internal/supervisor' \
    "${TEKHTON_HOME}/internal/stages/" \
    --include='*.go' \
    --exclude='*_test.go' 2>/dev/null) || SUPERVISOR_LINES=""

if [[ -z "$SUPERVISOR_LINES" ]]; then
    pass "No direct supervisor imports in internal/stages/ (non-test files)"
else
    SUPERVISOR_REFS=$(echo "$SUPERVISOR_LINES" | wc -l)
    fail "Found ${SUPERVISOR_REFS} supervisor import(s) in internal/stages/"
    echo "$SUPERVISOR_LINES"
fi

# --- Check 2: Provider field in every stage config -------------------------
PROVIDER_LINES=""
PROVIDER_LINES=$(grep -rnE 'Provider provider\.Provider' \
    "${TEKHTON_HOME}/internal/stages/"*/config.go 2>/dev/null) || PROVIDER_LINES=""
PROVIDER_FIELDS=0
if [[ -n "$PROVIDER_LINES" ]]; then
    PROVIDER_FIELDS=$(echo "$PROVIDER_LINES" | wc -l)
fi

if [[ "$PROVIDER_FIELDS" -ge 8 ]]; then
    pass "Provider provider.Provider field found in ${PROVIDER_FIELDS} stage config files (want ≥8)"
else
    fail "Only ${PROVIDER_FIELDS} stage config file(s) carry a Provider field (want ≥8)"
fi

# --- Check 3: Runner.Provider field present and non-nil -----------------
RUNNER_PROVIDER=""
RUNNER_PROVIDER=$(grep -cE 'Provider provider\.Provider' \
    "${TEKHTON_HOME}/internal/runner/runner.go" 2>/dev/null) || RUNNER_PROVIDER=0

if [[ "${RUNNER_PROVIDER:-0}" -ge 1 ]]; then
    pass "internal/runner/runner.go declares Provider provider.Provider"
else
    fail "internal/runner/runner.go missing Provider provider.Provider field"
fi

# Run the Go unit test that asserts New().Provider != nil.
if go test -run TestNew_ProviderNonNil \
       "${TEKHTON_HOME}/internal/runner/..." \
       -count=1 -timeout 30s \
       > /dev/null 2>&1; then
    pass "runner.New().Provider != nil (Go unit test TestNew_ProviderNonNil)"
else
    fail "runner.New().Provider == nil — New() does not wire the default provider"
fi

# --- Summary ---------------------------------------------------------------
echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "$FAIL_COUNT" -eq 0 ]]
