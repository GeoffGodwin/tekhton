#!/usr/bin/env bash
# Test: Milestone DAG migration — inline extraction, manifest generation,
# CLAUDE.md cleanup, re-migration idempotency, plan_generate post-processing
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Provide stubs for config values
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
TEST_CMD=""
ANALYZE_CMD=""
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}"

MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_DAG_ENABLED=true
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
MILESTONE_AUTO_MIGRATE=true
MILESTONE_ARCHIVE_FILE="${TMPDIR}/MILESTONE_ARCHIVE.md"

export MILESTONE_DAG_ENABLED MILESTONE_DIR MILESTONE_MANIFEST

source "${TEKHTON_HOME}/lib/state.sh"

# Stub run_build_gate
run_build_gate() { return 0; }

source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_migrate.sh"
source "${TEKHTON_HOME}/lib/milestone_archival_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"
source "${TEKHTON_HOME}/lib/milestone_ops.sh"

cd "$TMPDIR"

PASS=0
FAIL=0

assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# =============================================================================
echo "--- Test: Migration from complex CLAUDE.md ---"

MILESTONE_DIR_ABS="${TMPDIR}/.claude/milestones"

cat > "${TMPDIR}/CLAUDE.md" << 'CLAUDE_EOF'
# Project Rules

## Current Initiative: Complex Test

### Key Constraints
- Some constraint here

### Milestone Plan

#### Milestone 1: First Feature
Implement the first feature with careful attention to detail.

Files to create:
- lib/first.sh

Acceptance criteria:
- Feature works correctly
- Tests pass
- shellcheck clean

Watch For:
- Edge cases in parsing

Seeds Forward:
- Second feature depends on the data model here

#### [DONE] Milestone 2: Second Feature
Implement the second feature.

Acceptance criteria:
- Second feature works
- All tests pass

#### Milestone 3: Third Feature
Depends on Milestone 1.
Also depends on Milestone 2.

Implement the third feature.

Acceptance criteria:
- Third feature works

#### Milestone 4: Fourth Feature
Depends on Milestone 3.

Final feature.

Acceptance criteria:
- Fourth feature works

## Code Conventions
Some code conventions here.
CLAUDE_EOF

result=0
migrate_inline_milestones "${TMPDIR}/CLAUDE.md" "${MILESTONE_DIR_ABS}" && result=0 || result=1
assert "migration of complex CLAUDE.md succeeds" "$result"

result=0
[[ -f "${MILESTONE_DIR_ABS}/MANIFEST.cfg" ]] && result=0 || result=1
assert "MANIFEST.cfg created" "$result"

# Load and verify
load_manifest "${MILESTONE_DIR_ABS}/MANIFEST.cfg"

result=0
count=$(dag_get_count)
[[ "$count" -eq 4 ]] && result=0 || result=1
assert "4 milestones extracted (got: $count)" "$result"

# Verify done status preserved
result=0
status=$(dag_get_status "m02")
[[ "$status" == "done" ]] && result=0 || result=1
assert "m02 status is done (was [DONE] inline)" "$result"

# Verify multi-dependency detection (m03 depends on m01 AND m02)
result=0
deps="${_DAG_DEPS[${_DAG_IDX[m03]}]}"
[[ "$deps" == *"m01"* ]] && [[ "$deps" == *"m02"* ]] && result=0 || result=1
assert "m03 has both deps (m01 and m02, got: '$deps')" "$result"

# Verify milestone file content includes Watch For / Seeds Forward
result=0
file=$(dag_get_file "m01")
grep -q "Seeds Forward" "${MILESTONE_DIR_ABS}/${file}" && result=0 || result=1
assert "m01 file includes Seeds Forward content" "$result"

# =============================================================================
echo "--- Test: Re-migration is idempotent ---"

result=0
migrate_inline_milestones "${TMPDIR}/CLAUDE.md" "${MILESTONE_DIR_ABS}" && result=0 || result=1
assert "re-migration returns 0 (idempotent)" "$result"

# Count should still be the same
load_manifest "${MILESTONE_DIR_ABS}/MANIFEST.cfg"
result=0
count=$(dag_get_count)
[[ "$count" -eq 4 ]] && result=0 || result=1
assert "count unchanged after re-migration (got: $count)" "$result"

# =============================================================================
echo "--- Test: Migration with no milestones ---"

# Clean up for next test
rm -rf "${MILESTONE_DIR_ABS}"
mkdir -p "${MILESTONE_DIR_ABS}"

cat > "${TMPDIR}/empty.md" << 'EOF'
# Project Rules
No milestones here.
EOF

result=0
migrate_inline_milestones "${TMPDIR}/empty.md" "${MILESTONE_DIR_ABS}" && result=1 || result=0
assert "migration fails gracefully with no milestones" "$result"

# =============================================================================
echo "--- Test: Migration with missing CLAUDE.md ---"

result=0
migrate_inline_milestones "${TMPDIR}/nonexistent.md" "${MILESTONE_DIR_ABS}" && result=1 || result=0
assert "migration fails gracefully with missing file" "$result"

# =============================================================================
echo "--- Test: _insert_milestone_pointer (plan_generate post-processing) ---"

# _insert_milestone_pointer is already available from milestone_dag_migrate.sh
# (sourced at top of file), but plan_generate.sh is sourced here for
# completeness as it also provides the helper in production code paths.
source "${TEKHTON_HOME}/stages/plan_generate.sh"

# Create a fresh CLAUDE.md with milestones
cat > "${TMPDIR}/pointer_test.md" << 'CLAUDE_EOF'
# Project Rules

## Architecture
Some architecture content.

### Milestone Plan

#### Milestone 1: First
First milestone content.

Acceptance criteria:
- Works

#### Milestone 2: Second
Second milestone content.

## Code Conventions
Some conventions.
CLAUDE_EOF

_insert_milestone_pointer "${TMPDIR}/pointer_test.md" "${MILESTONE_DIR_ABS}"

# Check pointer was inserted
result=0
grep -q "Milestones are managed as individual files" "${TMPDIR}/pointer_test.md" && result=0 || result=1
assert "pointer comment inserted in CLAUDE.md" "$result"

# Check milestone content was removed
result=0
grep -q "First milestone content" "${TMPDIR}/pointer_test.md" && result=1 || result=0
assert "milestone content removed from CLAUDE.md" "$result"

# Check non-milestone content preserved
result=0
grep -q "Some architecture content" "${TMPDIR}/pointer_test.md" && result=0 || result=1
assert "architecture content preserved" "$result"

result=0
grep -q "Code Conventions" "${TMPDIR}/pointer_test.md" && result=0 || result=1
assert "code conventions section preserved" "$result"

# =============================================================================
echo "--- Test: _insert_milestone_pointer is idempotent ---"

_insert_milestone_pointer "${TMPDIR}/pointer_test.md" "${MILESTONE_DIR_ABS}"

result=0
count=$(grep -c "Milestones are managed" "${TMPDIR}/pointer_test.md")
[[ "$count" -eq 1 ]] && result=0 || result=1
assert "pointer not duplicated on re-run (count: $count)" "$result"

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
