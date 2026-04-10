#!/usr/bin/env bash
# Test: _ensure_init_gitignore() in lib/init_helpers.sh
# Verifies tech-stack, sensitive-file, and Tekhton runtime patterns
# are written correctly by the --init gitignore generator.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging / output functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# shellcheck source=../lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"

# Re-stub after common.sh (it may redefine these)
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# init_helpers.sh depends on these common.sh-defined globals/functions
# that are set up during a real run.  We source it directly here.
# shellcheck source=../lib/init_helpers.sh
source "${TEKHTON_HOME}/lib/init_helpers.sh"

# =============================================================================
# Section 1: Syntax / static analysis
# =============================================================================

if bash -n "${TEKHTON_HOME}/lib/init_helpers.sh" 2>/dev/null; then
    pass "bash -n lib/init_helpers.sh passes"
else
    fail "bash -n lib/init_helpers.sh: syntax error"
fi

if command -v shellcheck &>/dev/null; then
    if shellcheck "${TEKHTON_HOME}/lib/init_helpers.sh" 2>/dev/null; then
        pass "shellcheck lib/init_helpers.sh passes"
    else
        fail "shellcheck lib/init_helpers.sh: warnings or errors"
    fi
else
    echo "  SKIP: shellcheck not installed"
fi

# =============================================================================
# Section 2: Python — tech-stack patterns written
# =============================================================================

PROJ_PY="${TEST_TMPDIR}/proj_python"
mkdir -p "$PROJ_PY"

_ensure_init_gitignore "$PROJ_PY" "python|low|CLAUDE.md"

for pat in "__pycache__/" "*.pyc" ".venv/" "venv/" ".pytest_cache/"; do
    if grep -qF "$pat" "${PROJ_PY}/.gitignore"; then
        pass "python: '$pat' present"
    else
        fail "python: '$pat' missing"
    fi
done

# =============================================================================
# Section 3: Node / TypeScript — tech-stack patterns written
# =============================================================================

PROJ_TS="${TEST_TMPDIR}/proj_typescript"
mkdir -p "$PROJ_TS"

_ensure_init_gitignore "$PROJ_TS" "typescript|high|package.json"

for pat in "node_modules/" "dist/" ".next/"; do
    if grep -qF "$pat" "${PROJ_TS}/.gitignore"; then
        pass "typescript: '$pat' present"
    else
        fail "typescript: '$pat' missing"
    fi
done

# =============================================================================
# Section 4: Rust — tech-stack patterns written
# =============================================================================

PROJ_RS="${TEST_TMPDIR}/proj_rust"
mkdir -p "$PROJ_RS"

_ensure_init_gitignore "$PROJ_RS" "rust|high|Cargo.toml"

if grep -qF "target/" "${PROJ_RS}/.gitignore"; then
    pass "rust: 'target/' present"
else
    fail "rust: 'target/' missing"
fi

# =============================================================================
# Section 5: Go — tech-stack patterns written
# =============================================================================

PROJ_GO="${TEST_TMPDIR}/proj_go"
mkdir -p "$PROJ_GO"

_ensure_init_gitignore "$PROJ_GO" "go|high|go.mod"

if grep -qF "vendor/" "${PROJ_GO}/.gitignore"; then
    pass "go: 'vendor/' present"
else
    fail "go: 'vendor/' missing"
fi

# =============================================================================
# Section 6: Sensitive files always added
# =============================================================================

PROJ_SENS="${TEST_TMPDIR}/proj_sensitive"
mkdir -p "$PROJ_SENS"

_ensure_init_gitignore "$PROJ_SENS" ""

for pat in ".env" "*.pem" "*.key" "id_rsa" ".DS_Store"; do
    if grep -qF "$pat" "${PROJ_SENS}/.gitignore"; then
        pass "sensitive: '$pat' present even with no language"
    else
        fail "sensitive: '$pat' missing (empty languages arg)"
    fi
done

# =============================================================================
# Section 7: Tekhton runtime entries delegated via _ensure_gitignore_entries
# =============================================================================

if grep -qF ".claude/CHECKPOINT_META.json" "${PROJ_SENS}/.gitignore"; then
    pass "Tekhton runtime: .claude/CHECKPOINT_META.json present"
else
    fail "Tekhton runtime: .claude/CHECKPOINT_META.json missing"
fi

if grep -qF ".claude/dashboard/data/" "${PROJ_SENS}/.gitignore"; then
    pass "Tekhton runtime: .claude/dashboard/data/ present"
else
    fail "Tekhton runtime: .claude/dashboard/data/ missing"
fi

# =============================================================================
# Section 8: Multiple languages in one call
# =============================================================================

PROJ_MULTI="${TEST_TMPDIR}/proj_multi"
mkdir -p "$PROJ_MULTI"

langs_multi="$(printf 'python|high|pyproject.toml\ntypescript|high|package.json')"
_ensure_init_gitignore "$PROJ_MULTI" "$langs_multi"

for pat in "__pycache__/" "node_modules/" ".env"; do
    if grep -qF "$pat" "${PROJ_MULTI}/.gitignore"; then
        pass "multi-lang: '$pat' present"
    else
        fail "multi-lang: '$pat' missing"
    fi
done

# =============================================================================
# Section 9: Idempotent — calling twice produces no duplicates
# =============================================================================

_ensure_init_gitignore "$PROJ_MULTI" "$langs_multi"

for pat in "__pycache__/" "node_modules/" ".env" ".claude/PIPELINE.lock"; do
    count=$(grep -cF "$pat" "${PROJ_MULTI}/.gitignore" || true)
    if [[ "$count" -eq 1 ]]; then
        pass "idempotent: '$pat' appears exactly once"
    else
        fail "idempotent: '$pat' appears $count times (expected 1)"
    fi
done

# =============================================================================
# Section 10: Existing .gitignore content is preserved
# =============================================================================

PROJ_KEEP="${TEST_TMPDIR}/proj_keep_existing"
mkdir -p "$PROJ_KEEP"

cat > "${PROJ_KEEP}/.gitignore" << 'EOF'
# My custom patterns
*.log
tmp/
EOF

_ensure_init_gitignore "$PROJ_KEEP" "python|low|CLAUDE.md"

# Pre-existing lines must still be there
if grep -qF "*.log" "${PROJ_KEEP}/.gitignore" && grep -qF "tmp/" "${PROJ_KEEP}/.gitignore"; then
    pass "existing .gitignore content preserved after _ensure_init_gitignore"
else
    fail "existing content was lost or overwritten"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
