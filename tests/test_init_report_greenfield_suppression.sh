#!/usr/bin/env bash
# Test: Verify greenfield projects (file_count=0) suppress false-positive warnings
# Tests fix for lib/init_report.sh: ARCHITECTURE_FILE and test command warnings
# should not appear on greenfield projects since there's no code to document yet

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/init_config.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    exit 1
}

# ============================================================================
# Test 1: emit_init_summary suppresses ARCHITECTURE_FILE warning on greenfield
# ============================================================================
test_emit_init_summary_no_arch_warning_on_greenfield() {
    local project_dir
    project_dir=$(mktemp -d)
    trap "rm -rf '$project_dir'" RETURN

    # Source the init_report library
    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Capture output from emit_init_summary
    # file_count=0 (greenfield), no ARCHITECTURE.md, no pipeline.conf
    local output
    output=$(emit_init_summary "$project_dir" "" "" "" "api-service" 0 2>&1)

    # ARCHITECTURE_FILE warning should NOT appear on greenfield
    if echo "$output" | grep -q "ARCHITECTURE_FILE not detected"; then
        fail "emit_init_summary should suppress ARCHITECTURE_FILE warning on greenfield (file_count=0)"
    else
        pass "emit_init_summary correctly suppresses ARCHITECTURE_FILE warning on greenfield"
    fi
}

# ============================================================================
# Test 2: emit_init_summary suppresses test command warning on greenfield
# ============================================================================
test_emit_init_summary_no_test_warning_on_greenfield() {
    local project_dir
    project_dir=$(mktemp -d)
    trap "rm -rf '$project_dir'" RETURN

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Capture output: file_count=0, no test command detected
    local output
    output=$(emit_init_summary "$project_dir" "" "" "" "cli-tool" 0 2>&1)

    # "No test command detected" warning should NOT appear on greenfield
    if echo "$output" | grep -q "No test command detected"; then
        fail "emit_init_summary should suppress test command warning on greenfield (file_count=0)"
    else
        pass "emit_init_summary correctly suppresses test command warning on greenfield"
    fi
}

# ============================================================================
# Test 3: emit_init_summary does NOT falsely warn on brownfield when no explicit
#          broken ARCHITECTURE_FILE reference exists in pipeline.conf.
#          The default (empty/unset) means agents create the file organically.
# ============================================================================
test_emit_init_summary_no_arch_warning_on_brownfield_without_explicit_ref() {
    local project_dir
    project_dir=$(mktemp -d)
    trap "rm -rf '$project_dir'" RETURN

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # file_count=10 (brownfield), no ARCHITECTURE.md, no pipeline.conf with ARCHITECTURE_FILE
    local output
    output=$(emit_init_summary "$project_dir" "" "" "" "web-app" 10 2>&1)

    # Without an explicit broken reference, ARCHITECTURE_FILE warning should NOT appear
    if echo "$output" | grep -q 'ARCHITECTURE_FILE.*not found'; then
        fail "emit_init_summary should NOT warn about ARCHITECTURE_FILE on brownfield without an explicit broken reference"
    else
        pass "emit_init_summary correctly suppresses false ARCHITECTURE_FILE warning on brownfield (no explicit broken ref)"
    fi
}

# ============================================================================
# Test 4: emit_init_summary DOES show test command warning on non-greenfield
# ============================================================================
test_emit_init_summary_shows_test_warning_on_brownfield() {
    local project_dir
    project_dir=$(mktemp -d)
    trap "rm -rf '$project_dir'" RETURN

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # file_count=10, empty commands (no test command)
    local output
    output=$(emit_init_summary "$project_dir" "" "" "" "web-app" 10 2>&1)

    # On brownfield, test command warning SHOULD appear
    if echo "$output" | grep -q "No test command detected"; then
        pass "emit_init_summary correctly shows test command warning on brownfield (file_count > 0)"
    else
        fail "emit_init_summary should show test command warning on brownfield with file_count > 0"
    fi
}

# ============================================================================
# Test 5: _report_attention_items receives and uses file_count parameter
# ============================================================================
test_report_attention_items_file_count_parameter() {
    local project_dir
    project_dir=$(mktemp -d)
    trap "rm -rf '$project_dir'" RETURN

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Call _report_attention_items with file_count=0
    local output
    output=$(_report_attention_items "$project_dir" "" 0)

    # With file_count=0, no ARCHITECTURE_FILE or test warnings should appear
    if echo "$output" | grep -q "ARCHITECTURE_FILE"; then
        fail "_report_attention_items should suppress ARCHITECTURE_FILE warning when file_count=0"
    else
        pass "_report_attention_items correctly respects file_count=0 parameter"
    fi
}

# ============================================================================
# Test 6: _report_attention_items does NOT falsely warn on brownfield when no
#          explicit broken ARCHITECTURE_FILE reference exists in pipeline.conf
# ============================================================================
test_report_attention_items_no_false_arch_warning_on_brownfield() {
    local project_dir
    project_dir=$(mktemp -d)
    trap "rm -rf '$project_dir'" RETURN

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Call _report_attention_items with file_count=10 (brownfield), no pipeline.conf
    local output
    output=$(_report_attention_items "$project_dir" "" 10)

    # Without an explicit broken ARCHITECTURE_FILE reference, no arch warning should appear
    if echo "$output" | grep -q 'ARCHITECTURE_FILE.*not found'; then
        fail "_report_attention_items should NOT warn about ARCHITECTURE_FILE on brownfield without explicit broken ref"
    else
        pass "_report_attention_items correctly suppresses false ARCHITECTURE_FILE warning on brownfield"
    fi
}

# ============================================================================
# Test 7: emit_init_report_file suppresses warnings on greenfield
# ============================================================================
test_emit_init_report_file_greenfield_no_warnings() {
    local project_dir
    project_dir=$(mktemp -d)
    # Don't trap here — let cleanup happen at the end

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Generate INIT_REPORT.md with file_count=0 (greenfield)
    emit_init_report_file "$project_dir" "" "" "" "" "cli-tool" 0

    local report_file="${project_dir}/INIT_REPORT.md"
    if [[ ! -f "$report_file" ]]; then
        rm -rf "$project_dir"
        fail "emit_init_report_file should create INIT_REPORT.md"
    fi

    local report_content
    report_content=$(cat "$report_file")

    # On greenfield, no ARCHITECTURE_FILE or test warnings should appear
    if echo "$report_content" | grep -q "ARCHITECTURE_FILE not detected"; then
        rm -rf "$project_dir"
        fail "INIT_REPORT.md should not contain ARCHITECTURE_FILE warning on greenfield (file_count=0)"
    else
        pass "INIT_REPORT.md correctly suppresses ARCHITECTURE_FILE warning on greenfield"
    fi

    if echo "$report_content" | grep -q "No test command detected"; then
        rm -rf "$project_dir"
        fail "INIT_REPORT.md should not contain test command warning on greenfield (file_count=0)"
    else
        pass "INIT_REPORT.md correctly suppresses test command warning on greenfield"
    fi

    rm -rf "$project_dir"
}

# ============================================================================
# Test 8: emit_init_report_file does NOT falsely warn on brownfield when no
#          explicit broken ARCHITECTURE_FILE reference exists
# ============================================================================
test_emit_init_report_file_brownfield_no_false_arch_warning() {
    local project_dir
    project_dir=$(mktemp -d)

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Generate INIT_REPORT.md with file_count=10 (brownfield), no pipeline.conf
    emit_init_report_file "$project_dir" "" "" "" "" "web-app" 10

    local report_file="${project_dir}/INIT_REPORT.md"
    if [[ ! -f "$report_file" ]]; then
        rm -rf "$project_dir"
        fail "emit_init_report_file should create INIT_REPORT.md"
    fi

    local report_content
    report_content=$(cat "$report_file")

    # Without an explicit broken ARCHITECTURE_FILE reference, no false warning should appear
    if echo "$report_content" | grep -q 'ARCHITECTURE_FILE.*not found'; then
        rm -rf "$project_dir"
        fail "INIT_REPORT.md should NOT falsely warn about ARCHITECTURE_FILE on brownfield without explicit broken ref"
    else
        pass "INIT_REPORT.md correctly suppresses false ARCHITECTURE_FILE warning on brownfield"
    fi

    rm -rf "$project_dir"
}

# ============================================================================
# Run all tests
# ============================================================================
test_emit_init_summary_no_arch_warning_on_greenfield
test_emit_init_summary_no_test_warning_on_greenfield
test_emit_init_summary_no_arch_warning_on_brownfield_without_explicit_ref
test_emit_init_summary_shows_test_warning_on_brownfield
test_report_attention_items_file_count_parameter
test_report_attention_items_no_false_arch_warning_on_brownfield
test_emit_init_report_file_greenfield_no_warnings
test_emit_init_report_file_brownfield_no_false_arch_warning

echo
echo -e "${GREEN}All tests passed!${NC}"
