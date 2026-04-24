#!/usr/bin/env bash
# =============================================================================
# test_draft_milestones_validate_lint.sh — Authoring-time lint integration
#
# Verifies that draft_milestones_validate_output emits acceptance-criteria
# quality warnings during authoring (non-blocking). Lint was moved here from
# end-of-run milestone acceptance so warnings are actionable before a run.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

# Minimal stubs for common.sh surface used by sourced files.
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

export PROJECT_DIR="$TEST_TMPDIR"
export MILESTONE_DIR=".claude/milestones"
export MILESTONE_MANIFEST="MANIFEST.cfg"

# shellcheck source=lib/milestone_acceptance_lint.sh
source "${TEKHTON_HOME}/lib/milestone_acceptance_lint.sh"
# shellcheck source=lib/draft_milestones_write.sh
source "${TEKHTON_HOME}/lib/draft_milestones_write.sh"

# --- Fixture: structurally valid refactor milestone with only structural criteria
cat > "$TEST_TMPDIR/lint_refactor.md" << 'EOF'
# Milestone 99: Refactor Old Thing

<!-- milestone-meta
id: "99"
status: "pending"
-->

## Overview

Move old_thing to new_thing.

## Design Decisions

### 1. Decision

Structural move.

## Scope Summary

| Area | Count |
|------|-------|
| Files | 3 |

## Implementation Plan

### Step 1

Move the files.

## Files Touched

### Added
- new_thing.sh

### Modified
- old_thing.sh

## Negative Space

N/A.

## Acceptance Criteria

- [ ] Files moved to new location
- [ ] Build passes
- [ ] Tests pass
- [ ] shellcheck is clean
- [ ] docs updated
EOF

lint_output=$(draft_milestones_validate_output "$TEST_TMPDIR/lint_refactor.md" 2>&1)
lint_rc=$?
if [[ "$lint_rc" -eq 0 ]]; then
    pass "Structural-only refactor passes validation (lint is non-blocking)"
else
    fail "Validation should pass even when lint warnings fire (rc=${lint_rc})"
fi

if echo "$lint_output" | grep -q "LINT:"; then
    pass "Validation emits LINT: prefix for milestones with quality warnings"
else
    fail "Expected LINT: warnings in validation output, got: ${lint_output}"
fi

if echo "$lint_output" | grep -qi "behavioral"; then
    pass "Lint behavioral-criterion warning surfaces during authoring"
else
    fail "Expected behavioral-criterion warning, got: ${lint_output}"
fi

if echo "$lint_output" | grep -qi "completeness"; then
    pass "Lint refactor-completeness warning surfaces during authoring"
else
    fail "Expected refactor-completeness warning, got: ${lint_output}"
fi

# --- Fixture: well-formed milestone with behavioral acceptance criteria
cat > "$TEST_TMPDIR/lint_clean.md" << 'EOF'
# Milestone 99: Add Event Emitter

<!-- milestone-meta
id: "99"
status: "pending"
-->

## Overview

Add an event emitter.

## Design Decisions

### 1. Decision

Emit events on change.

## Scope Summary

| Area | Count |
|------|-------|
| Files | 1 |

## Implementation Plan

### Step 1

Implement.

## Files Touched

### Added
- lib/events.sh

## Negative Space

N/A.

## Acceptance Criteria

- [ ] emitter emits events on state change
- [ ] emitter rejects malformed payloads
- [ ] emitter handles concurrent writes
- [ ] emitter produces valid JSON
- [ ] shellcheck is clean
EOF

clean_output=$(draft_milestones_validate_output "$TEST_TMPDIR/lint_clean.md" 2>&1)
if echo "$clean_output" | grep -q "LINT:"; then
    fail "Clean milestone should not emit lint warnings, got: ${clean_output}"
else
    pass "Milestone with behavioral criteria produces no lint warnings"
fi

# --- Fixture: lint helper not loaded → validation skips lint silently
lint_no_helper=$(bash -c '
    set -euo pipefail
    export PROJECT_DIR="'"$TEST_TMPDIR"'"
    export MILESTONE_DIR=".claude/milestones"
    export MILESTONE_MANIFEST="MANIFEST.cfg"
    log()     { :; }
    warn()    { :; }
    error()   { :; }
    success() { :; }
    header()  { :; }
    # shellcheck source=../lib/draft_milestones_write.sh
    source "'"${TEKHTON_HOME}"'/lib/draft_milestones_write.sh"
    draft_milestones_validate_output "'"$TEST_TMPDIR"'/lint_refactor.md" 2>&1
' || true)

if echo "$lint_no_helper" | grep -q "LINT:"; then
    fail "Validation must skip lint when helper not loaded, got: ${lint_no_helper}"
else
    pass "Validation gracefully skips lint when lint_acceptance_criteria unavailable"
fi

echo
echo "────────────────────────────────────────"
echo "  ${PASS} passed, ${FAIL} failed"
echo "────────────────────────────────────────"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
