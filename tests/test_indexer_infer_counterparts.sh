#!/usr/bin/env bash
# Test: lib/indexer.sh — infer_test_counterparts()
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

warn() { echo "[WARN] $*" >&2; }
log()  { echo "[LOG] $*" >&2; }

PROJECT_DIR="/tmp"
export PROJECT_DIR

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_helpers.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer.sh"

# =============================================================================
# Empty input returns empty
# =============================================================================

echo "=== infer_test_counterparts: empty input ==="

result=$(infer_test_counterparts "")
if [ -z "$result" ]; then
    pass "empty input returns empty output"
else
    fail "empty input should return empty, got: '${result}'"
fi

# =============================================================================
# Python conventions
# =============================================================================

echo "=== infer_test_counterparts: Python ==="

result=$(infer_test_counterparts "src/foo.py")

if echo "$result" | grep -qw "test_foo.py"; then
    pass "Python: generates test_foo.py counterpart"
else
    fail "Python: should generate test_foo.py, got: '${result}'"
fi

if echo "$result" | grep -qw "foo_test.py"; then
    pass "Python: generates foo_test.py counterpart"
else
    fail "Python: should generate foo_test.py, got: '${result}'"
fi

if echo "$result" | grep -qw "src/foo.py"; then
    pass "Python: original file is retained in output"
else
    fail "Python: original file should be in output, got: '${result}'"
fi

# =============================================================================
# TypeScript conventions
# =============================================================================

echo "=== infer_test_counterparts: TypeScript ==="

result=$(infer_test_counterparts "src/bar.ts")

if echo "$result" | grep -qw "bar.test.ts"; then
    pass "TypeScript: generates bar.test.ts counterpart"
else
    fail "TypeScript: should generate bar.test.ts, got: '${result}'"
fi

if echo "$result" | grep -qw "bar.spec.ts"; then
    pass "TypeScript: generates bar.spec.ts counterpart"
else
    fail "TypeScript: should generate bar.spec.ts, got: '${result}'"
fi

# =============================================================================
# JavaScript conventions
# =============================================================================

echo "=== infer_test_counterparts: JavaScript ==="

result=$(infer_test_counterparts "utils.js")

if echo "$result" | grep -qw "utils.test.js"; then
    pass "JavaScript: generates utils.test.js counterpart"
else
    fail "JavaScript: should generate utils.test.js, got: '${result}'"
fi

if echo "$result" | grep -qw "utils.spec.js"; then
    pass "JavaScript: generates utils.spec.js counterpart"
else
    fail "JavaScript: should generate utils.spec.js, got: '${result}'"
fi

# =============================================================================
# Go conventions
# =============================================================================

echo "=== infer_test_counterparts: Go ==="

result=$(infer_test_counterparts "pkg/server.go")

if echo "$result" | grep -qw "server_test.go"; then
    pass "Go: generates server_test.go counterpart"
else
    fail "Go: should generate server_test.go, got: '${result}'"
fi

# =============================================================================
# Rust conventions
# =============================================================================

echo "=== infer_test_counterparts: Rust ==="

result=$(infer_test_counterparts "src/lib.rs")

if echo "$result" | grep -q "tests/lib.rs"; then
    pass "Rust: generates tests/lib.rs counterpart"
else
    fail "Rust: should generate tests/lib.rs, got: '${result}'"
fi

# =============================================================================
# Java conventions
# =============================================================================

echo "=== infer_test_counterparts: Java ==="

result=$(infer_test_counterparts "com/example/UserService.java")

if echo "$result" | grep -qw "UserServiceTest.java"; then
    pass "Java: generates UserServiceTest.java counterpart"
else
    fail "Java: should generate UserServiceTest.java, got: '${result}'"
fi

# =============================================================================
# Ruby conventions
# =============================================================================

echo "=== infer_test_counterparts: Ruby ==="

result=$(infer_test_counterparts "lib/user.rb")

if echo "$result" | grep -qw "user_spec.rb"; then
    pass "Ruby: generates user_spec.rb counterpart"
else
    fail "Ruby: should generate user_spec.rb, got: '${result}'"
fi

if echo "$result" | grep -qw "test_user.rb"; then
    pass "Ruby: generates test_user.rb counterpart"
else
    fail "Ruby: should generate test_user.rb, got: '${result}'"
fi

# =============================================================================
# Bash/shell conventions
# =============================================================================

echo "=== infer_test_counterparts: Bash ==="

result=$(infer_test_counterparts "lib/common.sh")

if echo "$result" | grep -qw "test_common.sh"; then
    pass "Bash: generates test_common.sh counterpart"
else
    fail "Bash: should generate test_common.sh, got: '${result}'"
fi

# =============================================================================
# Already-test files are skipped (no double-inference)
# =============================================================================

echo "=== infer_test_counterparts: skip already-test files ==="

# test_ prefix
result=$(infer_test_counterparts "test_foo.py")
count=$(echo "$result" | tr ' ' '\n' | grep -c "test_" || true)
if [ "$count" -eq 1 ]; then
    pass "test_ prefix file is not augmented (count=1)"
else
    fail "test_ prefix file should not generate extra counterparts, got: '${result}'"
fi

# _test suffix
result=$(infer_test_counterparts "server_test.go")
if ! echo "$result" | grep -q "server_test_test"; then
    pass "_test suffix file is not further augmented"
else
    fail "_test suffix file should not generate more counterparts, got: '${result}'"
fi

# .test. mid-extension
result=$(infer_test_counterparts "bar.test.ts")
if ! echo "$result" | grep -q "bar.test.test"; then
    pass ".test. file is not further augmented"
else
    fail ".test. file should not generate more counterparts, got: '${result}'"
fi

# =============================================================================
# Unknown extension: original file preserved, no counterpart added
# =============================================================================

echo "=== infer_test_counterparts: unknown extension ==="

result=$(infer_test_counterparts "data/config.yaml")
if echo "$result" | grep -qw "data/config.yaml"; then
    pass "unknown extension: original file preserved"
else
    fail "unknown extension: original file should be in output, got: '${result}'"
fi

# No additional files should be added for yaml
word_count=$(echo "$result" | wc -w)
if [ "$word_count" -eq 1 ]; then
    pass "unknown extension: no counterparts added"
else
    fail "unknown extension: should produce only 1 token, got ${word_count} in '${result}'"
fi

# =============================================================================
# Multiple files at once
# =============================================================================

echo "=== infer_test_counterparts: multiple input files ==="

result=$(infer_test_counterparts "src/foo.py src/bar.go")

if echo "$result" | grep -qw "test_foo.py"; then
    pass "multiple files: Python counterpart generated"
else
    fail "multiple files: should generate test_foo.py, got: '${result}'"
fi

if echo "$result" | grep -qw "bar_test.go"; then
    pass "multiple files: Go counterpart generated"
else
    fail "multiple files: should generate bar_test.go, got: '${result}'"
fi

if echo "$result" | grep -qw "src/foo.py"; then
    pass "multiple files: original Python file retained"
else
    fail "multiple files: original src/foo.py should be in output, got: '${result}'"
fi

if echo "$result" | grep -qw "src/bar.go"; then
    pass "multiple files: original Go file retained"
else
    fail "multiple files: original src/bar.go should be in output, got: '${result}'"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
