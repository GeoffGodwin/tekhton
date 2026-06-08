#!/usr/bin/env bash
# TIMEOUT_SECS=30
# =============================================================================
# test_coder_declared_files.sh — coverage gap: _coder_declared_files
# in lib/finalize_commit_staging.sh.
#
# The REVIEWER_REPORT identified that the `|| return 0` branch on the grep/
# sed/sort pipeline inside _coder_declared_files (line 28-32) is untested.
# This branch fires when the "## Files Modified" section exists but contains
# NO backtick-delimited paths — for example, a skeleton CODER_SUMMARY.md
# or one where all entries are filtered out by the exclude patterns.
#
# Tests:
#   1. File absent → empty output (the `[ -f ]` guard with `|| return 0`).
#   2. File present, no ## Files section → empty output.
#   3. File present, section exists but no backtick paths → empty output
#      (the pipeline `|| return 0` branch).
#   4. File present, valid paths → paths echoed one per line.
#   5. File present, "## Files Created" variant header is also matched.
#   6. Paths matching N/A, None, (fill are excluded.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0 FAIL=0
_pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Run _coder_declared_files in a subshell so CODER_SUMMARY_FILE is isolated.
_declared() {
    local f="$1"
    (
        export CODER_SUMMARY_FILE="$f"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/finalize_commit_staging.sh"
        _coder_declared_files
    )
}

# ---------------------------------------------------------------------------
# 1. File absent → empty output.
# ---------------------------------------------------------------------------
result=$(_declared "${TMP}/does_not_exist.md")
if [[ -z "$result" ]]; then
    _pass "1: absent CODER_SUMMARY_FILE → empty output"
else
    _fail "1: expected empty, got '$result'"
fi

# ---------------------------------------------------------------------------
# 2. File present, no ## Files section → empty output.
# ---------------------------------------------------------------------------
cat > "${TMP}/no_section.md" <<'EOF'
## Overview
Some text here.

## Not a files section
More text.
EOF
result=$(_declared "${TMP}/no_section.md")
if [[ -z "$result" ]]; then
    _pass "2: no files section → empty output"
else
    _fail "2: expected empty, got '$result'"
fi

# ---------------------------------------------------------------------------
# 3. File present, ## Files Modified section has prose but no backticks.
#    This is the `|| return 0` branch — the grep pipeline finds no matches
#    but must not cause a non-zero exit from the function.
# ---------------------------------------------------------------------------
cat > "${TMP}/no_backticks.md" <<'EOF'
## Files Modified

No backtick-delimited paths here. Just prose.
All good. Nothing to declare.

## Other section
EOF
result=$(_declared "${TMP}/no_backticks.md")
if [[ -z "$result" ]]; then
    _pass "3: section exists but no backtick paths → empty output (|| return 0 fires)"
else
    _fail "3: expected empty, got '$result'"
fi

# ---------------------------------------------------------------------------
# 4. File present, valid paths are echoed one per line, sorted and deduped.
# ---------------------------------------------------------------------------
cat > "${TMP}/with_paths.md" <<'EOF'
## Files Modified

- \`internal/provider/tools/canonical.go\` — six canonical tools
- \`internal/provider/toolschema.go\` — ToolSchema definition
- \`internal/provider/tools/canonical.go\` — duplicate (should dedup)

## Not Modified
- \`unrelated_section.go\` — should not appear
EOF
result=$(_declared "${TMP}/with_paths.md")
count=$(echo "$result" | grep -c . || true)
if [[ "$count" -eq 2 ]]; then
    _pass "4a: 2 unique paths from 3 entries (duplicate removed)"
else
    _fail "4a: expected 2 paths, got $count: '$result'"
fi
if echo "$result" | grep -q "internal/provider/toolschema.go"; then
    _pass "4b: toolschema.go is in output"
else
    _fail "4b: toolschema.go not found in output: '$result'"
fi
if echo "$result" | grep -q "internal/provider/tools/canonical.go"; then
    _pass "4c: canonical.go is in output"
else
    _fail "4c: canonical.go not found in output: '$result'"
fi
# The "unrelated_section.go" path is AFTER a new ## section, so must not appear.
if echo "$result" | grep -q "unrelated_section.go"; then
    _fail "4d: path from a later section leaked into output"
else
    _pass "4d: path from later section correctly excluded"
fi

# ---------------------------------------------------------------------------
# 5. "## Files Created" header variant is also matched.
# ---------------------------------------------------------------------------
cat > "${TMP}/files_created.md" <<'EOF'
## Files Created

- \`cmd/tekhton/main.go\` — entry point
EOF
result=$(_declared "${TMP}/files_created.md")
if echo "$result" | grep -q "cmd/tekhton/main.go"; then
    _pass "5: ## Files Created variant is matched"
else
    _fail "5: ## Files Created not matched; got '$result'"
fi

# ---------------------------------------------------------------------------
# 6. Filtered entries (N/A, None, (fill) do not appear in output.
# ---------------------------------------------------------------------------
cat > "${TMP}/filtered.md" <<'EOF'
## Files Modified

- \`(fill in path)\`
- \`N/A\`
- \`None\`
- \`cmd/tekhton/run.go\` — real path
EOF
result=$(_declared "${TMP}/filtered.md")
if echo "$result" | grep -qE '^\(fill|^N/A$|^None$'; then
    _fail "6: filtered entries should not appear; got '$result'"
else
    _pass "6: N/A, None, (fill entries are excluded"
fi
if echo "$result" | grep -q "cmd/tekhton/run.go"; then
    _pass "6b: real path survives the filter"
else
    _fail "6b: real path missing from output: '$result'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "──────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "──────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
