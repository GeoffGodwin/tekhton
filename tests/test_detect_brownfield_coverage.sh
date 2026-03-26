#!/usr/bin/env bash
# Test: Milestone 12 — Coverage gaps
#   - Ansible detection (ansible.cfg / playbooks/ / roles/)
#   - pnpm workspace enumeration
#   - Nx workspace enumeration
#   - _format_ci_section field rendering (deploy-target misalignment)
#   - _generate_smart_config doc-quality model selection
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_VERSION="${TEKHTON_VERSION:-0.0.0}"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions (required by sourced libs)
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source all needed detection libraries
# shellcheck source=../lib/detect_infrastructure.sh
source "${TEKHTON_HOME}/lib/detect_infrastructure.sh"
# shellcheck source=../lib/detect_workspaces.sh
source "${TEKHTON_HOME}/lib/detect_workspaces.sh"
# shellcheck source=../lib/detect_ci.sh
source "${TEKHTON_HOME}/lib/detect_ci.sh"
# shellcheck source=../lib/detect_report.sh
source "${TEKHTON_HOME}/lib/detect_report.sh"
# shellcheck source=../lib/init_config.sh
source "${TEKHTON_HOME}/lib/init_config.sh"

make_proj() {
    local name="$1"
    local dir="${TEST_TMPDIR}/${name}"
    mkdir -p "$dir"
    echo "$dir"
}

# Helper: count matching lines without failing on zero matches
count_lines() {
    local pattern="$1"
    local text="$2"
    echo "$text" | grep -c "$pattern" || true
}

# =============================================================================
# detect_infrastructure — Ansible: ansible.cfg
# =============================================================================
echo "=== detect_infrastructure: Ansible via ansible.cfg ==="

ANSIBLE_CFG=$(make_proj "ansible_cfg")
touch "$ANSIBLE_CFG/ansible.cfg"

infra_output=$(detect_infrastructure "$ANSIBLE_CFG")
if echo "$infra_output" | grep -q "ansible|.|unknown|high"; then
    pass "Ansible detected from ansible.cfg with high confidence"
else
    fail "Ansible NOT detected from ansible.cfg: $infra_output"
fi

# =============================================================================
# detect_infrastructure — Ansible: playbooks/ directory
# =============================================================================
echo "=== detect_infrastructure: Ansible via playbooks/ ==="

ANSIBLE_PB=$(make_proj "ansible_playbooks")
mkdir -p "$ANSIBLE_PB/playbooks"

infra_output=$(detect_infrastructure "$ANSIBLE_PB")
if echo "$infra_output" | grep -q "ansible|.|unknown|medium"; then
    pass "Ansible detected from playbooks/ directory with medium confidence"
else
    fail "Ansible NOT detected from playbooks/: $infra_output"
fi

# =============================================================================
# detect_infrastructure — Ansible: roles/ directory
# =============================================================================
echo "=== detect_infrastructure: Ansible via roles/ ==="

ANSIBLE_ROLES=$(make_proj "ansible_roles")
mkdir -p "$ANSIBLE_ROLES/roles"

infra_output=$(detect_infrastructure "$ANSIBLE_ROLES")
if echo "$infra_output" | grep -q "ansible|.|unknown|medium"; then
    pass "Ansible detected from roles/ directory with medium confidence"
else
    fail "Ansible NOT detected from roles/: $infra_output"
fi

# =============================================================================
# detect_infrastructure — Ansible: ansible.cfg triggers early return (high conf)
#   when both ansible.cfg and playbooks/ are present, only one line is emitted
# =============================================================================
echo "=== detect_infrastructure: Ansible cfg + playbooks → single high-conf line ==="

ANSIBLE_BOTH=$(make_proj "ansible_both")
touch "$ANSIBLE_BOTH/ansible.cfg"
mkdir -p "$ANSIBLE_BOTH/playbooks"

infra_output=$(detect_infrastructure "$ANSIBLE_BOTH")
# ansible.cfg returns early with high confidence
if echo "$infra_output" | grep -q "ansible|.|unknown|high"; then
    pass "Ansible: ansible.cfg present → high confidence output"
else
    fail "Ansible: expected high confidence line: $infra_output"
fi
# Only one ansible line should be emitted (early return after ansible.cfg)
line_count=$(count_lines "^ansible|" "$infra_output")
if [[ "$line_count" -eq 1 ]]; then
    pass "Ansible: exactly one line emitted when ansible.cfg present"
else
    fail "Ansible: expected 1 line, got $line_count: $infra_output"
fi

# =============================================================================
# detect_infrastructure — Ansible: no match → no output
# =============================================================================
echo "=== detect_infrastructure: Ansible: no ansible files ==="

NO_ANSIBLE=$(make_proj "no_ansible")
touch "$NO_ANSIBLE/main.py"

infra_output=$(detect_infrastructure "$NO_ANSIBLE")
ansible_lines=$(count_lines "^ansible|" "$infra_output")
if [[ "$ansible_lines" -eq 0 ]]; then
    pass "Ansible: no output for non-Ansible project"
else
    fail "Ansible: unexpected detection in non-Ansible project: $infra_output"
fi

# =============================================================================
# detect_workspaces — pnpm-workspace.yaml: type detection
# =============================================================================
echo "=== detect_workspaces: pnpm workspace type detection ==="

PNPM_WS=$(make_proj "pnpm_ws")
printf 'packages:\n  - "packages/*"\n' > "$PNPM_WS/pnpm-workspace.yaml"
mkdir -p "$PNPM_WS/packages/pkg-a" "$PNPM_WS/packages/pkg-b"

ws_output=$(detect_workspaces "$PNPM_WS")
if echo "$ws_output" | grep -q "pnpm-workspace|pnpm-workspace.yaml"; then
    pass "pnpm workspace detected from pnpm-workspace.yaml"
else
    fail "pnpm workspace NOT detected: $ws_output"
fi

# Subproject enumeration: created dirs should appear in output
if echo "$ws_output" | grep -q "packages/pkg-a"; then
    pass "pnpm workspace enumerates packages/pkg-a subproject"
else
    fail "pnpm workspace subproject packages/pkg-a not enumerated: $ws_output"
fi

if echo "$ws_output" | grep -q "packages/pkg-b"; then
    pass "pnpm workspace enumerates packages/pkg-b subproject"
else
    fail "pnpm workspace subproject packages/pkg-b not enumerated: $ws_output"
fi

# =============================================================================
# detect_workspaces — pnpm: multi-pattern awk limitation (single-pattern behavior)
#
# Bug: _enum_pnpm_workspaces awk modifies $0 via gsub(/^  - /,""), causing
# the exit condition (/^[^ ]/{exit}) to fire on the same record (the modified
# $0 no longer starts with a space). Only the first glob pattern is processed.
# =============================================================================
echo "=== detect_workspaces: pnpm multi-pattern awk limitation ==="

PNPM_MULTI=$(make_proj "pnpm_multi")
printf 'packages:\n  - "packages/*"\n  - "apps/*"\n' > "$PNPM_MULTI/pnpm-workspace.yaml"
mkdir -p "$PNPM_MULTI/packages/lib-a" "$PNPM_MULTI/apps/web-app"

ws_output=$(detect_workspaces "$PNPM_MULTI")
# Type detection still works
if echo "$ws_output" | grep -q "pnpm-workspace|pnpm-workspace.yaml"; then
    pass "pnpm multi-pattern: workspace type detected"
else
    fail "pnpm multi-pattern: workspace type NOT detected: $ws_output"
fi
# First pattern (packages/*) subprojects appear
if echo "$ws_output" | grep -q "packages/lib-a"; then
    pass "pnpm multi-pattern: first-pattern subproject (packages/lib-a) enumerated"
else
    fail "pnpm multi-pattern: first-pattern subproject NOT found: $ws_output"
fi
# Second pattern (apps/*) subprojects should be enumerated after awk fix
if echo "$ws_output" | grep -q "apps/web-app"; then
    pass "pnpm multi-pattern: second-pattern subproject (apps/web-app) enumerated (awk fixed)"
else
    fail "pnpm multi-pattern: second-pattern subproject NOT found (awk fix regression): $ws_output"
fi

# =============================================================================
# detect_workspaces — pnpm: no false positive for plain package.json
# =============================================================================
echo "=== detect_workspaces: pnpm no false positive ==="

NO_PNPM=$(make_proj "no_pnpm")
echo '{"name":"plain-package"}' > "$NO_PNPM/package.json"

ws_output=$(detect_workspaces "$NO_PNPM")
pnpm_lines=$(count_lines "^pnpm-workspace|" "$ws_output")
if [[ "$pnpm_lines" -eq 0 ]]; then
    pass "pnpm: no false positive for package.json without pnpm-workspace.yaml"
else
    fail "pnpm: false positive detected: $ws_output"
fi

# =============================================================================
# detect_workspaces — Nx workspace via nx.json + project.json
# =============================================================================
echo "=== detect_workspaces: Nx workspace ==="

NX_WS=$(make_proj "nx_ws")
echo '{"version":2}' > "$NX_WS/nx.json"
mkdir -p "$NX_WS/apps/my-app" "$NX_WS/libs/shared"
echo '{"name":"my-app","targets":{}}' > "$NX_WS/apps/my-app/project.json"
echo '{"name":"shared","targets":{}}' > "$NX_WS/libs/shared/project.json"

ws_output=$(detect_workspaces "$NX_WS")
if echo "$ws_output" | grep -q "nx|nx.json"; then
    pass "Nx workspace detected from nx.json"
else
    fail "Nx workspace NOT detected: $ws_output"
fi

if echo "$ws_output" | grep -q "apps/my-app"; then
    pass "Nx workspace enumerates apps/my-app project"
else
    fail "Nx workspace apps/my-app not enumerated: $ws_output"
fi

if echo "$ws_output" | grep -q "libs/shared"; then
    pass "Nx workspace enumerates libs/shared project"
else
    fail "Nx workspace libs/shared not enumerated: $ws_output"
fi

# =============================================================================
# detect_workspaces — Nx: no nx.json → no detection
# =============================================================================
echo "=== detect_workspaces: Nx no false positive ==="

NO_NX=$(make_proj "no_nx")
mkdir -p "$NO_NX/apps/my-app"
echo '{"name":"my-app"}' > "$NO_NX/apps/my-app/project.json"
# No nx.json at root → should not be detected as Nx workspace

ws_output=$(detect_workspaces "$NO_NX")
nx_lines=$(count_lines "^nx|" "$ws_output")
if [[ "$nx_lines" -eq 0 ]]; then
    pass "Nx: no detection without root nx.json"
else
    fail "Nx: false positive without nx.json: $ws_output"
fi

# =============================================================================
# _format_ci_section — field rendering and deploy-target misalignment
#
# Reviewer note: "github-actions|||||${deploy_target}|medium" places
# deploy_target in field 6 (_lang) instead of field 5 (deploy_tgt).
# Result: deploy target is silently dropped from the rendered table.
# Confirmed: the Deploy column shows '-' even when a target was detected.
# =============================================================================
echo "=== _format_ci_section: field rendering and deploy-target misalignment ==="

CI_FIELD_DIR=$(make_proj "ci_fields")
mkdir -p "$CI_FIELD_DIR/.github/workflows"
cat > "$CI_FIELD_DIR/.github/workflows/deploy.yml" << 'EOF'
name: Deploy
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: deploy to aws
        run: aws s3 sync ./dist s3://my-bucket
EOF

ci_section_output=$(_format_ci_section "$CI_FIELD_DIR" 2>/dev/null || true)

# Section must render when CI data is present
if echo "$ci_section_output" | grep -q "CI/CD Configuration"; then
    pass "_format_ci_section renders CI/CD section header"
else
    fail "_format_ci_section did not render section: $ci_section_output"
fi

# The table row for github-actions must appear
if echo "$ci_section_output" | grep -q "github-actions"; then
    pass "_format_ci_section renders github-actions row"
else
    fail "_format_ci_section github-actions row missing: $ci_section_output"
fi

# Inspect field placement in the rendered table row:
# Table format: | ci_sys | build | test | lint | deploy | conf |
# Fields (cut -d'|'): 1=empty, 2=ci_sys, 3=build, 4=test, 5=lint, 6=deploy, 7=conf
gha_row=$(echo "$ci_section_output" | grep "| github-actions" | head -1)
if [[ -n "$gha_row" ]]; then
    deploy_col=$(echo "$gha_row" | cut -d'|' -f6 | tr -d ' ')
    conf_col=$(echo "$gha_row" | cut -d'|' -f7 | tr -d ' ')
    # Field alignment was fixed: github-actions||||aws|medium now correctly places
    # deploy_target in field 5 (deploy column) and confidence in field 6
    if [[ "$deploy_col" == "aws" ]]; then
        pass "_format_ci_section: deploy column correctly shows 'aws'"
    else
        fail "_format_ci_section: deploy column expected 'aws', got: '$deploy_col'"
    fi
    if [[ "$conf_col" == "medium" ]]; then
        pass "_format_ci_section: confidence column renders 'medium' correctly"
    else
        fail "_format_ci_section: confidence column expected 'medium', got: '$conf_col'"
    fi
else
    fail "_format_ci_section: no github-actions row found in output"
fi

# =============================================================================
# _format_ci_section — normal command extraction (test/build/lint fields)
# =============================================================================
echo "=== _format_ci_section: test/build/lint field rendering ==="

CI_CMD_DIR=$(make_proj "ci_commands")
mkdir -p "$CI_CMD_DIR/.github/workflows"
cat > "$CI_CMD_DIR/.github/workflows/ci.yml" << 'EOF'
name: CI
on: push
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - run: npm run build
      - run: npm test
      - run: npm run lint
EOF

ci_cmd_output=$(_format_ci_section "$CI_CMD_DIR" 2>/dev/null || true)

if echo "$ci_cmd_output" | grep -q "CI/CD Configuration"; then
    pass "_format_ci_section renders section for build/test/lint workflow"
else
    fail "_format_ci_section did not render section: $ci_cmd_output"
fi

if echo "$ci_cmd_output" | grep -q "npm run build"; then
    pass "_format_ci_section: build command 'npm run build' rendered"
else
    fail "_format_ci_section: build command not rendered: $ci_cmd_output"
fi

if echo "$ci_cmd_output" | grep -q "npm test"; then
    pass "_format_ci_section: test command 'npm test' rendered"
else
    fail "_format_ci_section: test command not rendered: $ci_cmd_output"
fi

if echo "$ci_cmd_output" | grep -q "npm run lint"; then
    pass "_format_ci_section: lint command 'npm run lint' rendered"
else
    fail "_format_ci_section: lint command not rendered: $ci_cmd_output"
fi

# =============================================================================
# _generate_smart_config: doc quality model selection
# =============================================================================
echo "=== _generate_smart_config: doc quality model selection ==="

# Case 1: Low doc quality (<30) + large project (>100 files) → opus
DQ_LOW_DIR=$(make_proj "dq_low")
conf_low="$DQ_LOW_DIR/pipeline.conf"
_INIT_DOC_QUALITY="15|readme:0;contributing:0;api-docs:0;arch-docs:0;inline-docs:15"
export _INIT_DOC_QUALITY
_INIT_WORKSPACES=""
export _INIT_WORKSPACES
_INIT_SERVICES=""
export _INIT_SERVICES
_INIT_CI_CONFIG=""
export _INIT_CI_CONFIG
_INIT_WORKSPACE_SCOPE=""
export _INIT_WORKSPACE_SCOPE

_generate_smart_config "$DQ_LOW_DIR" "$conf_low" "" "" "" "150"
coder_model=$(grep "^CLAUDE_CODER_MODEL=" "$conf_low" | cut -d'"' -f2 || true)
if [[ "$coder_model" == "claude-opus-4-6" ]]; then
    pass "Doc quality < 30 + file_count 150 → coder model is opus"
else
    fail "Doc quality < 30 + file_count 150 → expected opus, got: $coder_model"
fi

# Case 2: High doc quality (>70) + medium project (51–200 files) → downgrade to sonnet
DQ_HIGH_DIR=$(make_proj "dq_high")
conf_high="$DQ_HIGH_DIR/pipeline.conf"
_INIT_DOC_QUALITY="82|readme:28;contributing:15;api-docs:14;arch-docs:18;inline-docs:7"
export _INIT_DOC_QUALITY

# file_count=100: >50 triggers opus base, then high doc quality downgrades to sonnet
_generate_smart_config "$DQ_HIGH_DIR" "$conf_high" "" "" "" "100"
coder_model=$(grep "^CLAUDE_CODER_MODEL=" "$conf_high" | cut -d'"' -f2 || true)
if [[ "$coder_model" == "claude-sonnet-4-6" ]]; then
    pass "Doc quality > 70 + file_count 100 (<=200) → coder model downgraded to sonnet"
else
    fail "Doc quality > 70 + file_count 100 → expected sonnet, got: $coder_model"
fi

# Case 3: High doc quality but very large project (>200 files) → stays opus (no downgrade)
DQ_HIGH_LARGE_DIR=$(make_proj "dq_high_large")
conf_high_large="$DQ_HIGH_LARGE_DIR/pipeline.conf"
_INIT_DOC_QUALITY="85|readme:28;contributing:15;api-docs:14;arch-docs:20;inline-docs:8"
export _INIT_DOC_QUALITY

_generate_smart_config "$DQ_HIGH_LARGE_DIR" "$conf_high_large" "" "" "" "250"
coder_model=$(grep "^CLAUDE_CODER_MODEL=" "$conf_high_large" | cut -d'"' -f2 || true)
if [[ "$coder_model" == "claude-opus-4-6" ]]; then
    pass "Doc quality > 70 but file_count 250 (>200) → stays opus (downgrade condition not met)"
else
    fail "Doc quality > 70 + file_count 250 → expected opus, got: $coder_model"
fi

# Case 4: Low doc quality but small project (<=100 files) → no opus upgrade
DQ_LOW_SMALL_DIR=$(make_proj "dq_low_small")
conf_low_small="$DQ_LOW_SMALL_DIR/pipeline.conf"
_INIT_DOC_QUALITY="10|readme:0;contributing:0;api-docs:0;arch-docs:0;inline-docs:10"
export _INIT_DOC_QUALITY

# file_count=50: ≤50 → base model is sonnet; low doc quality requires file_count>100 for upgrade
_generate_smart_config "$DQ_LOW_SMALL_DIR" "$conf_low_small" "" "" "" "50"
coder_model=$(grep "^CLAUDE_CODER_MODEL=" "$conf_low_small" | cut -d'"' -f2 || true)
if [[ "$coder_model" == "claude-sonnet-4-6" ]]; then
    pass "Doc quality < 30 + file_count 50 (<=100) → coder stays sonnet (no opus upgrade for small project)"
else
    fail "Doc quality < 30 + file_count 50 → expected sonnet, got: $coder_model"
fi

# Case 5: No _INIT_DOC_QUALITY set → model follows file count only
DQ_NONE_DIR=$(make_proj "dq_none")
conf_none="$DQ_NONE_DIR/pipeline.conf"
unset _INIT_DOC_QUALITY

# file_count=300 (>200) → opus from size alone
_generate_smart_config "$DQ_NONE_DIR" "$conf_none" "" "" "" "300"
coder_model=$(grep "^CLAUDE_CODER_MODEL=" "$conf_none" | cut -d'"' -f2 || true)
if [[ "$coder_model" == "claude-opus-4-6" ]]; then
    pass "No doc quality set, file_count 300 → opus from file count"
else
    fail "No doc quality, file_count 300 → expected opus, got: $coder_model"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== Milestone 12 Coverage Gap Tests ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
