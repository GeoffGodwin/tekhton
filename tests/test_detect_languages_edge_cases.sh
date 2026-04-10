#!/usr/bin/env bash
# Test: detect_languages edge cases
# Verifies safe handling of malformed CLAUDE.md, empty sections, and C# normalization
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source detection libraries
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"

# Helper: make a fresh project dir
make_proj() {
    local name="$1"
    local dir="${TEST_TMPDIR}/${name}"
    mkdir -p "$dir"
    echo "$dir"
}

# =============================================================================
# Test 1: CLAUDE.md with empty Project Identity section
# =============================================================================
echo "=== Test: Empty Project Identity section ==="

EMPTY_DIR=$(make_proj "empty_identity")

cat > "$EMPTY_DIR/CLAUDE.md" << 'EOF'
# Project

### 1. Project Identity

(empty section)

### 2. Architecture

Details here.
EOF

empty_langs=$(detect_languages "$EMPTY_DIR")

# Should return empty (no languages detected)
if [[ -z "$empty_langs" ]]; then
    pass "Empty Project Identity returns no language output"
else
    fail "Empty Project Identity should return empty, got: $empty_langs"
fi

# =============================================================================
# Test 2: CLAUDE.md without Project Identity section
# =============================================================================
echo "=== Test: Missing Project Identity section ==="

NO_IDENTITY_DIR=$(make_proj "no_identity")

cat > "$NO_IDENTITY_DIR/CLAUDE.md" << 'EOF'
# Project

### 2. Architecture

Details here.

### 3. Tech Stack

Implemented in TypeScript and Go.
EOF

no_identity_langs=$(detect_languages "$NO_IDENTITY_DIR")

# Strategy 3 (whole-file word-boundary scan) will find languages mentioned anywhere in
# the file, including the Tech Stack section's prose.  This is intentional — we want to
# detect the project's languages even when ### 1. Project Identity is absent.
if echo "$no_identity_langs" | grep -q "^typescript|" && echo "$no_identity_langs" | grep -q "^go|"; then
    pass "Languages found via whole-file fallback when Project Identity section is missing"
else
    fail "Expected TypeScript and Go via whole-file fallback, got: $no_identity_langs"
fi

# =============================================================================
# Test 3: CLAUDE.md with only whitespace in Project Identity
# =============================================================================
echo "=== Test: Whitespace-only Project Identity section ==="

WHITESPACE_DIR=$(make_proj "whitespace_identity")

cat > "$WHITESPACE_DIR/CLAUDE.md" << 'EOF'
# Project

### 1. Project Identity




### 2. Architecture

Details.
EOF

whitespace_langs=$(detect_languages "$WHITESPACE_DIR")

# Should return empty (only whitespace is considered empty)
if [[ -z "$whitespace_langs" ]]; then
    pass "Whitespace-only Project Identity returns no output"
else
    fail "Whitespace-only Identity should return empty, got: $whitespace_langs"
fi

# =============================================================================
# Test 4: C# language normalization
# =============================================================================
echo "=== Test: C# language name normalization ==="

CSHARP_DIR=$(make_proj "csharp_project")

cat > "$CSHARP_DIR/CLAUDE.md" << 'EOF'
# .NET Project

### 1. Project Identity

- C#
- ASP.NET

### 2. Architecture

Web framework.
EOF

csharp_langs=$(detect_languages "$CSHARP_DIR")

# Should detect csharp (aligned with file-based detection key)
if echo "$csharp_langs" | grep -q "^csharp|"; then
    pass "C# detected and normalized to csharp"
else
    fail "C# NOT detected or not normalized: $csharp_langs"
fi

# =============================================================================
# Test 5: Unknown/unlisted languages should be ignored
# =============================================================================
echo "=== Test: Unknown languages are ignored ==="

UNKNOWN_DIR=$(make_proj "unknown_langs")

cat > "$UNKNOWN_DIR/CLAUDE.md" << 'EOF'
# Project

### 1. Project Identity

- Go
- COBOL
- TypeScript
- Brainfuck

### 2. Architecture

Mixed tech.
EOF

unknown_langs=$(detect_languages "$UNKNOWN_DIR")

# Should detect Go and TypeScript (known languages)
if echo "$unknown_langs" | grep -q "^go|"; then
    pass "Go detected"
else
    fail "Go NOT detected: $unknown_langs"
fi

if echo "$unknown_langs" | grep -q "^typescript|"; then
    pass "TypeScript detected"
else
    fail "TypeScript NOT detected: $unknown_langs"
fi

# Should NOT detect COBOL or Brainfuck (not in known languages list)
if echo "$unknown_langs" | grep -qi "cobol\|brainfuck"; then
    fail "Unknown languages should not be detected: $unknown_langs"
else
    pass "Unknown languages correctly ignored"
fi

# =============================================================================
# Test 6: Only known languages in _known_langs are extracted
# =============================================================================
echo "=== Test: Only officially supported languages are extracted ==="

OFFICIAL_DIR=$(make_proj "official_langs")

# List all known languages from the code: TypeScript|JavaScript|Python|Go|Rust|Java|Kotlin|Swift|Dart|Ruby|PHP|C#|Elixir|Haskell
cat > "$OFFICIAL_DIR/CLAUDE.md" << 'EOF'
# Multi-Language

### 1. Project Identity

- TypeScript
- JavaScript
- Python
- Go
- Rust
- Java
- Kotlin
- Swift
- Dart
- Ruby
- PHP
- C#
- Elixir
- Haskell

### 2. Architecture

All languages.
EOF

official_langs=$(detect_languages "$OFFICIAL_DIR")

# Verify all 14 known languages are detected
expected_count=14
actual_count=$(echo "$official_langs" | wc -l)

if [[ "$actual_count" -eq "$expected_count" ]]; then
    pass "All 14 known languages detected correctly"
else
    fail "Expected $expected_count languages, got $actual_count: $official_langs"
fi

# All should be low confidence from CLAUDE.md
all_low=$(echo "$official_langs" | grep -c "|low|CLAUDE.md" || true)
if [[ "$all_low" -eq "$expected_count" ]]; then
    pass "All detected languages have low confidence from CLAUDE.md"
else
    fail "Not all languages have low confidence: $official_langs"
fi

# =============================================================================
# Test 7: Fallback gracefully handles sed/grep errors
# =============================================================================
echo "=== Test: Graceful error handling in fallback ==="

ERROR_DIR=$(make_proj "error_handling")

# Create a CLAUDE.md with potentially problematic content
cat > "$ERROR_DIR/CLAUDE.md" << 'EOF'
# Project

### 1. Project Identity

- Go (primary)
- Python (tools)

### 2. Section with regex-like content

This section has [special] (characters) like $ and ^ and \.

### 3. Architecture

Details.
EOF

error_langs=$(detect_languages "$ERROR_DIR")

# Should still detect Go and Python despite regex-like content in later sections
if echo "$error_langs" | grep -q "^go|"; then
    pass "Go detected despite regex-like content in later sections"
else
    fail "Go NOT detected: $error_langs"
fi

if echo "$error_langs" | grep -q "^python|"; then
    pass "Python detected despite regex-like content in later sections"
else
    fail "Python NOT detected: $error_langs"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
