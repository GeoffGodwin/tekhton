#!/usr/bin/env bash
set -euo pipefail

# Test: detect_languages() CLAUDE.md fallback
# Verifies that when file-based detection yields no results,
# detect_languages() reads the tech stack from CLAUDE.md's Project Identity section

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR=""

trap 'rm -rf "$TEMP_DIR"' EXIT

# Create temp directory for this test
TEMP_DIR=$(mktemp -d)

# Source the library
source "$TEST_DIR/lib/common.sh"
source "$TEST_DIR/lib/detect.sh"

# Test 1: TypeScript in CLAUDE.md fallback
echo "Test 1: TypeScript language detection from CLAUDE.md..."
TEST1_DIR=$(mktemp -d)
trap "rm -rf '$TEST1_DIR' '$TEMP_DIR'" EXIT

cat > "$TEST1_DIR/CLAUDE.md" << 'EOF'
# Project CLAUDE.md

### 1. Project Identity
- **Language:** TypeScript
- **Framework:** React
- **Architecture:** Component-based

This is a web application built with modern tooling.
EOF

# Call detect_languages with this directory
RESULT=$(detect_languages "$TEST1_DIR" 2>/dev/null || true)

# Verify output contains TypeScript with |low|CLAUDE.md
if echo "$RESULT" | grep -q "^typescript|low|CLAUDE\.md$"; then
    echo "✓ Test 1 PASSED: TypeScript detected from CLAUDE.md"
else
    echo "✗ Test 1 FAILED: Expected 'typescript|low|CLAUDE.md', got: '$RESULT'"
    exit 1
fi

# Test 2: Multiple languages in CLAUDE.md
echo "Test 2: Multiple languages from CLAUDE.md..."
TEST2_DIR=$(mktemp -d)
trap "rm -rf '$TEST1_DIR' '$TEST2_DIR' '$TEMP_DIR'" EXIT

cat > "$TEST2_DIR/CLAUDE.md" << 'EOF'
# Project CLAUDE.md

### 1. Project Identity
- **Tech Stack:**
  - TypeScript (frontend)
  - Python (backend)
  - PostgreSQL (database)

Built with modern microservices architecture.
EOF

# Call detect_languages
RESULT=$(detect_languages "$TEST2_DIR" 2>/dev/null || true)

# Verify both TypeScript and Python are detected
if echo "$RESULT" | grep -q "typescript|low|CLAUDE\.md" && echo "$RESULT" | grep -q "python|low|CLAUDE\.md"; then
    echo "✓ Test 2 PASSED: Multiple languages detected from CLAUDE.md"
else
    echo "✗ Test 2 FAILED: Expected both TypeScript and Python, got: '$RESULT'"
    exit 1
fi

# Test 3: Fallback handles bullet point format correctly
echo "Test 3: Fallback handles mixed bullet point formats..."
TEST3_DIR=$(mktemp -d)
trap "rm -rf '$TEST1_DIR' '$TEST2_DIR' '$TEST3_DIR' '$TEMP_DIR'" EXIT

# Create CLAUDE.md with bullets in proper markdown format
cat > "$TEST3_DIR/CLAUDE.md" << 'EOF'
### 1. Project Identity
- Go backend service
- JavaScript frontend
- Databases: PostgreSQL

This project uses modern cloud-native architecture.
EOF

RESULT=$(detect_languages "$TEST3_DIR" 2>/dev/null || true)

# Verify both Go and JavaScript are detected
if echo "$RESULT" | grep -q "go|low|CLAUDE\.md" && echo "$RESULT" | grep -q "javascript|low|CLAUDE\.md"; then
    echo "✓ Test 3 PASSED: Bullet points parsed correctly from CLAUDE.md"
else
    echo "✗ Test 3 FAILED: Expected both Go and JavaScript, got: '$RESULT'"
    exit 1
fi

# Test 4: No fallback when CLAUDE.md doesn't exist
echo "Test 4: No fallback when CLAUDE.md missing..."
TEST4_DIR=$(mktemp -d)
trap "rm -rf '$TEST1_DIR' '$TEST2_DIR' '$TEST3_DIR' '$TEST4_DIR' '$TEMP_DIR'" EXIT

# Empty directory with no CLAUDE.md
RESULT=$(detect_languages "$TEST4_DIR" 2>/dev/null || true)

# Result should be empty
if [[ -z "$RESULT" ]]; then
    echo "✓ Test 4 PASSED: Empty detection when no CLAUDE.md and no source files"
else
    echo "✗ Test 4 FAILED: Expected empty result, got: '$RESULT'"
    exit 1
fi

# Test 5: C# alias handling (C# should be converted to csharp)
echo "Test 5: C# alias handling..."
TEST5_DIR=$(mktemp -d)
trap "rm -rf '$TEST1_DIR' '$TEST2_DIR' '$TEST3_DIR' '$TEST4_DIR' '$TEST5_DIR' '$TEMP_DIR'" EXIT

cat > "$TEST5_DIR/CLAUDE.md" << 'EOF'
### 1. Project Identity
- C# backend
- Entity Framework Core
EOF

RESULT=$(detect_languages "$TEST5_DIR" 2>/dev/null || true)

# Verify C# is converted to csharp
if echo "$RESULT" | grep -q "^csharp|low|CLAUDE\.md$"; then
    echo "✓ Test 5 PASSED: C# properly aliased to csharp"
else
    echo "✗ Test 5 FAILED: Expected 'csharp|low|CLAUDE.md', got: '$RESULT'"
    exit 1
fi

echo ""
echo "All tests passed!"
exit 0
