#!/usr/bin/env bash
# Test: detect_ai_artifacts() — detection patterns, CLAUDE.md provenance,
#       .ai/ special case, and heuristic directive scanner (Milestone 11)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions required by the library
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source the detection library
# shellcheck source=../lib/detect_ai_artifacts.sh
source "${TEKHTON_HOME}/lib/detect_ai_artifacts.sh"

# Helper: fresh project directory
make_proj() {
    local name="$1"
    local dir="${TEST_TMPDIR}/${name}"
    mkdir -p "$dir"
    echo "$dir"
}

# =============================================================================
# detect_ai_artifacts — empty directory returns nothing
# =============================================================================
echo "=== detect_ai_artifacts: empty directory ==="

EMPTY_DIR=$(make_proj "empty")
result=$(detect_ai_artifacts "$EMPTY_DIR")
if [[ -z "$result" ]]; then
    pass "Empty project returns no artifacts"
else
    fail "Empty project should return no artifacts, got: $result"
fi

# =============================================================================
# detect_ai_artifacts — known AI directories (high confidence)
# =============================================================================
echo "=== detect_ai_artifacts: known AI directories ==="

for dir_tool in ".cursor|Cursor" ".cline|Cline" ".continue|Continue.dev" ".windsurf|Windsurf" ".roo|Roo Code"; do
    IFS='|' read -r dir_name tool_name <<< "$dir_tool"
    proj=$(make_proj "dir_${dir_name//\//_}")
    mkdir -p "${proj}/${dir_name}"
    result=$(detect_ai_artifacts "$proj")
    if echo "$result" | grep -q "^${tool_name}|"; then
        pass "${tool_name} detected via ${dir_name}/"
    else
        fail "${tool_name} NOT detected via ${dir_name}/: got: $result"
    fi
    if echo "$result" | grep "^${tool_name}|" | grep -q "|high$"; then
        pass "${tool_name} confidence is high"
    else
        fail "${tool_name} confidence not high: $result"
    fi
done

# GitHub Copilot (nested path)
COPILOT_DIR=$(make_proj "copilot")
mkdir -p "${COPILOT_DIR}/.github/copilot"
result=$(detect_ai_artifacts "$COPILOT_DIR")
if echo "$result" | grep -q "^GitHub Copilot|"; then
    pass "GitHub Copilot detected via .github/copilot/"
else
    fail "GitHub Copilot NOT detected: got: $result"
fi

# =============================================================================
# detect_ai_artifacts — known AI files (high confidence)
# =============================================================================
echo "=== detect_ai_artifacts: known AI files ==="

CURSOR_RULES_DIR=$(make_proj "cursorrules")
touch "${CURSOR_RULES_DIR}/.cursorrules"
result=$(detect_ai_artifacts "$CURSOR_RULES_DIR")
if echo "$result" | grep -q "^Cursor|.cursorrules|rules|high$"; then
    pass ".cursorrules detected as Cursor rules artifact"
else
    fail ".cursorrules not detected correctly: got: $result"
fi

WINDSURFRULES_DIR=$(make_proj "windsurfrules")
touch "${WINDSURFRULES_DIR}/.windsurfrules"
result=$(detect_ai_artifacts "$WINDSURFRULES_DIR")
if echo "$result" | grep -q "^Windsurf|.windsurfrules|rules|high$"; then
    pass ".windsurfrules detected as Windsurf rules artifact"
else
    fail ".windsurfrules not detected correctly: got: $result"
fi

ROOMODES_DIR=$(make_proj "roomodes")
touch "${ROOMODES_DIR}/.roomodes"
result=$(detect_ai_artifacts "$ROOMODES_DIR")
if echo "$result" | grep -q "^Roo Code|.roomodes|rules|high$"; then
    pass ".roomodes detected as Roo Code rules artifact"
else
    fail ".roomodes not detected correctly: got: $result"
fi

AICONFIG_DIR=$(make_proj "aiconfig")
touch "${AICONFIG_DIR}/.aiconfig"
result=$(detect_ai_artifacts "$AICONFIG_DIR")
if echo "$result" | grep -q "^Generic AI Config|.aiconfig|rules|high$"; then
    pass ".aiconfig detected as Generic AI Config"
else
    fail ".aiconfig not detected correctly: got: $result"
fi

# =============================================================================
# detect_ai_artifacts — .aider* glob patterns
# =============================================================================
echo "=== detect_ai_artifacts: .aider* glob patterns ==="

AIDER_DIR=$(make_proj "aider")
touch "${AIDER_DIR}/.aider.conf.yml"
result=$(detect_ai_artifacts "$AIDER_DIR")
if echo "$result" | grep -q "^aider|"; then
    pass ".aider.conf.yml detected as aider artifact"
else
    fail ".aider.conf.yml NOT detected: got: $result"
fi
if echo "$result" | grep "^aider|" | grep -q "|high$"; then
    pass "aider glob artifact confidence is high"
else
    fail "aider glob artifact not high confidence: $result"
fi

AIDER_DIR2=$(make_proj "aider2")
touch "${AIDER_DIR2}/.aiderignore"
result=$(detect_ai_artifacts "$AIDER_DIR2")
if echo "$result" | grep -q "^aider|"; then
    pass ".aiderignore detected as aider artifact"
else
    fail ".aiderignore NOT detected: got: $result"
fi

# =============================================================================
# detect_ai_artifacts — .ai/ special case (only when config files present)
# =============================================================================
echo "=== detect_ai_artifacts: .ai/ special case ==="

# .ai/ with only binary files — should NOT be detected
AI_EMPTY_DIR=$(make_proj "ai_empty")
mkdir -p "${AI_EMPTY_DIR}/.ai"
printf '\x00\x01\x02' > "${AI_EMPTY_DIR}/.ai/image.psd"
result=$(detect_ai_artifacts "$AI_EMPTY_DIR")
if echo "$result" | grep -q "^Generic AI Config|"; then
    fail ".ai/ with only binary files should NOT be detected as AI config"
else
    pass ".ai/ with only binary files is not reported as AI config"
fi

# .ai/ with a config JSON file — SHOULD be detected at medium confidence
AI_CONFIG_DIR=$(make_proj "ai_config")
mkdir -p "${AI_CONFIG_DIR}/.ai"
echo '{"model":"gpt-4"}' > "${AI_CONFIG_DIR}/.ai/config.json"
result=$(detect_ai_artifacts "$AI_CONFIG_DIR")
if echo "$result" | grep -q "^Generic AI Config|"; then
    pass ".ai/ with JSON config is detected as Generic AI Config"
else
    fail ".ai/ with JSON config NOT detected: got: $result"
fi
if echo "$result" | grep "^Generic AI Config|" | grep -q "|medium$"; then
    pass ".ai/ confidence is medium (ambiguous dir)"
else
    fail ".ai/ confidence should be medium: $result"
fi

# .ai/ with a markdown file — SHOULD be detected at medium confidence
AI_MD_DIR=$(make_proj "ai_md")
mkdir -p "${AI_MD_DIR}/.ai"
echo "# AI Rules" > "${AI_MD_DIR}/.ai/rules.md"
result=$(detect_ai_artifacts "$AI_MD_DIR")
if echo "$result" | grep -q "^Generic AI Config|"; then
    pass ".ai/ with markdown file is detected"
else
    fail ".ai/ with .md file NOT detected: got: $result"
fi

# =============================================================================
# detect_ai_artifacts — .claude/ granular detection (Tekhton vs Claude Code)
# =============================================================================
echo "=== detect_ai_artifacts: .claude/ granular detection ==="

# Tekhton: pipeline.conf
TEKHTON_CONF_DIR=$(make_proj "tekhton_conf")
mkdir -p "${TEKHTON_CONF_DIR}/.claude"
touch "${TEKHTON_CONF_DIR}/.claude/pipeline.conf"
result=$(detect_ai_artifacts "$TEKHTON_CONF_DIR")
if echo "$result" | grep -q "^Tekhton|.claude/pipeline.conf|config|high$"; then
    pass "Tekhton pipeline.conf detected correctly"
else
    fail "Tekhton pipeline.conf not detected: got: $result"
fi

# Tekhton: agents/ directory with .md files
TEKHTON_AGENTS_DIR=$(make_proj "tekhton_agents")
mkdir -p "${TEKHTON_AGENTS_DIR}/.claude/agents"
touch "${TEKHTON_AGENTS_DIR}/.claude/agents/coder.md"
result=$(detect_ai_artifacts "$TEKHTON_AGENTS_DIR")
if echo "$result" | grep -q "^Tekhton|.claude/agents/|agents|high$"; then
    pass "Tekhton .claude/agents/ detected correctly"
else
    fail "Tekhton .claude/agents/ not detected: got: $result"
fi

# Tekhton: agents/ dir exists but EMPTY — should not be reported
TEKHTON_AGENTS_EMPTY=$(make_proj "tekhton_agents_empty")
mkdir -p "${TEKHTON_AGENTS_EMPTY}/.claude/agents"
result=$(detect_ai_artifacts "$TEKHTON_AGENTS_EMPTY")
if echo "$result" | grep -q "^Tekhton|.claude/agents/"; then
    fail ".claude/agents/ with no .md files should NOT be reported"
else
    pass "Empty .claude/agents/ (no .md files) not falsely reported"
fi

# Tekhton: milestones/ directory
TEKHTON_MS_DIR=$(make_proj "tekhton_milestones")
mkdir -p "${TEKHTON_MS_DIR}/.claude/milestones"
result=$(detect_ai_artifacts "$TEKHTON_MS_DIR")
if echo "$result" | grep -q "^Tekhton|.claude/milestones/|config|high$"; then
    pass "Tekhton .claude/milestones/ detected correctly"
else
    fail "Tekhton .claude/milestones/ not detected: got: $result"
fi

# Claude Code: settings.json
CC_SETTINGS_DIR=$(make_proj "cc_settings")
mkdir -p "${CC_SETTINGS_DIR}/.claude"
echo '{}' > "${CC_SETTINGS_DIR}/.claude/settings.json"
result=$(detect_ai_artifacts "$CC_SETTINGS_DIR")
if echo "$result" | grep -q "^Claude Code|.claude/settings.json|config|high$"; then
    pass "Claude Code settings.json detected correctly"
else
    fail "Claude Code settings.json not detected: got: $result"
fi

# Claude Code: settings.local.json
CC_LOCAL_DIR=$(make_proj "cc_local")
mkdir -p "${CC_LOCAL_DIR}/.claude"
echo '{}' > "${CC_LOCAL_DIR}/.claude/settings.local.json"
result=$(detect_ai_artifacts "$CC_LOCAL_DIR")
if echo "$result" | grep -q "^Claude Code|.claude/settings.local.json|config|high$"; then
    pass "Claude Code settings.local.json detected correctly"
else
    fail "Claude Code settings.local.json not detected: got: $result"
fi

# Claude Code: commands/ directory with files
CC_CMD_DIR=$(make_proj "cc_commands")
mkdir -p "${CC_CMD_DIR}/.claude/commands"
touch "${CC_CMD_DIR}/.claude/commands/commit.md"
result=$(detect_ai_artifacts "$CC_CMD_DIR")
if echo "$result" | grep -q "^Claude Code|.claude/commands/|config|high$"; then
    pass "Claude Code .claude/commands/ detected correctly"
else
    fail "Claude Code .claude/commands/ not detected: got: $result"
fi

# Empty .claude/ dir — nothing should be reported
CC_EMPTY_DIR=$(make_proj "cc_empty")
mkdir -p "${CC_EMPTY_DIR}/.claude"
result=$(detect_ai_artifacts "$CC_EMPTY_DIR")
if echo "$result" | grep -q "^\(Tekhton\|Claude Code\)|\.claude"; then
    fail "Empty .claude/ dir should report no artifacts"
else
    pass "Empty .claude/ dir reports no artifacts"
fi

# =============================================================================
# detect_ai_artifacts — CLAUDE.md provenance check
# =============================================================================
echo "=== detect_ai_artifacts: CLAUDE.md provenance ==="

# CLAUDE.md with tekhton-managed marker → Tekhton, rules, high
TEKHTON_MD_DIR=$(make_proj "tekhton_md")
cat > "${TEKHTON_MD_DIR}/CLAUDE.md" << 'EOF'
<!-- tekhton-managed -->
# Project Configuration
EOF
result=$(detect_ai_artifacts "$TEKHTON_MD_DIR")
if echo "$result" | grep -q "^Tekhton|CLAUDE.md|rules|high$"; then
    pass "Tekhton-managed CLAUDE.md detected as Tekhton/rules/high"
else
    fail "Tekhton-managed CLAUDE.md not detected correctly: got: $result"
fi

# CLAUDE.md without marker → Claude/Tekhton, rules, medium
HAND_MD_DIR=$(make_proj "hand_md")
cat > "${HAND_MD_DIR}/CLAUDE.md" << 'EOF'
# My Project
Some project-specific instructions here.
EOF
result=$(detect_ai_artifacts "$HAND_MD_DIR")
if echo "$result" | grep -q "^Claude/Tekhton|CLAUDE.md|rules|medium$"; then
    pass "Hand-written CLAUDE.md detected as Claude/Tekhton/rules/medium"
else
    fail "Hand-written CLAUDE.md not detected correctly: got: $result"
fi

# No CLAUDE.md → not reported
NO_MD_DIR=$(make_proj "no_md")
result=$(detect_ai_artifacts "$NO_MD_DIR")
if echo "$result" | grep -q "CLAUDE.md"; then
    fail "Non-existent CLAUDE.md should not be reported"
else
    pass "Non-existent CLAUDE.md not reported"
fi

# =============================================================================
# _scan_for_directive_language — heuristic detection
# =============================================================================
echo "=== _scan_for_directive_language: heuristic patterns ==="

DIRECTIVE_FILE="${TEST_TMPDIR}/agents_md.md"

# File with strong persona language — should detect (≥2 matches)
cat > "$DIRECTIVE_FILE" << 'EOF'
# Agent Role: Coder

You are a senior software engineer.
Your role is to implement features.

## Rules
- MUST write tests for every function
- NEVER leave TODO comments
- ALWAYS follow the style guide
EOF
if _scan_for_directive_language "$DIRECTIVE_FILE"; then
    pass "File with persona+rules+directives detected as directive markdown"
else
    fail "Strong directive markdown NOT detected"
fi

# File with minimal content — should NOT detect (< 2 matches)
MINIMAL_FILE="${TEST_TMPDIR}/readme.md"
cat > "$MINIMAL_FILE" << 'EOF'
# My Project

This project does something useful.
EOF
if _scan_for_directive_language "$MINIMAL_FILE"; then
    fail "Minimal README should NOT be detected as directive markdown"
else
    pass "Minimal README not falsely detected as directive markdown"
fi

# Non-.md file — should NOT detect regardless of content
BASH_FILE="${TEST_TMPDIR}/script.sh"
cat > "$BASH_FILE" << 'EOF'
#!/usr/bin/env bash
# You are running this script.
# Your role is to deploy.
## Rules
# MUST exit 0 on success
# NEVER fail silently
# ALWAYS log errors
EOF
if _scan_for_directive_language "$BASH_FILE"; then
    fail "Non-.md file should NOT be detected as directive markdown"
else
    pass "Non-.md file not falsely detected"
fi

# Non-existent file — should return 1
if _scan_for_directive_language "/nonexistent/path.md" 2>/dev/null; then
    fail "Non-existent file should return 1"
else
    pass "Non-existent file returns 1 (not detected)"
fi

# Only MUST/NEVER/ALWAYS but count < 3 — should NOT trigger directive count alone
FEW_DIRECTIVES="${TEST_TMPDIR}/few_directives.md"
cat > "$FEW_DIRECTIVES" << 'EOF'
# Quick Notes

MUST do this.
NEVER do that.
EOF
# This has 2 directive words (< 3 threshold) — so directive_count alone won't fire.
# No persona lines either — total match_count = 0 → should NOT detect
if _scan_for_directive_language "$FEW_DIRECTIVES"; then
    fail "File with only 2 directive words should NOT be detected (threshold is 3)"
else
    pass "File with only 2 directive words not detected (threshold=3)"
fi

# Three+ MUST/NEVER/ALWAYS lines alone (directive_count >= 3 → +1) — still needs ≥2 total
DIRECTIVES_ONLY="${TEST_TMPDIR}/directives_only.md"
cat > "$DIRECTIVES_ONLY" << 'EOF'
# Notes

MUST do A.
NEVER do B.
ALWAYS do C.
EOF
# directive_count = 3 → match_count = 1 (only directives, no persona/headers)
# match_count < 2 → should NOT detect
if _scan_for_directive_language "$DIRECTIVES_ONLY"; then
    fail "Directives alone (no persona/headers) should NOT reach match_count 2"
else
    pass "Directives without persona/headers do not trigger detection alone"
fi

# =============================================================================
# _detect_directive_markdowns — scans known candidates in project dir
# =============================================================================
echo "=== _detect_directive_markdowns: candidate files ==="

DIRECTIVE_PROJ=$(make_proj "directive_proj")
cat > "${DIRECTIVE_PROJ}/AGENTS.md" << 'EOF'
# Agent Role: Coder

You are a software engineer.
Your role is to implement features.

## Rules
- MUST write tests
- NEVER skip linting
- ALWAYS follow conventions
EOF

result=$(detect_ai_artifacts "$DIRECTIVE_PROJ")
if echo "$result" | grep -q "^AI Directives|AGENTS.md|rules|low$"; then
    pass "AGENTS.md with directive language detected as AI Directives"
else
    fail "AGENTS.md with directive language not detected: got: $result"
fi

# ARCHITECTURE.md without directive language should NOT be flagged
ARCH_PROJ=$(make_proj "arch_proj")
cat > "${ARCH_PROJ}/ARCHITECTURE.md" << 'EOF'
# System Architecture

This document describes the system components and their relationships.
The web layer communicates with the database via the service layer.
EOF
result=$(detect_ai_artifacts "$ARCH_PROJ")
if echo "$result" | grep -q "^AI Directives|ARCHITECTURE.md"; then
    fail "Plain ARCHITECTURE.md should NOT be flagged as AI directives"
else
    pass "Plain ARCHITECTURE.md not falsely flagged"
fi

# =============================================================================
# classify_ai_tool — path-to-tool mapping
# =============================================================================
echo "=== classify_ai_tool: path mapping ==="

declare -A expected_tools=(
    [".cursor/config.json"]="Cursor"
    [".cursorrules"]="Cursor"
    [".github/copilot/settings.json"]="GitHub Copilot"
    [".aider.conf.yml"]="aider"
    [".cline/config"]="Cline"
    ["cline_docs/readme.md"]="Cline"
    [".continue/config.json"]="Continue.dev"
    [".windsurf/settings.json"]="Windsurf"
    [".windsurfrules"]="Windsurf"
    [".roomodes"]="Roo Code"
    [".roo/config"]="Roo Code"
    [".ai/config.json"]="Generic AI Config"
    [".aiconfig"]="Generic AI Config"
    [".claude/pipeline.conf"]="Tekhton"
    [".claude/agents/coder.md"]="Tekhton"
    [".claude/milestones/m01.md"]="Tekhton"
    [".claude/settings.json"]="Claude Code"
    [".claude/settings.local.json"]="Claude Code"
    [".claude/commands/foo.md"]="Claude Code"
    ["CLAUDE.md"]="Claude/Tekhton"
    ["random/path.txt"]="unknown"
)

for path in "${!expected_tools[@]}"; do
    expected="${expected_tools[$path]}"
    actual=$(classify_ai_tool "$path")
    if [[ "$actual" == "$expected" ]]; then
        pass "classify_ai_tool '$path' → '$expected'"
    else
        fail "classify_ai_tool '$path': expected '$expected', got '$actual'"
    fi
done

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
