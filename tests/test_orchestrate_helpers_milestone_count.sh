#!/usr/bin/env bash
# Test: get_milestone_count uses PROJECT_RULES_FILE variable (M92 Note 3)
set -euo pipefail

TEKHTON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(mktemp -d)"
trap "rm -rf $PROJECT_DIR" EXIT

# Source required libraries
source "$TEKHTON_DIR/lib/common.sh"
source "$TEKHTON_DIR/lib/milestones.sh"
source "$TEKHTON_DIR/lib/milestone_query.sh"

# Test 1: get_milestone_count with default CLAUDE.md
test_milestone_count_default() {
    # Create a CLAUDE.md with a milestone using correct format (#### Milestone N:)
    cat > "$PROJECT_DIR/CLAUDE.md" <<'EOF'
# Test Project

#### Milestone 1: First task
Some content

#### Milestone 2: Second task
More content

#### Milestone 3: Third task
Even more content
EOF

    cd "$PROJECT_DIR"

    # Disable DAG mode to test inline parsing
    export MILESTONE_DAG_ENABLED=false

    # Call get_milestone_count without PROJECT_RULES_FILE set
    unset PROJECT_RULES_FILE
    local count=$(get_milestone_count "CLAUDE.md")

    if [[ "$count" != "3" ]]; then
        echo "FAIL: get_milestone_count returned '$count' instead of 3 for default CLAUDE.md"
        return 1
    fi

    cd - > /dev/null
    return 0
}

# Test 2: get_milestone_count with PROJECT_RULES_FILE set
test_milestone_count_custom_rules_file() {
    # Create a custom rules file with correct format
    cat > "$PROJECT_DIR/DESIGN.md" <<'EOF'
# Design Document

#### Milestone 1: Alpha
Content A

#### Milestone 2: Beta
Content B
EOF

    cd "$PROJECT_DIR"

    # Disable DAG mode
    export MILESTONE_DAG_ENABLED=false

    # Call get_milestone_count with PROJECT_RULES_FILE set
    export PROJECT_RULES_FILE="DESIGN.md"
    local count=$(get_milestone_count "${PROJECT_RULES_FILE:-CLAUDE.md}")

    if [[ "$count" != "2" ]]; then
        echo "FAIL: get_milestone_count returned '$count' instead of 2 for DESIGN.md"
        return 1
    fi

    cd - > /dev/null
    return 0
}

# Test 3: Verify get_milestone_count respects the file parameter over default
test_milestone_count_explicit_parameter() {
    # Create both files with correct format
    cat > "$PROJECT_DIR/CLAUDE.md" <<'EOF'
# Default Rules

#### Milestone 1: First
Content

#### Milestone 2: Second
Content
EOF

    cat > "$PROJECT_DIR/RULES.md" <<'EOF'
# Custom Rules

#### Milestone 1: Alpha
Content

#### Milestone 2: Beta
Content

#### Milestone 3: Gamma
Content
EOF

    cd "$PROJECT_DIR"

    # Disable DAG mode
    export MILESTONE_DAG_ENABLED=false

    # Explicitly pass RULES.md
    local count=$(get_milestone_count "RULES.md")

    if [[ "$count" != "3" ]]; then
        echo "FAIL: get_milestone_count returned '$count' instead of 3 for RULES.md"
        return 1
    fi

    cd - > /dev/null
    return 0
}

# Run all tests
if test_milestone_count_default && \
   test_milestone_count_custom_rules_file && \
   test_milestone_count_explicit_parameter; then
    echo "PASS"
    exit 0
else
    echo "FAIL"
    exit 1
fi
