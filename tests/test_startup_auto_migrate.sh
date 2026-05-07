#!/usr/bin/env bash
# Test: Startup auto-migration path — regression test for tekhton.sh lines 864–884
# Exercises the MILESTONE_DAG_ENABLED + MILESTONE_AUTO_MIGRATE startup block that
# converts inline CLAUDE.md milestones to DAG files at pipeline startup.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export TEKHTON_HOME
export PROJECT_DIR="$TMPDIR"

source "${TEKHTON_HOME}/lib/common.sh"

# Config stubs
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
TEST_CMD=""
ANALYZE_CMD=""
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}"

MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_MANIFEST="MANIFEST.cfg"
MILESTONE_ARCHIVE_FILE="${TMPDIR}/MILESTONE_ARCHIVE.md"
export MILESTONE_MANIFEST

source "${TEKHTON_HOME}/lib/state.sh"

run_build_gate() { return 0; }

source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_query.sh"
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

# ─── Shared fixture ──────────────────────────────────────────────────────────

SAMPLE_CLAUDE_MD_CONTENT='# Project Rules

## Key Constraints
- Keep it simple

### Milestone Plan

#### Milestone 1: Alpha Feature
Implement the alpha feature.

Acceptance criteria:
- Works correctly
- Tests pass

#### Milestone 2: Beta Feature
Depends on Milestone 1.

Implement the beta feature.

Acceptance criteria:
- Beta works

## Code Conventions
Follow existing patterns.
'

# run_startup_migrate_block: replicates tekhton.sh lines 864–884 exactly,
# so we can test the startup path in isolation with varying env vars.
run_startup_migrate_block() {
    local claude_md="${1:-CLAUDE.md}"
    local dag_enabled="${2:-true}"
    local auto_migrate="${3:-true}"

    MILESTONE_DAG_ENABLED="$dag_enabled"
    MILESTONE_AUTO_MIGRATE="$auto_migrate"
    export MILESTONE_DAG_ENABLED MILESTONE_AUTO_MIGRATE

    # Replicate tekhton.sh lines 864–884 verbatim (MILESTONE_MODE=true + CLAUDE.md exists)
    local MILESTONE_MODE=true
    if [ "$MILESTONE_MODE" = true ] && [ -f "$claude_md" ]; then
        if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
           && [[ "${MILESTONE_AUTO_MIGRATE:-true}" == "true" ]] \
           && ! has_milestone_manifest; then
            if parse_milestones "$claude_md" >/dev/null 2>&1; then
                log "Auto-migrating inline milestones to DAG file format..."
                local milestone_dir
                milestone_dir="$(_dag_milestone_dir)"
                if migrate_inline_milestones "$claude_md" "$milestone_dir"; then
                    _insert_milestone_pointer "$claude_md" "$milestone_dir"
                else
                    warn "Milestone migration failed — continuing with inline mode"
                fi
            fi
        fi

        # Load manifest if it exists (either from migration or pre-existing)
        if has_milestone_manifest; then
            load_manifest "$(_dag_manifest_path)" || warn "Failed to load milestone manifest"
        fi
    fi
}

# =============================================================================
echo "--- Test: Happy path — startup migrates inline milestones ---"

TESTDIR="${TMPDIR}/test_happy"
mkdir -p "${TESTDIR}/.claude"
MILESTONE_DIR="${TESTDIR}/.claude/milestones"
export MILESTONE_DIR

echo "$SAMPLE_CLAUDE_MD_CONTENT" > "${TESTDIR}/CLAUDE.md"
cd "$TESTDIR"

# Reset DAG state
_DAG_IDS=()
_DAG_TITLES=()
_DAG_STATUSES=()
_DAG_DEPS=()
_DAG_FILES=()
_DAG_GROUPS=()
_DAG_IDX=()
_DAG_LOADED=false

run_startup_migrate_block "CLAUDE.md" "true" "true"

result=0
[[ -f "${MILESTONE_DIR}/MANIFEST.cfg" ]] && result=0 || result=1
assert "manifest created by startup auto-migration" "$result"

result=0
count=$(dag_get_count)
[[ "$count" -eq 2 ]] && result=0 || result=1
assert "2 milestones loaded into DAG after migration (got: $count)" "$result"

result=0
grep -q "Milestones are managed as individual files" "CLAUDE.md" && result=0 || result=1
assert "pointer comment inserted into CLAUDE.md" "$result"

result=0
grep -q "Alpha Feature" "CLAUDE.md" && result=1 || result=0
assert "milestone content removed from CLAUDE.md" "$result"

result=0
grep -q "Code Conventions" "CLAUDE.md" && result=0 || result=1
assert "non-milestone content preserved in CLAUDE.md" "$result"

# =============================================================================
echo "--- Test: Idempotency — second startup run does not re-migrate ---"

# Run the startup block again — manifest already exists
old_count_files=$(find "${MILESTONE_DIR}" -name "*.md" | wc -l)

_DAG_IDS=(); _DAG_TITLES=(); _DAG_STATUSES=(); _DAG_DEPS=(); _DAG_FILES=(); _DAG_GROUPS=(); _DAG_IDX=(); _DAG_LOADED=false

run_startup_migrate_block "CLAUDE.md" "true" "true"

result=0
new_count=$(find "${MILESTONE_DIR}" -name "*.md" | wc -l)
[[ "$new_count" -eq "$old_count_files" ]] && result=0 || result=1
assert "no new milestone files created on second run (was: $old_count_files, now: $new_count)" "$result"

result=0
pointer_count=$(grep -c "Milestones are managed" "CLAUDE.md")
[[ "$pointer_count" -eq 1 ]] && result=0 || result=1
assert "pointer comment not duplicated on second run (count: $pointer_count)" "$result"

result=0
count=$(dag_get_count)
[[ "$count" -eq 2 ]] && result=0 || result=1
assert "DAG still has 2 milestones after idempotent re-run (got: $count)" "$result"

cd "$TMPDIR"

# =============================================================================
echo "--- Test: MILESTONE_DAG_ENABLED=false — migration skipped ---"

TESTDIR2="${TMPDIR}/test_dag_disabled"
mkdir -p "${TESTDIR2}/.claude"
MILESTONE_DIR="${TESTDIR2}/.claude/milestones"
export MILESTONE_DIR

echo "$SAMPLE_CLAUDE_MD_CONTENT" > "${TESTDIR2}/CLAUDE.md"
cd "$TESTDIR2"

_DAG_IDS=(); _DAG_TITLES=(); _DAG_STATUSES=(); _DAG_DEPS=(); _DAG_FILES=(); _DAG_GROUPS=(); _DAG_IDX=(); _DAG_LOADED=false

run_startup_migrate_block "CLAUDE.md" "false" "true"

result=0
[[ ! -f "${MILESTONE_DIR}/MANIFEST.cfg" ]] && result=0 || result=1
assert "no manifest created when MILESTONE_DAG_ENABLED=false" "$result"

result=0
grep -q "Alpha Feature" "CLAUDE.md" && result=0 || result=1
assert "inline milestone content untouched when DAG disabled" "$result"

cd "$TMPDIR"

# =============================================================================
echo "--- Test: MILESTONE_AUTO_MIGRATE=false — migration skipped ---"

TESTDIR3="${TMPDIR}/test_auto_migrate_off"
mkdir -p "${TESTDIR3}/.claude"
MILESTONE_DIR="${TESTDIR3}/.claude/milestones"
export MILESTONE_DIR

echo "$SAMPLE_CLAUDE_MD_CONTENT" > "${TESTDIR3}/CLAUDE.md"
cd "$TESTDIR3"

_DAG_IDS=(); _DAG_TITLES=(); _DAG_STATUSES=(); _DAG_DEPS=(); _DAG_FILES=(); _DAG_GROUPS=(); _DAG_IDX=(); _DAG_LOADED=false

run_startup_migrate_block "CLAUDE.md" "true" "false"

result=0
[[ ! -f "${MILESTONE_DIR}/MANIFEST.cfg" ]] && result=0 || result=1
assert "no manifest created when MILESTONE_AUTO_MIGRATE=false" "$result"

result=0
grep -q "Alpha Feature" "CLAUDE.md" && result=0 || result=1
assert "inline content untouched when auto-migrate disabled" "$result"

cd "$TMPDIR"

# =============================================================================
echo "--- Test: No inline milestones — migration not attempted ---"

TESTDIR4="${TMPDIR}/test_no_milestones"
mkdir -p "${TESTDIR4}/.claude"
MILESTONE_DIR="${TESTDIR4}/.claude/milestones"
export MILESTONE_DIR

cat > "${TESTDIR4}/CLAUDE.md" << 'EOF'
# Project Rules

No milestones defined yet.

## Code Conventions
Follow existing patterns.
EOF

cd "$TESTDIR4"

_DAG_IDS=(); _DAG_TITLES=(); _DAG_STATUSES=(); _DAG_DEPS=(); _DAG_FILES=(); _DAG_GROUPS=(); _DAG_IDX=(); _DAG_LOADED=false

run_startup_migrate_block "CLAUDE.md" "true" "true"

result=0
[[ ! -f "${MILESTONE_DIR}/MANIFEST.cfg" ]] && result=0 || result=1
assert "no manifest created when CLAUDE.md has no milestones" "$result"

cd "$TMPDIR"

# =============================================================================
echo "--- Test: Pre-existing manifest — skip migration, load manifest ---"

TESTDIR5="${TMPDIR}/test_preexisting"
mkdir -p "${TESTDIR5}/.claude/milestones"
MILESTONE_DIR="${TESTDIR5}/.claude/milestones"
export MILESTONE_DIR

# Write a pre-existing manifest and milestone file
cat > "${TESTDIR5}/.claude/milestones/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Pre-existing Feature|pending||m01-pre-existing-feature.md|
EOF

cat > "${TESTDIR5}/.claude/milestones/m01-pre-existing-feature.md" << 'EOF'
#### Milestone 1: Pre-existing Feature
Pre-existing milestone content.

Acceptance criteria:
- Works
EOF

# CLAUDE.md with a pointer comment (already migrated)
cat > "${TESTDIR5}/CLAUDE.md" << 'EOF'
# Project Rules

<!-- Milestones are managed as individual files in .claude/milestones/.
     See MANIFEST.cfg for ordering and dependencies. -->

## Code Conventions
Follow existing patterns.
EOF

cd "$TESTDIR5"

_DAG_IDS=(); _DAG_TITLES=(); _DAG_STATUSES=(); _DAG_DEPS=(); _DAG_FILES=(); _DAG_GROUPS=(); _DAG_IDX=(); _DAG_LOADED=false

run_startup_migrate_block "CLAUDE.md" "true" "true"

result=0
count=$(dag_get_count)
[[ "$count" -eq 1 ]] && result=0 || result=1
assert "pre-existing manifest loaded (1 milestone, got: $count)" "$result"

result=0
title=$(dag_get_title "m01" 2>/dev/null || echo "")
[[ "$title" == "Pre-existing Feature" ]] && result=0 || result=1
assert "pre-existing milestone title loaded correctly (got: '$title')" "$result"

cd "$TMPDIR"

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
