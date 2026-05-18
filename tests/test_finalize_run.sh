#!/usr/bin/env bash
# =============================================================================
# test_finalize_run.sh — m21. The bash finalize_run orchestrator + 26-hook
# registry moved to internal/finalize.Orchestrator. The exhaustive hook-
# ordering / dispatch / error-propagation tests that previously lived here
# are now in internal/finalize/orchestrator_test.go (Go), where they can
# assert against the canonical 26-hook registration table.
#
# This file is now a thin smoke test: it verifies the bash compatibility
# shim (`lib/finalize.sh::finalize_run`) is callable, sources the right
# files, and delegates to `tekhton finalize` (or no-ops cleanly when the
# Go binary is absent).
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0
FAIL=0

assert() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: ${name}"
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${name} (expected ${expected}, got ${actual})"
        FAIL=$((FAIL + 1))
    fi
}

# Smoke 1: lib/finalize.sh sources without error.
(
    cd "$TEKHTON_HOME"
    # shellcheck source=/dev/null
    source lib/common.sh
    # shellcheck source=/dev/null
    source lib/finalize.sh
    declare -f finalize_run > /dev/null
)
assert "lib/finalize.sh sources and defines finalize_run" "0" "$?"

# Smoke 2: finalize_run delegates to tekhton finalize.
SHIM_BODY=$(
    cd "$TEKHTON_HOME"
    # shellcheck source=/dev/null
    source lib/common.sh
    # shellcheck source=/dev/null
    source lib/finalize.sh
    declare -f finalize_run
)
DELEGATION_OK=1
# Pattern: function body must reference $tekhton_bin and the `finalize`
# subcommand name. The actual invocation is `"$tekhton_bin" finalize ...`.
# shellcheck disable=SC2016  # grep needs the literal $tekhton_bin token from the shell function body
if echo "$SHIM_BODY" | grep -q 'tekhton_bin' && echo "$SHIM_BODY" | grep -Eq '"\$tekhton_bin"[[:space:]]+finalize|tekhton_bin.*finalize'; then
    DELEGATION_OK=0
fi
assert "finalize_run delegates to tekhton finalize" "0" "$DELEGATION_OK"

# Smoke 3: lib/finalize.sh no longer defines register_finalize_hook or
# the FINALIZE_HOOKS array — the registry moved to Go. Use a subshell so
# any leaks from earlier sources don't pollute the check.
REGISTRY_GONE=0
(
    cd "$TEKHTON_HOME"
    set +u
    # shellcheck source=/dev/null
    source lib/common.sh 2>/dev/null || true
    # shellcheck source=/dev/null
    source lib/finalize.sh 2>/dev/null || true
    if declare -f register_finalize_hook >/dev/null 2>&1; then
        exit 1
    fi
    if declare -p FINALIZE_HOOKS >/dev/null 2>&1; then
        exit 1
    fi
    exit 0
) && REGISTRY_GONE=0 || REGISTRY_GONE=1
assert "register_finalize_hook + FINALIZE_HOOKS removed from bash" "0" "$REGISTRY_GONE"

# Smoke 4: lib/finalize.sh is under the 50-line acceptance criterion.
lines=$(wc -l < "${TEKHTON_HOME}/lib/finalize.sh")
LINE_OK=1
if [[ "$lines" -le 50 ]]; then
    LINE_OK=0
fi
assert "lib/finalize.sh ≤ 50 lines (got ${lines})" "0" "$LINE_OK"

# Smoke 5: lib/finalize_shim.sh exists and is readable.
SHIM_PRESENT=1
[[ -r "${TEKHTON_HOME}/lib/finalize_shim.sh" ]] && SHIM_PRESENT=0
assert "lib/finalize_shim.sh present" "0" "$SHIM_PRESENT"

# Smoke 6: lib/finalize_core_hooks.sh defines the five remaining bash bodies.
HOOK_BODIES_OK=1
(
    cd "$TEKHTON_HOME"
    # shellcheck source=/dev/null
    source lib/common.sh
    # shellcheck source=/dev/null
    source lib/finalize_core_hooks.sh
    declare -f _hook_final_checks > /dev/null
    declare -f _hook_drift_artifacts > /dev/null
    declare -f _hook_record_metrics > /dev/null
    declare -f _hook_cleanup_resolved > /dev/null
    declare -f _hook_resolve_notes > /dev/null
) && HOOK_BODIES_OK=0
assert "lib/finalize_core_hooks.sh defines five remaining bash hooks" "0" "$HOOK_BODIES_OK"

echo
echo "=== test_finalize_run.sh: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
