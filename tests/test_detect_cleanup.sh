#!/usr/bin/env bash
# Test: detect.sh cleanup — Node.js framework lang labels, ERE dot escaping, confidence sort order
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

# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"

make_proj() {
    local name="$1"
    local dir="${TEST_TMPDIR}/${name}"
    mkdir -p "$dir"
    echo "$dir"
}

# =============================================================================
# Node.js framework lang labels — all should be "node", not "typescript"/"javascript"
# =============================================================================
echo "=== detect_frameworks: Node.js framework lang labels are 'node' ==="

NODE_DIR=$(make_proj "node_frameworks")
cat > "$NODE_DIR/package.json" << 'EOF'
{
  "name": "my-app",
  "dependencies": {
    "express": "^4.18.0",
    "react": "^18.0.0",
    "vue": "^3.0.0",
    "@angular/core": "^16.0.0",
    "svelte": "^3.0.0",
    "fastify": "^4.0.0"
  }
}
EOF

node_frameworks=$(detect_frameworks "$NODE_DIR")

for fw in express react vue angular svelte fastify; do
    if echo "$node_frameworks" | grep "^${fw}|" | grep -q "|node|"; then
        pass "${fw} framework has lang label 'node'"
    elif echo "$node_frameworks" | grep -q "^${fw}|"; then
        actual=$(echo "$node_frameworks" | grep "^${fw}|" | cut -d'|' -f2)
        fail "${fw} framework lang label should be 'node', got '${actual}'"
    else
        fail "${fw} not detected at all"
    fi
done

# Verify no framework uses 'typescript' or 'javascript' as lang label
if echo "$node_frameworks" | grep -q '|typescript|'; then
    fail "Framework output must not use 'typescript' as lang — found: $(echo "$node_frameworks" | grep '|typescript|')"
else
    pass "No framework output uses deprecated 'typescript' lang label"
fi

if echo "$node_frameworks" | grep -q '|javascript|'; then
    fail "Framework output must not use 'javascript' as lang — found: $(echo "$node_frameworks" | grep '|javascript|')"
else
    pass "No framework output uses deprecated 'javascript' lang label"
fi

# =============================================================================
# Node.js framework lang labels for TypeScript project
# =============================================================================
echo "=== detect_frameworks: Next.js lang label is 'node' even for TypeScript project ==="

NEXT_TS_DIR=$(make_proj "next_ts")
cat > "$NEXT_TS_DIR/package.json" << 'EOF'
{
  "name": "next-ts-app",
  "dependencies": {
    "next": "^13.0.0",
    "react": "^18.0.0"
  },
  "devDependencies": {
    "typescript": "^5.0.0"
  }
}
EOF
echo '{"compilerOptions":{}}' > "$NEXT_TS_DIR/tsconfig.json"

next_ts_fw=$(detect_frameworks "$NEXT_TS_DIR")
if echo "$next_ts_fw" | grep "^next.js|" | grep -q "|node|"; then
    pass "next.js framework uses 'node' lang label even when tsconfig.json present"
else
    actual=$(echo "$next_ts_fw" | grep "^next.js|" | cut -d'|' -f2 || echo "<not detected>")
    fail "next.js framework lang label should be 'node', got '${actual}'"
fi

# =============================================================================
# _DETECT_EXCLUDE_DIRS — dots must be escaped in ERE patterns
# =============================================================================
echo "=== _DETECT_EXCLUDE_DIRS: dot-prefixed dirs excluded, but not non-dot variants ==="

# Verify .git is in the exclusion pattern with escaped dot
if echo "$_DETECT_EXCLUDE_DIRS" | grep -q '\\\.git'; then
    pass "_DETECT_EXCLUDE_DIRS contains escaped \.git (not literal .git)"
else
    fail "_DETECT_EXCLUDE_DIRS should contain \.git not .git: ${_DETECT_EXCLUDE_EXCLUDE_DIRS}"
fi

# Verify other dot-prefixed dirs are escaped
for escaped_dir in '\\\.dart_tool' '\\\.next' '\\\.bundle' '\\\.gradle' '\\\.build' '\\\.pub-cache' '\\\.cargo'; do
    if echo "$_DETECT_EXCLUDE_DIRS" | grep -q "$escaped_dir"; then
        pass "_DETECT_EXCLUDE_DIRS escapes ${escaped_dir}"
    else
        fail "_DETECT_EXCLUDE_DIRS missing escaped ${escaped_dir}"
    fi
done

# =============================================================================
# Confidence sort order — high before medium before low
# =============================================================================
echo "=== detect_languages: confidence sort order (high first) ==="

# Build a mixed project: TypeScript (high) + Ruby manifest only (medium)
SORT_DIR=$(make_proj "sort_order")
echo '{"name":"app"}' > "$SORT_DIR/package.json"
echo '{"compilerOptions":{}}' > "$SORT_DIR/tsconfig.json"
touch "$SORT_DIR/index.ts" "$SORT_DIR/app.ts" "$SORT_DIR/utils.ts"
touch "$SORT_DIR/Gemfile"   # Ruby manifest but no .rb files → medium confidence

sorted_langs=$(detect_languages "$SORT_DIR")

# Extract confidence levels in output order
confidences=$(echo "$sorted_langs" | cut -d'|' -f2)

# 'high' must not appear after 'medium' or 'low'
first_medium_or_low=$(echo "$confidences" | grep -n 'medium\|low' | head -1 | cut -d: -f1 || echo "")
first_high=$(echo "$confidences" | grep -n 'high' | head -1 | cut -d: -f1 || echo "")

if [[ -z "$first_high" ]]; then
    pass "No high-confidence languages — sort order trivially correct"
elif [[ -z "$first_medium_or_low" ]]; then
    pass "Only high-confidence languages present — sort order correct"
elif [[ "$first_high" -lt "$first_medium_or_low" ]]; then
    pass "High-confidence language appears before medium/low in output"
else
    fail "Sort order wrong: high-confidence appears at line ${first_high}, medium/low at line ${first_medium_or_low}"
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
