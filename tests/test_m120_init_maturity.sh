#!/usr/bin/env bash
# Test: M120 — _classify_project_maturity, _print_init_next_step,
#              artifact_defaults.sh self-healing of empty DESIGN_FILE
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "${label} (=${expected})"
    else
        fail "${label}: expected '${expected}', got '${actual}'"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        pass "${label}"
    else
        fail "${label}: '${needle}' not found in output"
    fi
}

assert_empty() {
    local label="$1" actual="$2"
    if [[ -z "$actual" ]]; then
        pass "${label} (empty as expected)"
    else
        fail "${label}: expected empty output, got: '${actual}'"
    fi
}

# Stubs for output helpers used by _print_init_next_step.
# We capture calls so tests can assert on what was printed.
_OUT_LINES=()
out_section() { _OUT_LINES+=("SECTION:$1"); }
out_msg()     { _OUT_LINES+=("MSG:$*"); }

# Source only the maturity helper — it depends on out_section/out_msg above.
# shellcheck source=../lib/init_helpers_maturity.sh
source "${TEKHTON_HOME}/lib/init_helpers_maturity.sh"

# =============================================================================
# Suite 1: _classify_project_maturity
# =============================================================================
echo "=== Suite 1: _classify_project_maturity ==="

TMPDIR1=$(mktemp -d)
trap 'rm -rf "$TMPDIR1"' EXIT

# 1.1 has_design: $2 (resolved design_file) is non-empty
result=$(_classify_project_maturity "$TMPDIR1" "some/DESIGN.md" 0 0)
assert_eq "1.1 non-empty design_file arg → has_design" "has_design" "$result"

# 1.2 has_design: .tekhton/DESIGN.md exists on disk (no design_file arg)
mkdir -p "${TMPDIR1}/.tekhton"
touch "${TMPDIR1}/.tekhton/DESIGN.md"
result=$(_classify_project_maturity "$TMPDIR1" "" 0 0)
assert_eq "1.2 .tekhton/DESIGN.md on disk → has_design" "has_design" "$result"
rm -f "${TMPDIR1}/.tekhton/DESIGN.md"

# 1.3 has_design: DESIGN.md at project root exists on disk (no design_file arg)
touch "${TMPDIR1}/DESIGN.md"
result=$(_classify_project_maturity "$TMPDIR1" "" 0 0)
assert_eq "1.3 DESIGN.md at root on disk → has_design" "has_design" "$result"
rm -f "${TMPDIR1}/DESIGN.md"

# 1.4 greenfield: ≤5 files and no commands
result=$(_classify_project_maturity "$TMPDIR1" "" 3 0)
assert_eq "1.4 3 files, no commands → greenfield" "greenfield" "$result"

# 1.5 greenfield: exactly 5 files and no commands (boundary)
result=$(_classify_project_maturity "$TMPDIR1" "" 5 0)
assert_eq "1.5 5 files, no commands → greenfield" "greenfield" "$result"

# 1.6 brownfield: ≤5 files but has_commands=1 (commands detected)
result=$(_classify_project_maturity "$TMPDIR1" "" 2 1)
assert_eq "1.6 2 files but has_commands → brownfield" "brownfield" "$result"

# 1.7 brownfield: >5 files and no commands
result=$(_classify_project_maturity "$TMPDIR1" "" 6 0)
assert_eq "1.7 6 files, no commands → brownfield" "brownfield" "$result"

# 1.8 brownfield: >5 files and has_commands
result=$(_classify_project_maturity "$TMPDIR1" "" 100 1)
assert_eq "1.8 large brownfield project → brownfield" "brownfield" "$result"

# =============================================================================
# Suite 2: _print_init_next_step
# =============================================================================
echo "=== Suite 2: _print_init_next_step ==="

# 2.1 has_design → completely silent (no out_section, no out_msg)
_OUT_LINES=()
_print_init_next_step "has_design"
out_count="${#_OUT_LINES[@]}"
if [[ "$out_count" -eq 0 ]]; then
    pass "2.1 has_design → silent (no output calls)"
else
    fail "2.1 has_design → expected no output, got ${out_count} lines"
fi

# 2.2 greenfield → emits "Next step" section and --plan mention
_OUT_LINES=()
_print_init_next_step "greenfield"
joined_output=$(printf '%s\n' "${_OUT_LINES[@]}")
assert_contains "2.2 greenfield → 'Next step' section" "Next step" "$joined_output"
assert_contains "2.2 greenfield → mentions --plan" "--plan" "$joined_output"

# 2.3 brownfield → emits "Next step" section but explicitly avoids pushing --plan
_OUT_LINES=()
_print_init_next_step "brownfield"
joined_output=$(printf '%s\n' "${_OUT_LINES[@]}")
assert_contains "2.3 brownfield → 'Next step' section" "Next step" "$joined_output"
assert_contains "2.3 brownfield → mentions Tekhton is ready" "Tekhton is ready" "$joined_output"

# 2.4 unknown classification → silent (defensive fallback)
_OUT_LINES=()
_print_init_next_step "unknown_type"
out_count="${#_OUT_LINES[@]}"
if [[ "$out_count" -eq 0 ]]; then
    pass "2.4 unknown classification → silent (defensive fallback)"
else
    fail "2.4 unknown classification → expected no output, got ${out_count} lines"
fi

# =============================================================================
# Suite 3: artifact_defaults.sh self-healing of empty DESIGN_FILE
# =============================================================================
echo "=== Suite 3: artifact_defaults.sh self-healing ==="

# 3.1 Sourcing artifact_defaults.sh with DESIGN_FILE="" restores the default.
# This is the core M120 Goal 2 fix: pre-M120 pipeline.conf emitted DESIGN_FILE=""
# which load_plan_config overwrote the in-memory default. Re-sourcing fixes it.
(
    unset TEKHTON_DIR 2>/dev/null || true
    export DESIGN_FILE=""
    # shellcheck source=../lib/artifact_defaults.sh
    source "${TEKHTON_HOME}/lib/artifact_defaults.sh"
    # :=  does NOT overwrite non-empty, but DOES overwrite empty string.
    # With DESIGN_FILE="" set, := should NOT fire (DESIGN_FILE is set, just empty).
    # The expected behavior of `:=` is: only fires if the variable is UNSET or empty.
    if [[ "$DESIGN_FILE" == ".tekhton/DESIGN.md" ]]; then
        echo "SELF_HEAL:ok"
    else
        echo "SELF_HEAL:fail:${DESIGN_FILE}"
    fi
)
subshell_result=$(
    unset TEKHTON_DIR 2>/dev/null || true
    export DESIGN_FILE=""
    source "${TEKHTON_HOME}/lib/artifact_defaults.sh"
    echo "$DESIGN_FILE"
)
assert_eq "3.1 empty DESIGN_FILE self-heals to .tekhton/DESIGN.md" ".tekhton/DESIGN.md" "$subshell_result"

# 3.2 Sourcing artifact_defaults.sh with DESIGN_FILE already set preserves the value.
subshell_result=$(
    unset TEKHTON_DIR 2>/dev/null || true
    export DESIGN_FILE="custom/MY_DESIGN.md"
    source "${TEKHTON_HOME}/lib/artifact_defaults.sh"
    echo "$DESIGN_FILE"
)
assert_eq "3.2 non-empty DESIGN_FILE preserved after sourcing artifact_defaults" \
    "custom/MY_DESIGN.md" "$subshell_result"

# 3.3 With no DESIGN_FILE set at all, gets the canonical default.
subshell_result=$(
    unset TEKHTON_DIR 2>/dev/null || true
    unset DESIGN_FILE 2>/dev/null || true
    source "${TEKHTON_HOME}/lib/artifact_defaults.sh"
    echo "$DESIGN_FILE"
)
assert_eq "3.3 unset DESIGN_FILE gets canonical default" ".tekhton/DESIGN.md" "$subshell_result"

# 3.4 Sourcing artifact_defaults.sh twice is idempotent (no double-default).
subshell_result=$(
    unset TEKHTON_DIR 2>/dev/null || true
    unset DESIGN_FILE 2>/dev/null || true
    source "${TEKHTON_HOME}/lib/artifact_defaults.sh"
    source "${TEKHTON_HOME}/lib/artifact_defaults.sh"
    echo "$DESIGN_FILE"
)
assert_eq "3.4 double-source is idempotent" ".tekhton/DESIGN.md" "$subshell_result"

# =============================================================================
# Results
# =============================================================================
echo
echo "=== M120 init maturity tests: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
