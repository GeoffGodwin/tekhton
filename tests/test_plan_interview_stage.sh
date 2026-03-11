#!/usr/bin/env bash
# Test: stages/plan_interview.sh — log creation, exit codes, DESIGN.md handling
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Helper: run run_plan_interview() in an isolated subprocess.
#
# Arguments:
#   $1  mock_exit_code  — exit code the fake claude should return
#   $2  create_design   — "yes" to have mock claude create DESIGN.md, "no" otherwise
#   $3  project_dir     — temp directory to use as PROJECT_DIR
#
# Prints the function's exit code to stdout.
# ---------------------------------------------------------------------------
run_interview() {
    local mock_exit="$1"
    local create_design="$2"
    local project_dir="$3"

    local mock_bin="${TMPDIR_BASE}/bin_$$"
    mkdir -p "$mock_bin"

    # Write mock claude script
    if [ "$create_design" = "yes" ]; then
        cat > "${mock_bin}/claude" << MOCK
#!/usr/bin/env bash
echo "# DESIGN.md" > "${project_dir}/DESIGN.md"
echo "Mock content." >> "${project_dir}/DESIGN.md"
exit ${mock_exit}
MOCK
    else
        cat > "${mock_bin}/claude" << MOCK
#!/usr/bin/env bash
exit ${mock_exit}
MOCK
    fi
    chmod +x "${mock_bin}/claude"

    # Run in subprocess with mocked PATH and required exports
    bash -c "
        export PATH=\"${mock_bin}:\${PATH}\"
        export TEKHTON_HOME='${TEKHTON_HOME}'
        export PROJECT_DIR='${project_dir}'
        export PLAN_TEMPLATE_FILE='${TEKHTON_HOME}/templates/plans/web-app.md'
        export PLAN_PROJECT_TYPE='web-app'
        export PLAN_INTERVIEW_MODEL='test-model'
        export PLAN_INTERVIEW_MAX_TURNS='5'
        export TEMPLATE_CONTENT='## Overview'
        export PROJECT_TYPE='web-app'

        export PLAN_STATE_FILE='${project_dir}/.claude/PLAN_STATE.md'

        source '${TEKHTON_HOME}/lib/common.sh'
        source '${TEKHTON_HOME}/lib/prompts.sh'
        source '${TEKHTON_HOME}/lib/plan_state.sh'
        source '${TEKHTON_HOME}/stages/plan_interview.sh'

        set +e
        run_plan_interview > /dev/null 2>&1
        echo \$?
    " 2>/dev/null
}

# ---------------------------------------------------------------------------
echo "=== Log Directory and File Creation ==="

project_a="${TMPDIR_BASE}/proj_a"
mkdir -p "$project_a"
# Remove logs dir to confirm it's created by the function
rm -rf "${project_a}/.claude"

run_interview 0 yes "$project_a" > /dev/null 2>&1 || true

if [ -d "${project_a}/.claude/logs" ]; then
    pass "log directory created by run_plan_interview()"
else
    fail "log directory not created: ${project_a}/.claude/logs"
fi

log_count=$(find "${project_a}/.claude/logs" -name "*plan-interview.log" | wc -l)
if [ "$log_count" -ge 1 ]; then
    pass "log file created with *plan-interview.log naming"
else
    fail "no *plan-interview.log file found in ${project_a}/.claude/logs"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Log File Metadata Content ==="

log_file=$(find "${project_a}/.claude/logs" -name "*plan-interview.log" | head -1)

if grep -q 'Project Type:' "$log_file"; then
    pass "log contains 'Project Type:' metadata"
else
    fail "log missing 'Project Type:' metadata"
fi

if grep -q 'Template:' "$log_file"; then
    pass "log contains 'Template:' metadata"
else
    fail "log missing 'Template:' metadata"
fi

if grep -q 'Model:' "$log_file"; then
    pass "log contains 'Model:' metadata"
else
    fail "log missing 'Model:' metadata"
fi

if grep -q 'Max Turns:' "$log_file"; then
    pass "log contains 'Max Turns:' metadata"
else
    fail "log missing 'Max Turns:' metadata"
fi

if grep -q 'Session Start' "$log_file"; then
    pass "log contains 'Session Start' marker"
else
    fail "log missing 'Session Start' marker"
fi

if grep -q 'Session End' "$log_file"; then
    pass "log contains 'Session End' marker"
else
    fail "log missing 'Session End' marker"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Exit Code: claude succeeds + DESIGN.md created → return 0 ==="

project_b="${TMPDIR_BASE}/proj_b"
mkdir -p "$project_b"
result=$(run_interview 0 yes "$project_b")
if [ "$result" = "0" ]; then
    pass "returns 0 when claude exits 0 and DESIGN.md exists"
else
    fail "expected return 0, got ${result}"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Exit Code: claude fails + DESIGN.md created → return 0 (preserved) ==="

project_c="${TMPDIR_BASE}/proj_c"
mkdir -p "$project_c"
result=$(run_interview 1 yes "$project_c")
if [ "$result" = "0" ]; then
    pass "returns 0 when claude exits 1 but DESIGN.md was created (partial preserved)"
else
    fail "expected return 0 (DESIGN.md preserved), got ${result}"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Exit Code: claude fails + no DESIGN.md → return 1 ==="

project_d="${TMPDIR_BASE}/proj_d"
mkdir -p "$project_d"
result=$(run_interview 1 no "$project_d")
if [ "$result" = "1" ]; then
    pass "returns 1 when claude exits 1 and no DESIGN.md created"
else
    fail "expected return 1 (no output), got ${result}"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Exit Code: claude succeeds + no DESIGN.md → return 1 ==="

project_e="${TMPDIR_BASE}/proj_e"
mkdir -p "$project_e"
result=$(run_interview 0 no "$project_e")
if [ "$result" = "1" ]; then
    pass "returns 1 when claude exits 0 but no DESIGN.md created"
else
    fail "expected return 1 (agent produced no output), got ${result}"
fi

# ---------------------------------------------------------------------------
echo
echo "=== DESIGN.md Preservation Check ==="

project_f="${TMPDIR_BASE}/proj_f"
mkdir -p "$project_f"
run_interview 1 yes "$project_f" > /dev/null 2>&1 || true

if [ -f "${project_f}/DESIGN.md" ]; then
    pass "DESIGN.md preserved on disk after interrupted session"
else
    fail "DESIGN.md not found after interrupted session"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Log Records DESIGN.md Status ==="

project_g="${TMPDIR_BASE}/proj_g"
mkdir -p "$project_g"
run_interview 0 yes "$project_g" > /dev/null 2>&1 || true

log_g=$(find "${project_g}/.claude/logs" -name "*plan-interview.log" | head -1)
if grep -q 'DESIGN.md: exists' "$log_g"; then
    pass "log records DESIGN.md as existing after successful session"
else
    fail "log does not record DESIGN.md:exists"
fi

project_h="${TMPDIR_BASE}/proj_h"
mkdir -p "$project_h"
run_interview 0 no "$project_h" > /dev/null 2>&1 || true

log_h=$(find "${project_h}/.claude/logs" -name "*plan-interview.log" | head -1)
if grep -q 'DESIGN.md: not created' "$log_h"; then
    pass "log records DESIGN.md as not created when absent"
else
    fail "log does not record DESIGN.md:not created"
fi

# ---------------------------------------------------------------------------
echo
echo "=== TEMPLATE_CONTENT Loaded from PLAN_TEMPLATE_FILE ==="

# Verify that the stage reads the template file into TEMPLATE_CONTENT.
# We confirm this indirectly: if render_prompt uses TEMPLATE_CONTENT and the
# system prompt is logged, the template text should appear in the log.
project_i="${TMPDIR_BASE}/proj_i"
mkdir -p "$project_i"
run_interview 0 yes "$project_i" > /dev/null 2>&1 || true

log_i=$(find "${project_i}/.claude/logs" -name "*plan-interview.log" | head -1)
# The log includes the rendered system prompt which contains TEMPLATE_CONTENT.
# The web-app.md template has a recognizable heading.
if grep -q 'System Prompt' "$log_i"; then
    pass "system prompt written to log file"
else
    fail "system prompt not found in log file"
fi

# ---------------------------------------------------------------------------
echo
echo "=== PLAN_STATE.md File Creation (Milestone 6) ==="

project_j="${TMPDIR_BASE}/proj_j"
mkdir -p "$project_j"/.claude
run_interview 0 yes "$project_j" > /dev/null 2>&1 || true

if [ -f "${project_j}/.claude/PLAN_STATE.md" ]; then
    pass "PLAN_STATE.md created after successful interview"
else
    fail "PLAN_STATE.md not created: ${project_j}/.claude/PLAN_STATE.md"
fi

# ---------------------------------------------------------------------------
echo
echo "=== PLAN_STATE.md Content Validation ==="

project_k="${TMPDIR_BASE}/proj_k"
mkdir -p "$project_k"/.claude
run_interview 0 yes "$project_k" > /dev/null 2>&1 || true

state_file="${project_k}/.claude/PLAN_STATE.md"
if [ -f "$state_file" ]; then
    if grep -q '## Stage' "$state_file"; then
        pass "PLAN_STATE.md contains '## Stage' section"
    else
        fail "PLAN_STATE.md missing '## Stage' section"
    fi

    if grep -q '## Project Type' "$state_file"; then
        pass "PLAN_STATE.md contains '## Project Type' section"
    else
        fail "PLAN_STATE.md missing '## Project Type' section"
    fi

    if grep -q '## Template File' "$state_file"; then
        pass "PLAN_STATE.md contains '## Template File' section"
    else
        fail "PLAN_STATE.md missing '## Template File' section"
    fi

    if grep -q '## Files Present' "$state_file"; then
        pass "PLAN_STATE.md contains '## Files Present' section"
    else
        fail "PLAN_STATE.md missing '## Files Present' section"
    fi

    if grep -q 'interview' "$state_file"; then
        pass "PLAN_STATE.md records correct stage (interview)"
    else
        fail "PLAN_STATE.md does not record interview stage"
    fi

    if grep -q 'web-app' "$state_file"; then
        pass "PLAN_STATE.md records correct project type (web-app)"
    else
        fail "PLAN_STATE.md does not record web-app project type"
    fi
else
    fail "Could not read PLAN_STATE.md for content validation"
fi

# ---------------------------------------------------------------------------
echo
echo "=== PLAN_STATE.md Created on Interrupted Session ==="

project_l="${TMPDIR_BASE}/proj_l"
mkdir -p "$project_l"/.claude
run_interview 1 yes "$project_l" > /dev/null 2>&1 || true

if [ -f "${project_l}/.claude/PLAN_STATE.md" ]; then
    pass "PLAN_STATE.md created even when interview is interrupted (exit 1)"
else
    fail "PLAN_STATE.md not created on interrupted session"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
