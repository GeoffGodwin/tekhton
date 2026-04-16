#!/usr/bin/env bash
# Test: Documentation Strategy section is REQUIRED in all plan templates
# and the plan completeness checker recognizes it.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Create a temporary project dir
TEST_TMPDIR=$(mktemp -d)
export PROJECT_DIR="$TEST_TMPDIR"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }

DESIGN_FILE="${TEKHTON_DIR:-.tekhton}/DESIGN.md"

# Source plan.sh (constants) and plan_completeness.sh (check functions)
# shellcheck source=../lib/plan.sh
source "${TEKHTON_HOME}/lib/plan.sh"
# shellcheck source=../lib/plan_completeness.sh
source "${TEKHTON_HOME}/lib/plan_completeness.sh"

echo "=== All 7 templates have Documentation Strategy with REQUIRED marker ==="

TEMPLATES_DIR="${TEKHTON_HOME}/templates/plans"
for tmpl in cli-tool.md web-app.md api-service.md mobile-app.md web-game.md custom.md library.md; do
    tmpl_path="${TEMPLATES_DIR}/${tmpl}"
    if [[ ! -f "$tmpl_path" ]]; then
        fail "${tmpl}: file not found"
        continue
    fi

    # Check for ## Documentation Strategy heading
    if ! grep -q '^## Documentation Strategy' "$tmpl_path"; then
        fail "${tmpl}: missing ## Documentation Strategy section"
        continue
    fi

    # Check that REQUIRED marker follows the heading
    required=$(_extract_required_sections "$tmpl_path")
    if echo "$required" | grep -q "Documentation Strategy"; then
        pass "${tmpl}: Documentation Strategy is REQUIRED"
    else
        fail "${tmpl}: Documentation Strategy exists but is not marked REQUIRED"
    fi
done

echo
echo "=== Completeness checker flags missing Documentation Strategy ==="

# Use cli-tool.md as the template (it has Documentation Strategy as REQUIRED)
PLAN_TEMPLATE_FILE="${TEMPLATES_DIR}/cli-tool.md"  # used by plan_completeness.sh
export PLAN_TEMPLATE_FILE

# DESIGN.md without Documentation Strategy section
mkdir -p "${TEST_TMPDIR}/${TEKHTON_DIR:-.tekhton}"
cat > "${TEST_TMPDIR}/${DESIGN_FILE}" << 'DESIGN_EOF'
# Design Document — CLI Tool

## Developer Philosophy & Constraints
Fail fast and loud. Zero-config defaults.
### Principles
Unix philosophy: do one thing well.

## Project Overview
A CLI tool for managing cloud resources.
Built for DevOps engineers.
### Target Users
Site reliability engineers and platform teams.

## Tech Stack
### Language
Rust with clap for argument parsing.
### Testing
cargo test with integration test fixtures.

## Command Taxonomy
### init
Initializes a new project configuration.
### deploy
Deploys the current configuration to the cloud.

## Input Sources & Formats
### Config Files
TOML config at ~/.config/tool/config.toml.
### Environment Variables
TOOL_API_KEY for authentication.

## Output Formatting & Modes
### Human Mode
Colored output with progress bars.
### Machine Mode
JSON output with --format json flag.

## Configuration System
### Config File Format
TOML with global and local overrides.
### Discovery Order
CLI flags > env vars > local config > global config > defaults.

## Core Processing Logic
### Pipeline
Input validation → API call → transform → output.
### Parallelism
Uses rayon for parallel file processing.

## Config Architecture
### Defaults
All configurable values with sensible defaults.
### Override Hierarchy
CLI flags take highest precedence.

## Open Design Questions
### Plugin System
Unsure if needed — start without, evaluate after v1.0.
DESIGN_EOF

if check_design_completeness; then
    fail "DESIGN.md missing Documentation Strategy should fail completeness"
else
    pass "DESIGN.md missing Documentation Strategy fails completeness"
fi

if echo "$PLAN_INCOMPLETE_SECTIONS" | grep -q "Documentation Strategy"; then
    pass "Documentation Strategy listed as incomplete"
else
    fail "Documentation Strategy should be listed as incomplete"
fi

echo
echo "=== Completeness checker passes when Documentation Strategy is populated ==="

# Add a populated Documentation Strategy section
cat >> "${TEST_TMPDIR}/${DESIGN_FILE}" << 'DESIGN_EOF'

## Documentation Strategy
### Project Documentation
README.md at project root plus docs/ directory with user guides.
### Hosting
Documentation hosted on GitHub Pages using mdbook.
### Public Surface
CLI flags, config keys, and environment variables must be documented.
On every feature change, update the relevant docs/ page.
### Doc Freshness Policy
Warn-only — non-blocking finding during review.

## Versioning & Release Strategy
### Versioning Scheme
Semantic versioning (major.minor.patch).
### Bump Rules
Major for breaking changes, minor for new features, patch for bug fixes.
DESIGN_EOF

if check_design_completeness; then
    pass "DESIGN.md with populated Documentation Strategy passes completeness"
else
    fail "DESIGN.md with populated Documentation Strategy should pass"
fi

echo
echo "=== Config defaults: DOCS_* variables exist ==="

# Source config_defaults.sh to check variables are set
# Need stubs for _clamp_config_value and _clamp_config_float
_clamp_config_value() { :; }
_clamp_config_float() { :; }

# shellcheck source=../lib/config_defaults.sh
source "${TEKHTON_HOME}/lib/config_defaults.sh"

if [[ "${DOCS_ENFORCEMENT_ENABLED}" = "true" ]]; then
    pass "DOCS_ENFORCEMENT_ENABLED defaults to true"
else
    fail "DOCS_ENFORCEMENT_ENABLED should default to true, got '${DOCS_ENFORCEMENT_ENABLED}'"
fi

if [[ "${DOCS_STRICT_MODE}" = "false" ]]; then
    pass "DOCS_STRICT_MODE defaults to false"
else
    fail "DOCS_STRICT_MODE should default to false, got '${DOCS_STRICT_MODE}'"
fi

if [[ "${DOCS_DIRS}" = "docs/" ]]; then
    pass "DOCS_DIRS defaults to docs/"
else
    fail "DOCS_DIRS should default to 'docs/', got '${DOCS_DIRS}'"
fi

if [[ "${DOCS_README_FILE}" = "README.md" ]]; then
    pass "DOCS_README_FILE defaults to README.md"
else
    fail "DOCS_README_FILE should default to 'README.md', got '${DOCS_README_FILE}'"
fi

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
