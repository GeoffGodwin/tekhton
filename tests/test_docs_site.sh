#!/usr/bin/env bash
# Test: Milestone 18 — Documentation Site (MkDocs + GitHub Pages)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
echo "=== Required doc files exist ==="

REQUIRED_DOCS=(
    "docs/index.md"
    "docs/requirements.txt"
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
)

for doc in "${REQUIRED_DOCS[@]}"; do
    if [ -f "${TEKHTON_HOME}/${doc}" ]; then
        pass "${doc} exists"
    else
        fail "${doc} missing"
    fi
done

# ---------------------------------------------------------------------------
echo
echo "=== mkdocs.yml exists and has required fields ==="

MKDOCS="${TEKHTON_HOME}/mkdocs.yml"

if [ -f "$MKDOCS" ]; then
    pass "mkdocs.yml exists"
else
    fail "mkdocs.yml missing"
fi

if grep -q '^site_name:' "$MKDOCS"; then
    pass "mkdocs.yml has site_name"
else
    fail "mkdocs.yml missing site_name"
fi

if grep -q '^site_url:' "$MKDOCS"; then
    pass "mkdocs.yml has site_url"
else
    fail "mkdocs.yml missing site_url"
fi

if grep -q '^repo_url:' "$MKDOCS"; then
    pass "mkdocs.yml has repo_url"
else
    fail "mkdocs.yml missing repo_url"
fi

# ---------------------------------------------------------------------------
echo
echo "=== mkdocs.yml theme is Material ==="

if grep -q 'name: material' "$MKDOCS"; then
    pass "mkdocs.yml uses Material theme"
else
    fail "mkdocs.yml does not use Material theme"
fi

# ---------------------------------------------------------------------------
echo
echo "=== mkdocs.yml nav covers all top-level sections ==="

for section in "Getting Started" "Guides" "Reference" "Concepts" "Troubleshooting" "Changelog"; do
    if grep -q "$section" "$MKDOCS"; then
        pass "nav includes '${section}'"
    else
        fail "nav missing '${section}'"
    fi
done

# ---------------------------------------------------------------------------
echo
echo "=== mkdocs.yml nav references all expected doc files ==="

NAV_DOCS=(
    "getting-started/installation.md"
    "getting-started/first-project.md"
    "getting-started/first-milestone.md"
    "getting-started/understanding-output.md"
    "guides/greenfield.md"
    "guides/brownfield.md"
    "guides/monorepo.md"
    "guides/security-config.md"
    "guides/watchtower.md"
    "guides/planning.md"
    "reference/commands.md"
    "reference/configuration.md"
    "reference/stages.md"
    "reference/agents.md"
    "reference/template-variables.md"
    "concepts/pipeline-flow.md"
    "concepts/milestone-dag.md"
    "concepts/health-scoring.md"
    "concepts/context-budget.md"
    "troubleshooting/diagnose.md"
    "troubleshooting/common-errors.md"
    "troubleshooting/faq.md"
    "changelog.md"
)

for doc in "${NAV_DOCS[@]}"; do
    if grep -q "$doc" "$MKDOCS"; then
        pass "nav references ${doc}"
    else
        fail "nav missing ${doc}"
    fi
done

# ---------------------------------------------------------------------------
echo
echo "=== mkdocs.yml markdown extensions ==="

for ext in "admonition" "pymdownx.superfences" "pymdownx.tabbed" "pymdownx.highlight" "toc"; do
    if grep -q "$ext" "$MKDOCS"; then
        pass "markdown_extensions includes ${ext}"
    else
        fail "markdown_extensions missing ${ext}"
    fi
done

# ---------------------------------------------------------------------------
echo
echo "=== docs/requirements.txt contains mkdocs-material ==="

REQS="${TEKHTON_HOME}/docs/requirements.txt"
if [ -f "$REQS" ]; then
    if grep -q 'mkdocs-material' "$REQS"; then
        pass "docs/requirements.txt contains mkdocs-material"
    else
        fail "docs/requirements.txt missing mkdocs-material"
    fi
else
    fail "docs/requirements.txt missing"
fi

# ---------------------------------------------------------------------------
echo
echo "=== GitHub Actions workflow file exists and is valid ==="

WORKFLOW="${TEKHTON_HOME}/.github/workflows/docs.yml"
if [ -f "$WORKFLOW" ]; then
    pass ".github/workflows/docs.yml exists"
else
    fail ".github/workflows/docs.yml missing"
fi

if grep -q 'mkdocs build' "$WORKFLOW"; then
    pass "workflow runs mkdocs build"
else
    fail "workflow missing 'mkdocs build' step"
fi

if grep -q 'deploy-pages' "$WORKFLOW"; then
    pass "workflow uses deploy-pages action"
else
    fail "workflow missing deploy-pages action"
fi

if grep -q "branches: \[main\]" "$WORKFLOW"; then
    pass "workflow triggers on push to main"
else
    fail "workflow does not trigger on push to main"
fi

if grep -q "workflow_dispatch" "$WORKFLOW"; then
    pass "workflow supports manual dispatch"
else
    fail "workflow missing manual dispatch trigger"
fi

if grep -q "release:" "$WORKFLOW"; then
    pass "workflow triggers on release"
else
    fail "workflow missing release trigger"
fi

# Verify required Pages permissions
if grep -q 'pages: write' "$WORKFLOW"; then
    pass "workflow has pages: write permission"
else
    fail "workflow missing pages: write permission"
fi

if grep -q 'id-token: write' "$WORKFLOW"; then
    pass "workflow has id-token: write permission"
else
    fail "workflow missing id-token: write permission"
fi

# ---------------------------------------------------------------------------
echo
echo "=== .gitignore contains site/ ==="

GITIGNORE="${TEKHTON_HOME}/.gitignore"
if grep -q '^site/$' "$GITIGNORE"; then
    pass ".gitignore contains site/"
else
    fail ".gitignore missing site/"
fi

# ---------------------------------------------------------------------------
echo
echo "=== tekhton.sh --docs flag ==="

TEKHTON="${TEKHTON_HOME}/tekhton.sh"

if grep -q '"\-\-docs"' "$TEKHTON"; then
    pass "tekhton.sh handles --docs flag"
else
    fail "tekhton.sh missing --docs flag handler"
fi

if grep -q 'xdg-open' "$TEKHTON"; then
    pass "tekhton.sh uses xdg-open for --docs"
else
    fail "tekhton.sh missing xdg-open for --docs"
fi

# The --docs URL should point to the GitHub Pages site
if grep -q 'geoffgodwin.github.io/tekhton' "$TEKHTON"; then
    pass "tekhton.sh --docs URL points to GitHub Pages site"
else
    fail "tekhton.sh --docs URL does not reference geoffgodwin.github.io/tekhton"
fi

# --docs should appear in help text
if grep '\-\-docs' "$TEKHTON" | grep -q 'documentation'; then
    pass "tekhton.sh --docs appears in help text"
else
    fail "tekhton.sh --docs missing from help text"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Each doc file has a non-empty # heading ==="

for doc in "${REQUIRED_DOCS[@]}"; do
    filepath="${TEKHTON_HOME}/${doc}"
    [ -f "$filepath" ] || continue
    # Skip requirements.txt (not markdown)
    [[ "$doc" == *.txt ]] && continue

    if grep -q '^# ' "$filepath"; then
        pass "${doc} has a top-level heading"
    else
        fail "${doc} missing top-level # heading"
    fi
done

# ---------------------------------------------------------------------------
echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
