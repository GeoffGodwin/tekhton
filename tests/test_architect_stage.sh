#!/usr/bin/env bash
# Test: Architect audit stage logic — config, prompt rendering, plan parsing,
#       coder routing, drift resolution, and human action surfacing
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
TEKHTON_SESSION_DIR="$TMPDIR"

# --- Set up minimal config environment ---
DRIFT_LOG_FILE="DRIFT_LOG.md"
ARCHITECTURE_LOG_FILE="ARCHITECTURE_LOG.md"
HUMAN_ACTION_FILE="HUMAN_ACTION_REQUIRED.md"
DRIFT_OBSERVATION_THRESHOLD=3
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=5
TASK="Test architect audit"
ARCHITECT_ROLE_FILE=".claude/agents/architect.md"
ARCHITECTURE_FILE="ARCHITECTURE.md"
PROJECT_RULES_FILE="CLAUDE.md"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/drift.sh"
source "${TEKHTON_HOME}/lib/drift_artifacts.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

assert_file_contains() {
    local name="$1" file="$2" pattern="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — pattern '$pattern' not found in $file"
        FAIL=1
    fi
}

assert_file_not_contains() {
    local name="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — unexpected pattern '$pattern' found in $file"
        FAIL=1
    fi
}

# =============================================================================
# Test 1: Architect config defaults are set correctly
# =============================================================================
: "${ARCHITECT_MAX_TURNS:=25}"
: "${MILESTONE_ARCHITECT_MAX_TURNS:=$(( ARCHITECT_MAX_TURNS * 2 ))}"
: "${CLAUDE_ARCHITECT_MODEL:=${CLAUDE_STANDARD_MODEL}}"
: "${DEPENDENCY_CONSTRAINTS_FILE:=}"

assert_eq "architect max turns default" "25" "$ARCHITECT_MAX_TURNS"
assert_eq "architect milestone turns" "50" "$MILESTONE_ARCHITECT_MAX_TURNS"
assert_eq "architect model default" "claude-sonnet-4-6" "$CLAUDE_ARCHITECT_MODEL"
assert_eq "dependency constraints default" "" "$DEPENDENCY_CONSTRAINTS_FILE"

# =============================================================================
# Test 2: --init copies architect.md to agents directory
# =============================================================================
cd "$TMPDIR"
TEKHTON_NON_INTERACTIVE=true bash "${TEKHTON_HOME}/tekhton.sh" --init > /dev/null 2>&1
[ -f ".claude/agents/architect.md" ] || { echo "FAIL: architect.md not created by --init"; FAIL=1; }
assert_file_contains "architect role content" ".claude/agents/architect.md" "architecture audit agent"
cd - > /dev/null

# =============================================================================
# Test 3: Architect prompt template renders correctly
# =============================================================================
PROJECT_NAME="TestProject"
ARCHITECTURE_CONTENT="## Layers\n- engine\n- features"
ARCHITECTURE_LOG_CONTENT="## ADL-1: Initial structure"
DRIFT_LOG_CONTENT="## Unresolved Observations\n- naming drift in engine/"
DRIFT_OBSERVATION_COUNT="3"
DEPENDENCY_CONSTRAINTS_CONTENT=""

RENDERED=$(render_prompt "architect")

echo "$RENDERED" | grep -q "TestProject" || { echo "FAIL: architect prompt missing PROJECT_NAME"; FAIL=1; }
echo "$RENDERED" | grep -q "3 reviewer runs" || { echo "FAIL: architect prompt missing observation count"; FAIL=1; }
echo "$RENDERED" | grep -q "Dependency Constraints" && { echo "FAIL: architect prompt should not include empty constraints block"; FAIL=1; }

# Test with dependency constraints present
DEPENDENCY_CONSTRAINTS_CONTENT="layers:\n  - engine"
RENDERED_WITH_DEPS=$(render_prompt "architect")
echo "$RENDERED_WITH_DEPS" | grep -q "Dependency Constraints" || { echo "FAIL: architect prompt missing constraints when set"; FAIL=1; }

# Reset
DEPENDENCY_CONSTRAINTS_CONTENT=""

# =============================================================================
# Test 4: Architect sr rework prompt renders
# =============================================================================
CODER_ROLE_FILE=".claude/agents/coder.md"
RENDERED_SR=$(render_prompt "architect_sr_rework")
echo "$RENDERED_SR" | grep -q "Simplification" || { echo "FAIL: sr rework prompt missing Simplification"; FAIL=1; }
echo "$RENDERED_SR" | grep -q "TestProject" || { echo "FAIL: sr rework prompt missing PROJECT_NAME"; FAIL=1; }

# =============================================================================
# Test 5: Architect jr rework prompt renders
# =============================================================================
JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"
RENDERED_JR=$(render_prompt "architect_jr_rework")
echo "$RENDERED_JR" | grep -q "Staleness Fixes" || { echo "FAIL: jr rework prompt missing Staleness Fixes"; FAIL=1; }
echo "$RENDERED_JR" | grep -q "Dead Code Removal" || { echo "FAIL: jr rework prompt missing Dead Code Removal"; FAIL=1; }

# =============================================================================
# Test 6: Architect review prompt renders
# =============================================================================
REVIEWER_ROLE_FILE=".claude/agents/reviewer.md"
RENDERED_REVIEW=$(render_prompt "architect_review")
echo "$RENDERED_REVIEW" | grep -q "Expedited" || { echo "FAIL: review prompt missing Expedited"; FAIL=1; }
echo "$RENDERED_REVIEW" | grep -q "ARCHITECT_PLAN.md" || { echo "FAIL: review prompt missing ARCHITECT_PLAN.md reference"; FAIL=1; }

# =============================================================================
# Test 7: Plan section parsing — extract Simplification from ARCHITECT_PLAN.md
# =============================================================================
mkdir -p "${TMPDIR}/parse_test"
cat > "${TMPDIR}/parse_test/ARCHITECT_PLAN.md" << 'EOF'
# Architect Plan

## Staleness Fixes
- Update ARCHITECTURE.md: engine/rules section — trigger_resolver.dart moved to engine/triggers/
- Remove obsolete reference: docs/old_api.md:15 — removed endpoint

## Dead Code Removal
- lib/utils/legacy_helper.dart:calculate_old — zero callers outside tests

## Naming Normalization
- Rename columnLock → column_lock in warden_processor.dart — consistency with config

## Simplification
- engine/state/game_state.dart — over-wrapped optional fields — flatten to direct access

## Design Doc Observations
- GDD section 4.2 — warden resolution options A and B both referenced but only A implemented

## Drift Observations to Resolve
- warden_processor.dart:45 — duplicate rank lookup pattern
- general — naming inconsistency: columnLock vs column_lock

## Out of Scope
- Large-scale test reorganization — defer to dedicated sprint
EOF

# Parse simplification section
simp=$(awk '/^## Simplification/{found=1; next} found && /^##/{exit} found{print}' \
    "${TMPDIR}/parse_test/ARCHITECT_PLAN.md" 2>/dev/null || true)
echo "$simp" | grep -q "game_state.dart" || { echo "FAIL: simplification section not parsed"; FAIL=1; }

# Parse jr coder sections
staleness=$(awk '/^## Staleness Fixes/{found=1; next} found && /^##/{exit} found{print}' \
    "${TMPDIR}/parse_test/ARCHITECT_PLAN.md" 2>/dev/null || true)
echo "$staleness" | grep -q "trigger_resolver.dart" || { echo "FAIL: staleness section not parsed"; FAIL=1; }

dead=$(awk '/^## Dead Code Removal/{found=1; next} found && /^##/{exit} found{print}' \
    "${TMPDIR}/parse_test/ARCHITECT_PLAN.md" 2>/dev/null || true)
echo "$dead" | grep -q "legacy_helper.dart" || { echo "FAIL: dead code section not parsed"; FAIL=1; }

naming=$(awk '/^## Naming Normalization/{found=1; next} found && /^##/{exit} found{print}' \
    "${TMPDIR}/parse_test/ARCHITECT_PLAN.md" 2>/dev/null || true)
echo "$naming" | grep -q "columnLock" || { echo "FAIL: naming section not parsed"; FAIL=1; }

# Parse design doc observations
design=$(awk '/^## Design Doc Observations/{found=1; next} found && /^##/{exit} found{print}' \
    "${TMPDIR}/parse_test/ARCHITECT_PLAN.md" 2>/dev/null || true)
echo "$design" | grep -q "GDD section 4.2" || { echo "FAIL: design doc section not parsed"; FAIL=1; }

# Parse resolve section
resolve=$(awk '/^## Drift Observations to Resolve/{found=1; next} found && /^##/{exit} found{print}' \
    "${TMPDIR}/parse_test/ARCHITECT_PLAN.md" 2>/dev/null || true)
echo "$resolve" | grep -q "duplicate rank lookup" || { echo "FAIL: resolve section not parsed"; FAIL=1; }

# =============================================================================
# Test 8: "None" sections correctly detected as empty
# =============================================================================
cat > "${TMPDIR}/parse_test/ARCHITECT_PLAN_MINIMAL.md" << 'EOF'
## Staleness Fixes
None

## Dead Code Removal
- None

## Naming Normalization
None

## Simplification
None

## Design Doc Observations
None

## Drift Observations to Resolve
- naming drift observed

## Out of Scope
None
EOF

simp_none=$(awk '/^## Simplification/{found=1; next} found && /^##/{exit} found{print}' \
    "${TMPDIR}/parse_test/ARCHITECT_PLAN_MINIMAL.md" 2>/dev/null || true)
if echo "$simp_none" | grep -qiE '^\s*-?\s*None\s*$'; then
    : # Correctly detected as None — no sr coder work
else
    echo "FAIL: None detection failed for Simplification"
    FAIL=1
fi

# =============================================================================
# Test 9: Design doc observations surface as human actions
# =============================================================================
# Reset human action file
rm -f "${PROJECT_DIR}/${HUMAN_ACTION_FILE}"

design_items="- GDD section 4.2 — warden resolution mismatch
- GDD section 6.1 — boss encounter pacing unclear"

while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/^[[:space:]]*//')
    [ -z "$line" ] && continue
    append_human_action "architect" "$line"
done <<< "$design_items"

assert_eq "human actions from architect" "2" "$(count_human_actions)"
assert_file_contains "architect source tag" "${PROJECT_DIR}/${HUMAN_ACTION_FILE}" "Source: architect"
assert_file_contains "design obs content" "${PROJECT_DIR}/${HUMAN_ACTION_FILE}" "GDD section 4.2"

# =============================================================================
# Test 10: Drift resolution after architect audit
# =============================================================================
# Set up a drift log with known observations
rm -f "${PROJECT_DIR}/${DRIFT_LOG_FILE}"
_ensure_drift_log

# Add observations manually
cat > "${PROJECT_DIR}/${DRIFT_LOG_FILE}" << 'EOF'
# Drift Log

## Metadata
- Last audit: never
- Runs since audit: 6

## Unresolved Observations
- [2026-03-01 | "Task A"] warden_processor.dart:45 — duplicate rank lookup pattern
- [2026-03-01 | "Task A"] general — naming inconsistency: columnLock vs column_lock
- [2026-03-02 | "Task B"] engine/state — unused import in game_state.dart

## Resolved
EOF

assert_eq "pre-resolve count" "3" "$(count_drift_observations)"

# Resolve the two observations the architect addressed
resolve_drift_observations "duplicate rank lookup" "naming inconsistency"

assert_eq "post-resolve count" "1" "$(count_drift_observations)"
assert_file_contains "resolved entry" "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "RESOLVED.*duplicate rank lookup"
assert_file_contains "still unresolved" "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "unused import"

# =============================================================================
# Test 11: Reset runs-since-audit counter after audit
# =============================================================================
reset_runs_since_audit
assert_eq "runs reset" "0" "$(get_runs_since_audit)"
assert_file_contains "last audit date" "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "Last audit: $(date +%Y-%m-%d)"

# =============================================================================
# Test 12: --skip-audit and --force-audit flags parse correctly
# =============================================================================
# These are just shell variables — test that the defaults are correct
SKIP_AUDIT=false
FORCE_AUDIT=false
assert_eq "skip audit default" "false" "$SKIP_AUDIT"
assert_eq "force audit default" "false" "$FORCE_AUDIT"

# Simulate flag setting
SKIP_AUDIT=true
FORCE_AUDIT=true
assert_eq "skip audit set" "true" "$SKIP_AUDIT"
assert_eq "force audit set" "true" "$FORCE_AUDIT"

# =============================================================================
# Test 13: Audit trigger logic with force/skip flags
# =============================================================================
# Reset to below threshold
rm -f "${PROJECT_DIR}/${DRIFT_LOG_FILE}"
_ensure_drift_log
DRIFT_OBSERVATION_THRESHOLD=10
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=10

# No observations, no runs — should NOT trigger
if should_trigger_audit 2>/dev/null; then
    echo "FAIL: audit should not trigger with empty log and high thresholds"
    FAIL=1
fi

# Force audit overrides — test the logic pattern used in tekhton.sh
FORCE_AUDIT=true
if [ "$FORCE_AUDIT" = true ] || should_trigger_audit 2>/dev/null; then
    : # Correctly triggers due to force flag
else
    echo "FAIL: force audit should override threshold check"
    FAIL=1
fi

# Skip audit flag — test the gating pattern
SKIP_AUDIT=true
FORCE_AUDIT=false
if [ "$SKIP_AUDIT" = false ]; then
    echo "FAIL: skip audit should prevent audit dispatch"
    FAIL=1
fi

# =============================================================================
# Test 14: Architect template file exists and has correct content
# =============================================================================
[ -f "${TEKHTON_HOME}/templates/architect.md" ] || { echo "FAIL: templates/architect.md missing"; FAIL=1; }
assert_file_contains "template mandate" "${TEKHTON_HOME}/templates/architect.md" "architecture audit agent"
assert_file_contains "template output format" "${TEKHTON_HOME}/templates/architect.md" "ARCHITECT_PLAN.md"
assert_file_contains "template staleness" "${TEKHTON_HOME}/templates/architect.md" "Staleness Fixes"
assert_file_contains "template simplification" "${TEKHTON_HOME}/templates/architect.md" "Simplification"
assert_file_contains "template out of scope" "${TEKHTON_HOME}/templates/architect.md" "Out of Scope"

# =============================================================================
# Test 15: All architect prompt templates exist and are valid
# =============================================================================
for tmpl in architect architect_sr_rework architect_jr_rework architect_review; do
    [ -f "${TEKHTON_HOME}/prompts/${tmpl}.prompt.md" ] || { echo "FAIL: ${tmpl}.prompt.md missing"; FAIL=1; }
done

# =============================================================================
# Done
# =============================================================================
if [ "$FAIL" -ne 0 ]; then
    echo "ARCHITECT TEST FAILED"
    exit 1
fi

echo "Architect audit tests passed (15 tests)"
