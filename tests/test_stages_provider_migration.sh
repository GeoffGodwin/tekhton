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

# --- Check 3: Runner provider dispatch exists ---------------------------
# m15 replaced m02's single Runner.Provider field with per-stage dispatch
# via providerForStage() + ResolveProvider(). Assert the new architecture:
# the runner exposes a providerForStage method that resolves a provider
# (verified by the Go unit tests TestProviderForStage_*).
RUNNER_DISPATCH=""
RUNNER_DISPATCH=$(grep -cE 'func \(r \*Runner\) providerForStage' \
    "${TEKHTON_HOME}/internal/runner/runner.go" 2>/dev/null) || RUNNER_DISPATCH=0

if [[ "${RUNNER_DISPATCH:-0}" -ge 1 ]]; then
    pass "internal/runner/runner.go declares providerForStage dispatch"
else
    fail "internal/runner/runner.go missing providerForStage dispatch method"
fi

# Run the Go unit tests that assert per-stage resolution works.
if go test -run 'TestProviderForStage_' \
       "${TEKHTON_HOME}/internal/runner/..." \
       -count=1 -timeout 30s \
       > /dev/null 2>&1; then
    pass "providerForStage returns non-nil provider and caches (TestProviderForStage_*)"
else
    fail "providerForStage Go unit tests failed"
fi

# --- Summary ---------------------------------------------------------------
echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "$FAIL_COUNT" -eq 0 ]]
