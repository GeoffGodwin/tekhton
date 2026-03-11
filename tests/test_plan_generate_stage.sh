#!/usr/bin/env bash
# Test: stages/plan_generate.sh — log creation, exit codes, DESIGN.md handling
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Helper: run run_plan_generate() in an isolated subprocess.
#
# Arguments:
#   $1  create_claude — "yes" to have mock agent create CLAUDE.md, "no" otherwise
#   $2  project_dir   — temp directory to use as PROJECT_DIR
#
# Prints "0" or "1" (the function's exit code) to stdout.
# ---------------------------------------------------------------------------
run_generate() {
    local create_claude="$1"
    local project_dir="$2"

    local script_file
    script_file=$(mktemp "${TMPDIR_BASE}/run_gen_XXXXXX.sh")

    # Single-quoted heredoc: no variable expansion here — values passed via env
    cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash
# No set -euo pipefail — we need to capture non-zero exit codes

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

# Mock _call_planning_batch — no real claude invocation needed.
# Prints CLAUDE.md content to stdout when CREATE_CLAUDE=yes.
_call_planning_batch() {
    if [ "${CREATE_CLAUDE}" = "yes" ]; then
        printf '# Project CLAUDE.md\n\nGenerated content.\n'
    fi
    return 0
}

source "${TEKHTON_HOME}/stages/plan_generate.sh"

run_plan_generate > /dev/null 2>&1 && echo 0 || echo 1
INNERSCRIPT

    TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$project_dir" \
    PLAN_GENERATION_MODEL="test-model" \
    PLAN_GENERATION_MAX_TURNS="5" \
    PROJECT_NAME="test-project" \
    CREATE_CLAUDE="$create_claude" \
    bash "$script_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
echo "=== Missing DESIGN.md → returns 1 ==="

project_a="${TMPDIR_BASE}/proj_a"
mkdir -p "$project_a"
# No DESIGN.md created

result=$(run_generate no "$project_a")
if [ "$result" = "1" ]; then
    pass "returns 1 when DESIGN.md does not exist"
else
    fail "expected return 1 (no DESIGN.md), got ${result}"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Log Directory and File Creation ==="

project_b="${TMPDIR_BASE}/proj_b"
mkdir -p "$project_b"
echo "# My Project" > "${project_b}/DESIGN.md"
echo "A test project." >> "${project_b}/DESIGN.md"
rm -rf "${project_b}/.claude"

run_generate yes "$project_b" > /dev/null 2>&1 || true

if [ -d "${project_b}/.claude/logs" ]; then
    pass "log directory created by run_plan_generate()"
else
    fail "log directory not created: ${project_b}/.claude/logs"
fi

log_count=$(find "${project_b}/.claude/logs" -name "*plan-generate.log" | wc -l)
if [ "$log_count" -ge 1 ]; then
    pass "log file created with *plan-generate.log naming"
else
    fail "no *plan-generate.log file found in ${project_b}/.claude/logs"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Log File Metadata Content ==="

log_file=$(find "${project_b}/.claude/logs" -name "*plan-generate.log" | head -1)

if grep -q 'Tekhton Plan Generation' "$log_file"; then
    pass "log contains 'Tekhton Plan Generation' header"
else
    fail "log missing 'Tekhton Plan Generation' header"
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

if grep -q 'Design file:' "$log_file"; then
    pass "log contains 'Design file:' metadata"
else
    fail "log missing 'Design file:' metadata"
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

if grep -q 'Exit code:' "$log_file"; then
    pass "log contains 'Exit code:' after session"
else
    fail "log missing 'Exit code:' after session"
fi

if grep -q 'Turns used:' "$log_file"; then
    pass "log contains 'Turns used:' after session"
else
    fail "log missing 'Turns used:' after session"
fi

# ---------------------------------------------------------------------------
echo
echo "=== System Prompt Written to Log ==="

if grep -q 'System Prompt' "$log_file"; then
    pass "system prompt section written to log"
else
    fail "system prompt section not found in log"
fi

# The rendered prompt should contain DESIGN.md content
if grep -q 'My Project' "$log_file"; then
    pass "DESIGN.md content present in log (via DESIGN_CONTENT substitution)"
else
    fail "DESIGN.md content not found in log — DESIGN_CONTENT may not be set"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Exit Code: DESIGN.md present + CLAUDE.md created → return 0 ==="

project_c="${TMPDIR_BASE}/proj_c"
mkdir -p "$project_c"
echo "# My Project" > "${project_c}/DESIGN.md"

result=$(run_generate yes "$project_c")
if [ "$result" = "0" ]; then
    pass "returns 0 when DESIGN.md exists and CLAUDE.md is created"
else
    fail "expected return 0, got ${result}"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Exit Code: DESIGN.md present + CLAUDE.md not created → return 1 ==="

project_d="${TMPDIR_BASE}/proj_d"
mkdir -p "$project_d"
echo "# My Project" > "${project_d}/DESIGN.md"

result=$(run_generate no "$project_d")
if [ "$result" = "1" ]; then
    pass "returns 1 when DESIGN.md exists but CLAUDE.md is not created"
else
    fail "expected return 1, got ${result}"
fi

# ---------------------------------------------------------------------------
echo
echo "=== CLAUDE.md Exists on Disk After Success ==="

project_e="${TMPDIR_BASE}/proj_e"
mkdir -p "$project_e"
echo "# My Project" > "${project_e}/DESIGN.md"
run_generate yes "$project_e" > /dev/null 2>&1 || true

if [ -f "${project_e}/CLAUDE.md" ]; then
    pass "CLAUDE.md present on disk after successful generation"
else
    fail "CLAUDE.md not found after successful generation"
fi

# ---------------------------------------------------------------------------
echo
echo "=== DESIGN_CONTENT Loaded from DESIGN.md ==="

project_f="${TMPDIR_BASE}/proj_f"
mkdir -p "$project_f"
echo "# Unique Marker XYZ789" > "${project_f}/DESIGN.md"
echo "Some project details." >> "${project_f}/DESIGN.md"
run_generate yes "$project_f" > /dev/null 2>&1 || true

log_f=$(find "${project_f}/.claude/logs" -name "*plan-generate.log" | head -1)
if grep -q 'Unique Marker XYZ789' "$log_f"; then
    pass "DESIGN_CONTENT variable populated from DESIGN.md and rendered into prompt"
else
    fail "DESIGN.md contents not found in log — DESIGN_CONTENT substitution may be broken"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
