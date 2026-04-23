#!/usr/bin/env bash
# Test: M121 — lib/plan.sh config loader empty-slate behavior.
#
# Exercises load_plan_config + the subsequent artifact_defaults.sh re-source
# added by M120. Three cases:
#   1. pipeline.conf contains DESIGN_FILE="" — self-heals to default.
#   2. pipeline.conf contains DESIGN_FILE="custom/path.md" — user value preserved.
#   3. No pipeline.conf at all — pure default applies.
#
# Also verifies _assert_design_file_usable behavior in isolation.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# _get_design_file — Sources common.sh + plan.sh with a given pipeline.conf
# layout and prints the resulting DESIGN_FILE value.
# Arguments:
#   $1  project_dir   — PROJECT_DIR to use (must exist)
#   $2  conf_content  — pipeline.conf contents (empty string = no file)
_get_design_file() {
    local project_dir="$1"
    local conf_content="$2"

    mkdir -p "${project_dir}/.claude"
    if [[ -n "$conf_content" ]]; then
        printf '%s\n' "$conf_content" > "${project_dir}/.claude/pipeline.conf"
    else
        rm -f "${project_dir}/.claude/pipeline.conf"
    fi

    (
        # Isolated subshell — no DESIGN_FILE leak from the parent env.
        unset DESIGN_FILE
        unset TEKHTON_DIR
        export TEKHTON_HOME PROJECT_DIR="$project_dir"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/common.sh"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/plan.sh"
        echo "${DESIGN_FILE}"
    )
}

# ---------------------------------------------------------------------------
echo "=== Test 1: DESIGN_FILE=\"\" in pipeline.conf self-heals to default ==="

proj_empty="${TMPDIR_BASE}/empty_design"
mkdir -p "$proj_empty"
result=$(_get_design_file "$proj_empty" 'DESIGN_FILE=""')
if [[ "$result" == ".tekhton/DESIGN.md" ]]; then
    pass "empty DESIGN_FILE self-heals to '.tekhton/DESIGN.md'"
else
    fail "expected '.tekhton/DESIGN.md', got '${result}'"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Test 2: Custom DESIGN_FILE value in pipeline.conf is preserved ==="

proj_custom="${TMPDIR_BASE}/custom_design"
mkdir -p "$proj_custom"
result=$(_get_design_file "$proj_custom" 'DESIGN_FILE="custom/path.md"')
if [[ "$result" == "custom/path.md" ]]; then
    pass "custom DESIGN_FILE='custom/path.md' preserved after load_plan_config"
else
    fail "expected 'custom/path.md', got '${result}'"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Test 3: No pipeline.conf — default path applies ==="

proj_nofile="${TMPDIR_BASE}/no_conf"
mkdir -p "$proj_nofile"
result=$(_get_design_file "$proj_nofile" "")
if [[ "$result" == ".tekhton/DESIGN.md" ]]; then
    pass "unset DESIGN_FILE defaults to '.tekhton/DESIGN.md'"
else
    fail "expected '.tekhton/DESIGN.md', got '${result}'"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Test 4: _assert_design_file_usable — empty DESIGN_FILE returns 1 ==="

rc=$(
    unset DESIGN_FILE
    unset TEKHTON_DIR
    export TEKHTON_HOME
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # Intentionally source plan.sh then clobber DESIGN_FILE to empty to
    # simulate a degenerate runtime state.
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    DESIGN_FILE=""
    set +e
    _assert_design_file_usable >/dev/null 2>&1
    echo $?
)
if [[ "$rc" == "1" ]]; then
    pass "_assert_design_file_usable returns 1 when DESIGN_FILE is empty"
else
    fail "expected return 1 on empty DESIGN_FILE, got ${rc}"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Test 5: _assert_design_file_usable — trailing-slash DESIGN_FILE returns 1 ==="

rc=$(
    unset DESIGN_FILE
    unset TEKHTON_DIR
    export TEKHTON_HOME
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    DESIGN_FILE=".tekhton/"
    set +e
    _assert_design_file_usable >/dev/null 2>&1
    echo $?
)
if [[ "$rc" == "1" ]]; then
    pass "_assert_design_file_usable returns 1 when DESIGN_FILE ends in '/'"
else
    fail "expected return 1 on trailing-slash DESIGN_FILE, got ${rc}"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Test 6: _assert_design_file_usable — valid DESIGN_FILE returns 0 ==="

rc=$(
    unset DESIGN_FILE
    unset TEKHTON_DIR
    export TEKHTON_HOME
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    DESIGN_FILE=".tekhton/DESIGN.md"
    set +e
    _assert_design_file_usable >/dev/null 2>&1
    echo $?
)
if [[ "$rc" == "0" ]]; then
    pass "_assert_design_file_usable returns 0 on canonical DESIGN_FILE"
else
    fail "expected return 0 on valid DESIGN_FILE, got ${rc}"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
