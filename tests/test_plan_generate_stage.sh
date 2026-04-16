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
    TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}" \
    DESIGN_FILE="${TEKHTON_DIR:-.tekhton}/DESIGN.md" \
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
mkdir -p "${project_b}/${TEKHTON_DIR:-.tekhton}"
echo "# My Project" > "${project_b}/${TEKHTON_DIR:-.tekhton}/DESIGN.md"
echo "A test project." >> "${project_b}/${TEKHTON_DIR:-.tekhton}/DESIGN.md"
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
mkdir -p "${project_c}/${TEKHTON_DIR:-.tekhton}"
echo "# My Project" > "${project_c}/${TEKHTON_DIR:-.tekhton}/DESIGN.md"

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
mkdir -p "${project_d}/${TEKHTON_DIR:-.tekhton}"
echo "# My Project" > "${project_d}/${TEKHTON_DIR:-.tekhton}/DESIGN.md"

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
mkdir -p "${project_e}/${TEKHTON_DIR:-.tekhton}"
echo "# My Project" > "${project_e}/${TEKHTON_DIR:-.tekhton}/DESIGN.md"
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
mkdir -p "${project_f}/${TEKHTON_DIR:-.tekhton}"
echo "# Unique Marker XYZ789" > "${project_f}/${TEKHTON_DIR:-.tekhton}/DESIGN.md"
echo "Some project details." >> "${project_f}/${TEKHTON_DIR:-.tekhton}/DESIGN.md"
run_generate yes "$project_f" > /dev/null 2>&1 || true

log_f=$(find "${project_f}/.claude/logs" -name "*plan-generate.log" | head -1)
if grep -q 'Unique Marker XYZ789' "$log_f"; then
    pass "DESIGN_CONTENT variable populated from DESIGN.md and rendered into prompt"
else
    fail "DESIGN.md contents not found in log — DESIGN_CONTENT substitution may be broken"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Milestone 3: Default Max Turns = 50 ==="

# Verify PLAN_GENERATION_MAX_TURNS defaults to 50 in lib/plan.sh
gen_turns_default=$(
    unset CLAUDE_PLAN_MODEL 2>/dev/null || true
    unset PLAN_GENERATION_MAX_TURNS 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    echo "$PLAN_GENERATION_MAX_TURNS"
)

if [ "$gen_turns_default" = "50" ]; then
    pass "default PLAN_GENERATION_MAX_TURNS is 50 (Milestone 3 requirement)"
else
    fail "expected PLAN_GENERATION_MAX_TURNS='50', got '${gen_turns_default}'"
fi

# Verify PLAN_GENERATION_MODEL defaults to opus
gen_model_default=$(
    unset CLAUDE_PLAN_MODEL 2>/dev/null || true
    unset PLAN_GENERATION_MODEL 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    echo "$PLAN_GENERATION_MODEL"
)

if [ "$gen_model_default" = "opus" ]; then
    pass "default PLAN_GENERATION_MODEL is 'opus' (Milestone 1 requirement)"
else
    fail "expected PLAN_GENERATION_MODEL='opus', got '${gen_model_default}'"
fi

echo
echo "=== Generation Prompt: 12 Required Sections ==="

GEN_PROMPT="${TEKHTON_HOME}/prompts/plan_generate.prompt.md"

# The generation prompt must mandate all 12 CLAUDE.md sections
for section in "Project Identity" "Architecture Philosophy" "Repository Layout" \
               "Key Design Decisions" "Config Architecture" "Non-Negotiable Rules" \
               "Implementation Milestones" "Code Conventions" "Critical System Rules" \
               "What Not to Build Yet" "Testing Strategy" "Development Environment"; do
    if grep -q "$section" "$GEN_PROMPT"; then
        pass "generation prompt mandates '${section}' section"
    else
        fail "generation prompt missing '${section}' section"
    fi
done

# Must instruct Seeds Forward and Watch For in milestones
if grep -q 'Seeds Forward' "$GEN_PROMPT"; then
    pass "generation prompt includes 'Seeds Forward' in milestone format"
else
    fail "generation prompt missing 'Seeds Forward' block"
fi

if grep -q 'Watch For' "$GEN_PROMPT"; then
    pass "generation prompt includes 'Watch For' in milestone format"
else
    fail "generation prompt missing 'Watch For' block"
fi

# Must instruct 10-20 non-negotiable rules
if grep -q '10.*20' "$GEN_PROMPT"; then
    pass "generation prompt specifies 10-20 non-negotiable rules"
else
    fail "generation prompt does not specify 10-20 rules range"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
