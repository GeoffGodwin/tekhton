#!/usr/bin/env bash
# Test: Verify ARCHITECTURE_FILE config path is correctly checked
# Tests fix for lib/init_report.sh: after hardcoded ARCHITECTURE.md check,
# also parse pipeline.conf for ARCHITECTURE_FILE= and test that path

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
# Test 1: ARCHITECTURE.md is found at default location
# ============================================================================
test_default_architecture_file_found() {
    local project_dir
    project_dir=$(mktemp -d)

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Create ARCHITECTURE.md at default location
    touch "${project_dir}/ARCHITECTURE.md"

    # Call emit_init_summary with file_count > 0
    local output
    output=$(emit_init_summary "$project_dir" "" "" "" "web-app" 10 2>&1)

    # ARCHITECTURE_FILE warning should NOT appear (file found at default location)
    if echo "$output" | grep -q "ARCHITECTURE_FILE not detected"; then
        rm -rf "$project_dir"
        fail "Should not show ARCHITECTURE_FILE warning when ARCHITECTURE.md exists"
    else
        pass "Correctly found ARCHITECTURE.md at default location"
    fi

    rm -rf "$project_dir"
}

# ============================================================================
# Test 2: Custom ARCHITECTURE_FILE path is read from pipeline.conf
# ============================================================================
test_custom_architecture_file_path_from_config() {
    local project_dir
    project_dir=$(mktemp -d)

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Create .claude/pipeline.conf with custom ARCHITECTURE_FILE
    mkdir -p "${project_dir}/.claude"
    cat > "${project_dir}/.claude/pipeline.conf" << 'EOF'
ARCHITECTURE_FILE="docs/architecture.md"
EOF

    # Create the architecture file at the custom location
    mkdir -p "${project_dir}/docs"
    touch "${project_dir}/docs/architecture.md"

    # Call emit_init_summary with file_count > 0
    local output
    output=$(emit_init_summary "$project_dir" "" "" "" "web-app" 10 2>&1)

    # ARCHITECTURE_FILE warning should NOT appear (file found at configured path)
    if echo "$output" | grep -q "ARCHITECTURE_FILE not detected"; then
        rm -rf "$project_dir"
        fail "Should not show ARCHITECTURE_FILE warning when custom path exists in pipeline.conf"
    else
        pass "Correctly found custom ARCHITECTURE_FILE path from pipeline.conf"
    fi

    rm -rf "$project_dir"
}

# ============================================================================
# Test 3: Custom ARCHITECTURE_FILE path with quotes is handled correctly
# ============================================================================
test_custom_architecture_file_with_single_quotes() {
    local project_dir
    project_dir=$(mktemp -d)

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Create .claude/pipeline.conf with custom ARCHITECTURE_FILE in single quotes
    mkdir -p "${project_dir}/.claude"
    cat > "${project_dir}/.claude/pipeline.conf" << "EOF"
ARCHITECTURE_FILE='docs/system-design.md'
EOF

    # Create the architecture file at the custom location
    mkdir -p "${project_dir}/docs"
    touch "${project_dir}/docs/system-design.md"

    # Call emit_init_summary with file_count > 0
    local output
    output=$(emit_init_summary "$project_dir" "" "" "" "web-app" 10 2>&1)

    # ARCHITECTURE_FILE warning should NOT appear (quotes should be stripped)
    if echo "$output" | grep -q "ARCHITECTURE_FILE not detected"; then
        rm -rf "$project_dir"
        fail "Should handle ARCHITECTURE_FILE with single quotes from pipeline.conf"
    else
        pass "Correctly handled ARCHITECTURE_FILE with single quotes"
    fi

    rm -rf "$project_dir"
}

# ============================================================================
# Test 4: Custom ARCHITECTURE_FILE path with double quotes is handled correctly
# ============================================================================
test_custom_architecture_file_with_double_quotes() {
    local project_dir
    project_dir=$(mktemp -d)

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Create .claude/pipeline.conf with custom ARCHITECTURE_FILE in double quotes
    mkdir -p "${project_dir}/.claude"
    cat > "${project_dir}/.claude/pipeline.conf" << 'EOF'
ARCHITECTURE_FILE="docs/ARCHITECTURE.md"
EOF

    # Create the architecture file at the custom location
    mkdir -p "${project_dir}/docs"
    touch "${project_dir}/docs/ARCHITECTURE.md"

    # Call emit_init_summary with file_count > 0
    local output
    output=$(emit_init_summary "$project_dir" "" "" "" "web-app" 10 2>&1)

    # ARCHITECTURE_FILE warning should NOT appear (quotes should be stripped)
    if echo "$output" | grep -q "ARCHITECTURE_FILE not detected"; then
        rm -rf "$project_dir"
        fail "Should handle ARCHITECTURE_FILE with double quotes from pipeline.conf"
    else
        pass "Correctly handled ARCHITECTURE_FILE with double quotes"
    fi

    rm -rf "$project_dir"
}

# ============================================================================
# Test 5: Missing custom ARCHITECTURE_FILE path triggers warning
# ============================================================================
test_missing_custom_architecture_file() {
    local project_dir
    project_dir=$(mktemp -d)

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Create .claude/pipeline.conf with custom path that doesn't exist
    mkdir -p "${project_dir}/.claude"
    cat > "${project_dir}/.claude/pipeline.conf" << 'EOF'
ARCHITECTURE_FILE="docs/architecture.md"
EOF

    # Do NOT create the file at the custom location
    # Call emit_init_summary with file_count > 0
    local output
    output=$(emit_init_summary "$project_dir" "" "" "" "web-app" 10 2>&1)

    # ARCHITECTURE_FILE warning SHOULD appear (file doesn't exist)
    # New message format: ARCHITECTURE_FILE="<path>" not found
    if echo "$output" | grep -q 'ARCHITECTURE_FILE.*not found'; then
        pass "Correctly warns when custom ARCHITECTURE_FILE path doesn't exist"
    else
        rm -rf "$project_dir"
        fail "Should warn about missing custom ARCHITECTURE_FILE path"
    fi

    rm -rf "$project_dir"
}

# ============================================================================
# Test 6: _report_attention_items also checks custom ARCHITECTURE_FILE path
# ============================================================================
test_report_attention_items_custom_architecture() {
    local project_dir
    project_dir=$(mktemp -d)

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Create .claude/pipeline.conf with custom path
    mkdir -p "${project_dir}/.claude"
    cat > "${project_dir}/.claude/pipeline.conf" << 'EOF'
ARCHITECTURE_FILE="architecture/design.md"
EOF

    # Create the file at the custom location
    mkdir -p "${project_dir}/architecture"
    touch "${project_dir}/architecture/design.md"

    # Call _report_attention_items with file_count > 0
    local output
    output=$(_report_attention_items "$project_dir" "" 10)

    # ARCHITECTURE_FILE warning should NOT appear
    if echo "$output" | grep -q "ARCHITECTURE_FILE"; then
        rm -rf "$project_dir"
        fail "_report_attention_items should check custom ARCHITECTURE_FILE path"
    else
        pass "_report_attention_items correctly checks custom ARCHITECTURE_FILE path"
    fi

    rm -rf "$project_dir"
}

# ============================================================================
# Test 7: INIT_REPORT.md also uses custom ARCHITECTURE_FILE path
# ============================================================================
test_init_report_file_custom_architecture() {
    local project_dir
    project_dir=$(mktemp -d)

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Create .claude/pipeline.conf with custom path
    mkdir -p "${project_dir}/.claude"
    cat > "${project_dir}/.claude/pipeline.conf" << 'EOF'
ARCHITECTURE_FILE="docs/system.md"
EOF

    # Create the file at the custom location
    mkdir -p "${project_dir}/docs"
    touch "${project_dir}/docs/system.md"

    # Generate INIT_REPORT.md with file_count > 0
    emit_init_report_file "$project_dir" "" "" "" "" "web-app" 10

    local report_file="${project_dir}/INIT_REPORT.md"
    local report_content=$(cat "$report_file")

    # ARCHITECTURE_FILE warning should NOT appear in report
    if echo "$report_content" | grep -q "ARCHITECTURE_FILE not detected"; then
        rm -rf "$project_dir"
        fail "INIT_REPORT.md should not warn when custom ARCHITECTURE_FILE path exists"
    else
        pass "INIT_REPORT.md correctly checks custom ARCHITECTURE_FILE path"
    fi

    rm -rf "$project_dir"
}

# ============================================================================
# Test 8: Empty ARCHITECTURE_FILE config value is treated as "not set" — no warning
# Empty/unset means the default; agents create the file organically.
# ============================================================================
test_empty_architecture_file_config() {
    local project_dir
    project_dir=$(mktemp -d)

    source "${TEKHTON_HOME}/lib/init_report.sh"

    # Create .claude/pipeline.conf with empty ARCHITECTURE_FILE
    mkdir -p "${project_dir}/.claude"
    cat > "${project_dir}/.claude/pipeline.conf" << 'EOF'
ARCHITECTURE_FILE=""
EOF

    # Test 1: emit_init_summary — empty value is not a broken reference → no warning
    local output
    output=$(emit_init_summary "$project_dir" "" "" "" "web-app" 10 2>&1)

    # Empty ARCHITECTURE_FILE is equivalent to unset — should NOT warn
    if echo "$output" | grep -q 'ARCHITECTURE_FILE.*not found'; then
        rm -rf "$project_dir"
        fail "emit_init_summary should NOT warn when ARCHITECTURE_FILE is empty (not a broken reference)"
    else
        pass "Empty ARCHITECTURE_FILE correctly suppressed in emit_init_summary (not a broken reference)"
    fi

    # Test 2: _report_attention_items — same: empty value should not trigger warning
    local report_output
    report_output=$(_report_attention_items "$project_dir" "" 10)

    if echo "$report_output" | grep -q 'ARCHITECTURE_FILE.*not found'; then
        rm -rf "$project_dir"
        fail "_report_attention_items should NOT warn when ARCHITECTURE_FILE is empty"
    else
        pass "Empty ARCHITECTURE_FILE correctly suppressed in _report_attention_items"
    fi

    rm -rf "$project_dir"
}

# ============================================================================
# Run all tests
# ============================================================================
test_default_architecture_file_found
test_custom_architecture_file_path_from_config
test_custom_architecture_file_with_single_quotes
test_custom_architecture_file_with_double_quotes
test_missing_custom_architecture_file
test_report_attention_items_custom_architecture
test_init_report_file_custom_architecture
test_empty_architecture_file_config

echo
echo -e "${GREEN}All tests passed!${NC}"
