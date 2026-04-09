#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# test_m52_circular_onboarding.sh — Verify Milestone 52: Fix Circular Onboarding
#
# Tests that the circular --init ↔ --plan loop is broken:
# - _print_next_steps() in lib/plan.sh checks for pipeline.conf and skips
#   --init recommendation when it exists
# - emit_init_summary() in lib/init_report.sh checks for existing milestones
#   and skips --plan recommendation when they exist
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

declare -g PASSED=0 FAILED=0

pass() {
    ((PASSED++))
    echo "  ✓ $*"
}

fail() {
    ((FAILED++))
    echo "  ✗ $*"
}

# =============================================================================
# Test implementations
# =============================================================================

test1_print_next_steps_without_pipeline_conf() {
    local PROJECT_DIR
    PROJECT_DIR=$(mktemp -d)
    trap "rm -rf $PROJECT_DIR" EXIT
    export PROJECT_DIR

    mkdir -p "${PROJECT_DIR}/.claude"

    source "${TEKHTON_HOME}/lib/common.sh" >/dev/null 2>&1
    source "${TEKHTON_HOME}/lib/plan.sh" >/dev/null 2>&1

    local output
    output=$(_print_next_steps 2>&1 || true)

    # Should recommend --init when pipeline.conf doesn't exist
    if echo "$output" | grep -q "tekhton --init"; then
        return 0
    else
        return 1
    fi
}

test2_print_next_steps_with_pipeline_conf() {
    local PROJECT_DIR
    PROJECT_DIR=$(mktemp -d)
    trap "rm -rf $PROJECT_DIR" EXIT
    export PROJECT_DIR

    # Create pipeline.conf to simulate prior --init run
    mkdir -p "${PROJECT_DIR}/.claude"
    touch "${PROJECT_DIR}/.claude/pipeline.conf"

    source "${TEKHTON_HOME}/lib/common.sh" >/dev/null 2>&1
    source "${TEKHTON_HOME}/lib/plan.sh" >/dev/null 2>&1

    local output
    output=$(_print_next_steps 2>&1 || true)

    # Should NOT recommend --init when pipeline.conf exists
    if ! echo "$output" | grep -q "tekhton --init"; then
        # Should still recommend milestone implementation
        if echo "$output" | grep -q "Implement Milestone 1"; then
            return 0
        fi
    fi
    return 1
}

test3_print_next_steps_has_next_steps() {
    local PROJECT_DIR
    PROJECT_DIR=$(mktemp -d)
    trap "rm -rf $PROJECT_DIR" EXIT
    export PROJECT_DIR

    mkdir -p "${PROJECT_DIR}/.claude"

    source "${TEKHTON_HOME}/lib/common.sh" >/dev/null 2>&1
    source "${TEKHTON_HOME}/lib/plan.sh" >/dev/null 2>&1

    local output
    output=$(_print_next_steps 2>&1 || true)

    # Should always have "Next steps:" section
    if echo "$output" | grep -q "Next steps"; then
        return 0
    fi
    return 1
}

test4_emit_init_summary_without_milestones() {
    local PROJECT_DIR
    PROJECT_DIR=$(mktemp -d)
    trap "rm -rf $PROJECT_DIR" EXIT
    export PROJECT_DIR

    mkdir -p "${PROJECT_DIR}/.claude"

    source "${TEKHTON_HOME}/lib/common.sh" >/dev/null 2>&1
    source "${TEKHTON_HOME}/lib/init_report.sh" >/dev/null 2>&1

    # No milestones present
    local output
    output=$(emit_init_summary "$PROJECT_DIR" "" "" "" "custom" "10" 2>&1 || true)

    # Should recommend --plan when no milestones exist and files < 50
    if echo "$output" | grep -q "tekhton --plan"; then
        return 0
    fi
    return 1
}

test5_emit_init_summary_with_manifest_cfg() {
    local PROJECT_DIR
    PROJECT_DIR=$(mktemp -d)
    trap "rm -rf $PROJECT_DIR" EXIT
    export PROJECT_DIR

    # Create MANIFEST.cfg with entries (simulating prior --plan run)
    mkdir -p "${PROJECT_DIR}/.claude/milestones"
    cat > "${PROJECT_DIR}/.claude/milestones/MANIFEST.cfg" << 'MANIFEST'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Implement Feature X|pending||m01-feature-x.md|feature
MANIFEST

    source "${TEKHTON_HOME}/lib/common.sh" >/dev/null 2>&1
    source "${TEKHTON_HOME}/lib/init_report.sh" >/dev/null 2>&1

    local output
    output=$(emit_init_summary "$PROJECT_DIR" "" "" "" "custom" "10" 2>&1 || true)

    # Should NOT recommend --plan when MANIFEST.cfg has entries
    if ! echo "$output" | grep -q "tekhton --plan"; then
        # Should still recommend implementing milestone 1
        if echo "$output" | grep -q "Implement Milestone 1"; then
            return 0
        fi
    fi
    return 1
}

test6_emit_init_summary_with_empty_manifest() {
    local PROJECT_DIR
    PROJECT_DIR=$(mktemp -d)
    trap "rm -rf $PROJECT_DIR" EXIT
    export PROJECT_DIR

    # Create empty MANIFEST.cfg (no entries)
    mkdir -p "${PROJECT_DIR}/.claude/milestones"
    touch "${PROJECT_DIR}/.claude/milestones/MANIFEST.cfg"

    source "${TEKHTON_HOME}/lib/common.sh" >/dev/null 2>&1
    source "${TEKHTON_HOME}/lib/init_report.sh" >/dev/null 2>&1

    local output
    output=$(emit_init_summary "$PROJECT_DIR" "" "" "" "custom" "10" 2>&1 || true)

    # Should recommend --plan when MANIFEST.cfg is empty
    if echo "$output" | grep -q "tekhton --plan"; then
        return 0
    fi
    return 1
}

test7_emit_init_summary_with_claude_md_milestones() {
    local PROJECT_DIR
    PROJECT_DIR=$(mktemp -d)
    trap "rm -rf $PROJECT_DIR" EXIT
    export PROJECT_DIR

    mkdir -p "${PROJECT_DIR}/.claude"

    # Create CLAUDE.md with milestone headers (simulating prior --plan run)
    cat > "${PROJECT_DIR}/CLAUDE.md" << 'EOF'
# My Project

## Architecture

Some architecture description.

#### Milestone 1: Setup Foundation
- [ ] Task 1

#### Milestone 2: Core Features
- [ ] Task 2
EOF

    source "${TEKHTON_HOME}/lib/common.sh" >/dev/null 2>&1
    source "${TEKHTON_HOME}/lib/init_report.sh" >/dev/null 2>&1

    local output
    output=$(emit_init_summary "$PROJECT_DIR" "" "" "" "custom" "10" 2>&1 || true)

    # Should NOT recommend --plan when CLAUDE.md has milestones
    if ! echo "$output" | grep -q "tekhton --plan"; then
        # Should still recommend implementing milestone 1
        if echo "$output" | grep -q "Implement Milestone 1"; then
            return 0
        fi
    fi
    return 1
}

test8_emit_init_summary_with_stub_claude_md() {
    local PROJECT_DIR
    PROJECT_DIR=$(mktemp -d)
    trap "rm -rf $PROJECT_DIR" EXIT
    export PROJECT_DIR

    mkdir -p "${PROJECT_DIR}/.claude"

    # Create stub CLAUDE.md (from --init, contains TODO about --plan)
    cat > "${PROJECT_DIR}/CLAUDE.md" << 'EOF'
# My Project

## Project Rules

TODO stub.

<!-- TODO: Add milestones here, or run tekhton --plan to generate them -->

## Architecture

Stub architecture.
EOF

    source "${TEKHTON_HOME}/lib/common.sh" >/dev/null 2>&1
    source "${TEKHTON_HOME}/lib/init_report.sh" >/dev/null 2>&1

    local output
    output=$(emit_init_summary "$PROJECT_DIR" "" "" "" "custom" "10" 2>&1 || true)

    # Should recommend --plan when CLAUDE.md is a stub
    if echo "$output" | grep -q "tekhton --plan"; then
        return 0
    fi
    return 1
}

test9_circular_loop_prevention() {
    local PROJECT_DIR
    PROJECT_DIR=$(mktemp -d)
    trap "rm -rf $PROJECT_DIR" EXIT
    export PROJECT_DIR

    mkdir -p "${PROJECT_DIR}/.claude"

    # Simulate --init results (creates pipeline.conf)
    touch "${PROJECT_DIR}/.claude/pipeline.conf"

    source "${TEKHTON_HOME}/lib/common.sh" >/dev/null 2>&1
    source "${TEKHTON_HOME}/lib/init_report.sh" >/dev/null 2>&1

    local init_output
    init_output=$(emit_init_summary "$PROJECT_DIR" "" "" "" "custom" "10" 2>&1 || true)

    # After --init, should recommend --plan
    if ! echo "$init_output" | grep -q "tekhton --plan"; then
        return 1
    fi

    # Now simulate --plan run (creates CLAUDE.md with milestones)
    cat > "${PROJECT_DIR}/CLAUDE.md" << 'EOF'
# My Project

#### Milestone 1: Setup
- [ ] Task 1

#### Milestone 2: Features
- [ ] Task 2
EOF

    # Reload lib/plan.sh in new shell to test fresh state
    unset PLAN_INTERVIEW_MODEL PLAN_GENERATION_MODEL PLAN_INTERVIEW_MAX_TURNS PLAN_GENERATION_MAX_TURNS 2>/dev/null || true
    source "${TEKHTON_HOME}/lib/plan.sh" >/dev/null 2>&1

    local plan_output
    plan_output=$(_print_next_steps 2>&1 || true)

    # After --plan, should NOT recommend --init again
    if ! echo "$plan_output" | grep -q "tekhton --init"; then
        return 0
    fi
    return 1
}

test10a_emit_init_summary_greenfield_suppresses_warnings() {
    local PROJECT_DIR
    PROJECT_DIR=$(mktemp -d)
    trap "rm -rf $PROJECT_DIR" EXIT
    export PROJECT_DIR

    mkdir -p "${PROJECT_DIR}/.claude"

    source "${TEKHTON_HOME}/lib/common.sh" >/dev/null 2>&1
    source "${TEKHTON_HOME}/lib/init_report.sh" >/dev/null 2>&1

    # Greenfield: file_count=0, no architecture, no test command
    local output
    output=$(emit_init_summary "$PROJECT_DIR" "" "" "" "custom" "0" 2>&1 || true)

    # Should NOT show ARCHITECTURE_FILE warning on greenfield
    if echo "$output" | grep -q "ARCHITECTURE_FILE"; then
        return 1
    fi
    # Should NOT show test command warning on greenfield
    if echo "$output" | grep -q "No test command"; then
        return 1
    fi
    return 0
}

test10_emit_init_summary_large_project() {
    local PROJECT_DIR
    PROJECT_DIR=$(mktemp -d)
    trap "rm -rf $PROJECT_DIR" EXIT
    export PROJECT_DIR

    mkdir -p "${PROJECT_DIR}/.claude"

    source "${TEKHTON_HOME}/lib/common.sh" >/dev/null 2>&1
    source "${TEKHTON_HOME}/lib/init_report.sh" >/dev/null 2>&1

    # No milestones present, file_count > 50
    local output
    output=$(emit_init_summary "$PROJECT_DIR" "" "" "" "custom" "100" 2>&1 || true)

    # Should recommend --plan-from-index for large projects
    if echo "$output" | grep -q "tekhton --plan-from-index"; then
        # Should NOT recommend regular --plan
        if ! echo "$output" | grep -q "tekhton --plan \""; then
            return 0
        fi
    fi
    return 1
}

# =============================================================================
# Run all tests
# =============================================================================

main() {
    echo "Testing Milestone 52: Fix Circular Onboarding Flow"
    echo ""

    echo "Group 1: _print_next_steps() tests"
    test1_print_next_steps_without_pipeline_conf && pass "Recommends --init when pipeline.conf missing" || fail "Recommends --init when pipeline.conf missing"
    test2_print_next_steps_with_pipeline_conf && pass "Skips --init when pipeline.conf exists" || fail "Skips --init when pipeline.conf exists"
    test3_print_next_steps_has_next_steps && pass "Output has Next steps section" || fail "Output has Next steps section"

    echo ""
    echo "Group 2: emit_init_summary() tests"
    test4_emit_init_summary_without_milestones && pass "--plan recommended without milestones" || fail "--plan recommended without milestones"
    test5_emit_init_summary_with_manifest_cfg && pass "Skips --plan with MANIFEST.cfg entries" || fail "Skips --plan with MANIFEST.cfg entries"
    test6_emit_init_summary_with_empty_manifest && pass "--plan recommended with empty MANIFEST.cfg" || fail "--plan recommended with empty MANIFEST.cfg"
    test7_emit_init_summary_with_claude_md_milestones && pass "Skips --plan with CLAUDE.md milestones" || fail "Skips --plan with CLAUDE.md milestones"
    test8_emit_init_summary_with_stub_claude_md && pass "--plan recommended with stub CLAUDE.md" || fail "--plan recommended with stub CLAUDE.md"

    echo ""
    echo "Group 3: Greenfield and large-project branches"
    test10a_emit_init_summary_greenfield_suppresses_warnings && pass "Greenfield (file_count=0) suppresses ARCHITECTURE and test warnings" || fail "Greenfield (file_count=0) suppresses ARCHITECTURE and test warnings"
    test10_emit_init_summary_large_project && pass "Uses --plan-from-index for file_count > 50" || fail "Uses --plan-from-index for file_count > 50"

    echo ""
    echo "Integration tests"
    test9_circular_loop_prevention && pass "Circular loop prevented" || fail "Circular loop prevented"

    echo ""
    echo "Results: $PASSED passed, $FAILED failed"

    if [[ $FAILED -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
