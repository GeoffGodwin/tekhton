#!/usr/bin/env bash
# =============================================================================
# test_docs_structure.sh — Verify M18 (Documentation Site) deliverables exist
#                          and are structurally valid.
#
# Tests:
#   1. All required docs/ files from mkdocs.yml nav are present
#   2. mkdocs.yml has required Material theme features
#   3. docs/requirements.txt includes mkdocs-material
#   4. .github/workflows/docs.yml has the required workflow steps
#   5. tekhton.sh --docs exits 0 and prints the GitHub Pages URL
#   6. docs/assets/screenshots/ directory exists
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Suite 1: Required docs/ files referenced in mkdocs.yml nav
# ---------------------------------------------------------------------------
echo "Suite 1: Required docs files"

required_files=(
    "docs/index.md"
    "docs/getting-started/installation.md"
    "docs/getting-started/first-project.md"
    "docs/getting-started/first-milestone.md"
    "docs/getting-started/understanding-output.md"
    "docs/guides/greenfield.md"
    "docs/guides/brownfield.md"
    "docs/guides/monorepo.md"
    "docs/guides/security-config.md"
    "docs/guides/watchtower.md"
    "docs/guides/planning.md"
    "docs/reference/commands.md"
    "docs/reference/configuration.md"
    "docs/reference/stages.md"
    "docs/reference/agents.md"
    "docs/reference/template-variables.md"
    "docs/concepts/pipeline-flow.md"
    "docs/concepts/milestone-dag.md"
    "docs/concepts/health-scoring.md"
    "docs/concepts/context-budget.md"
    "docs/troubleshooting/diagnose.md"
    "docs/troubleshooting/common-errors.md"
    "docs/troubleshooting/faq.md"
    "docs/changelog.md"
    "docs/requirements.txt"
)

for f in "${required_files[@]}"; do
    if [[ -f "${TEKHTON_HOME}/${f}" ]]; then
        pass "${f} exists"
    else
        fail "${f} MISSING"
    fi
done

# ---------------------------------------------------------------------------
# Suite 2: docs/assets/screenshots/ directory exists (Watch For)
# ---------------------------------------------------------------------------
echo "Suite 2: docs/assets/screenshots directory"

if [[ -d "${TEKHTON_HOME}/docs/assets/screenshots" ]]; then
    pass "docs/assets/screenshots/ directory exists"
else
    fail "docs/assets/screenshots/ directory MISSING"
fi

# ---------------------------------------------------------------------------
# Suite 3: mkdocs.yml structural validation
# ---------------------------------------------------------------------------
echo "Suite 3: mkdocs.yml structure"

MKDOCS="${TEKHTON_HOME}/mkdocs.yml"

if grep -q "name: material" "$MKDOCS"; then
    pass "mkdocs.yml uses Material theme"
else
    fail "mkdocs.yml missing Material theme"
fi

if grep -q "content.code.copy" "$MKDOCS"; then
    pass "mkdocs.yml has content.code.copy feature"
else
    fail "mkdocs.yml missing content.code.copy feature"
fi

if grep -q "navigation.tabs" "$MKDOCS"; then
    pass "mkdocs.yml has navigation.tabs feature"
else
    fail "mkdocs.yml missing navigation.tabs feature"
fi

# Dark/light toggle requires both palette entries
dark_count=$(grep -c "scheme:" "$MKDOCS" || true)
if [[ "$dark_count" -ge 2 ]]; then
    pass "mkdocs.yml has dark/light palette toggle ($dark_count schemes)"
else
    fail "mkdocs.yml missing dark/light palette toggle (found $dark_count scheme entries)"
fi

if grep -q "toc:" "$MKDOCS" && grep -q "permalink:" "$MKDOCS"; then
    pass "mkdocs.yml has toc with permalink"
else
    fail "mkdocs.yml missing toc permalink config"
fi

if grep -q "site_url:" "$MKDOCS"; then
    pass "mkdocs.yml has site_url"
else
    fail "mkdocs.yml missing site_url"
fi

if grep -q "repo_url:" "$MKDOCS"; then
    pass "mkdocs.yml has repo_url"
else
    fail "mkdocs.yml missing repo_url"
fi

# ---------------------------------------------------------------------------
# Suite 4: docs/requirements.txt has mkdocs-material
# ---------------------------------------------------------------------------
echo "Suite 4: docs/requirements.txt"

REQS="${TEKHTON_HOME}/docs/requirements.txt"
if grep -qi "mkdocs-material" "$REQS"; then
    pass "docs/requirements.txt includes mkdocs-material"
else
    fail "docs/requirements.txt missing mkdocs-material"
fi

# Verify it's separate from tools/requirements.txt
if [[ -f "${TEKHTON_HOME}/tools/requirements.txt" ]]; then
    if grep -qi "mkdocs-material" "${TEKHTON_HOME}/tools/requirements.txt"; then
        fail "mkdocs-material found in tools/requirements.txt (should only be in docs/requirements.txt)"
    else
        pass "mkdocs-material not in tools/requirements.txt (correct separation)"
    fi
else
    pass "tools/requirements.txt not present (not a concern)"
fi

# ---------------------------------------------------------------------------
# Suite 5: .github/workflows/docs.yml workflow structure
# ---------------------------------------------------------------------------
echo "Suite 5: GitHub Actions docs workflow"

WORKFLOW="${TEKHTON_HOME}/.github/workflows/docs.yml"
if [[ ! -f "$WORKFLOW" ]]; then
    fail ".github/workflows/docs.yml MISSING"
else
    pass ".github/workflows/docs.yml exists"

    if grep -q "actions/checkout" "$WORKFLOW"; then
        pass "workflow uses actions/checkout"
    else
        fail "workflow missing actions/checkout step"
    fi

    if grep -q "actions/setup-python" "$WORKFLOW"; then
        pass "workflow uses actions/setup-python"
    else
        fail "workflow missing actions/setup-python step"
    fi

    if grep -q "mkdocs build" "$WORKFLOW"; then
        pass "workflow runs mkdocs build"
    else
        fail "workflow missing mkdocs build step"
    fi

    if grep -q "actions/upload-pages-artifact" "$WORKFLOW"; then
        pass "workflow uses upload-pages-artifact"
    else
        fail "workflow missing upload-pages-artifact step"
    fi

    if grep -q "actions/deploy-pages" "$WORKFLOW"; then
        pass "workflow uses deploy-pages"
    else
        fail "workflow missing deploy-pages step"
    fi

    if grep -q "docs/requirements.txt" "$WORKFLOW"; then
        pass "workflow installs from docs/requirements.txt"
    else
        fail "workflow missing docs/requirements.txt install"
    fi

    # Workflow triggers on push to main, release, and manual dispatch
    if grep -q "workflow_dispatch" "$WORKFLOW"; then
        pass "workflow supports manual dispatch"
    else
        fail "workflow missing manual dispatch trigger"
    fi

    if grep -q "branches: \[main\]" "$WORKFLOW"; then
        pass "workflow triggers only on main branch"
    else
        fail "workflow missing branch filter for main"
    fi

    # Required permissions for GitHub Pages deployment
    if grep -q "pages: write" "$WORKFLOW"; then
        pass "workflow has pages: write permission"
    else
        fail "workflow missing pages: write permission"
    fi

    if grep -q "id-token: write" "$WORKFLOW"; then
        pass "workflow has id-token: write permission"
    else
        fail "workflow missing id-token: write permission"
    fi
fi

# ---------------------------------------------------------------------------
# Suite 6: tekhton.sh --docs flag
# ---------------------------------------------------------------------------
echo "Suite 6: tekhton.sh --docs flag"

# Verify --docs exits 0 and prints the GitHub Pages URL
# We stub xdg-open/open/start to avoid actually opening a browser
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Create a stub for xdg-open that does nothing
mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/xdg-open" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$TMPDIR/bin/xdg-open"

# tkhton.sh requires a PROJECT_DIR; run with minimal env from TMPDIR
output=$(PATH="$TMPDIR/bin:$PATH" bash "${TEKHTON_HOME}/tekhton.sh" --docs 2>&1 || true)
exit_code=$(PATH="$TMPDIR/bin:$PATH" bash "${TEKHTON_HOME}/tekhton.sh" --docs 2>&1; echo $?) || true
actual_exit=$(PATH="$TMPDIR/bin:$PATH" bash "${TEKHTON_HOME}/tekhton.sh" --docs > /dev/null 2>&1; echo $?)

if [[ "$actual_exit" -eq 0 ]]; then
    pass "--docs exits 0"
else
    fail "--docs exits non-zero (got $actual_exit)"
fi

docs_url="https://geoffgodwin.github.io/tekhton/"
if echo "$output" | grep -q "$docs_url"; then
    pass "--docs prints GitHub Pages URL"
else
    fail "--docs does not print GitHub Pages URL (output: $output)"
fi

# ---------------------------------------------------------------------------
# Suite 7: docs/index.md has required content
# ---------------------------------------------------------------------------
echo "Suite 7: docs/index.md content"

INDEX="${TEKHTON_HOME}/docs/index.md"
if grep -qi "One intent. Many hands." "$INDEX"; then
    pass "docs/index.md has tagline"
else
    fail "docs/index.md missing 'One intent. Many hands.' tagline"
fi

if grep -qi "getting.started\|getting started" "$INDEX"; then
    pass "docs/index.md references Getting Started"
else
    fail "docs/index.md missing Getting Started link"
fi

# ---------------------------------------------------------------------------
# Suite 8: docs/getting-started/installation.md platform coverage
# ---------------------------------------------------------------------------
echo "Suite 8: installation.md platform coverage"

INSTALL="${TEKHTON_HOME}/docs/getting-started/installation.md"
if grep -qi "macos\|mac os" "$INSTALL"; then
    pass "installation.md has macOS notes"
else
    fail "installation.md missing macOS notes"
fi

if grep -qi "windows\|wsl" "$INSTALL"; then
    pass "installation.md has Windows/WSL notes"
else
    fail "installation.md missing Windows/WSL notes"
fi

if grep -qi "linux" "$INSTALL"; then
    pass "installation.md has Linux notes"
else
    fail "installation.md missing Linux notes"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ $FAIL -eq 0 ]]
