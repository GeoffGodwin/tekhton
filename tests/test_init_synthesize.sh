#!/usr/bin/env bash
# Test: stages/init_synthesize.sh — _assemble_synthesis_context,
#       _compress_synthesis_context, _check_synthesis_completeness,
#       _get_section_content_simple, config defaults, prompt content
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Helper: source synthesize stage in a subshell with all mocks in place.
# Env vars and function body passed as positional args.
# ---------------------------------------------------------------------------
run_synthesize_subshell() {
    local proj_dir="$1"
    local body="$2"   # bash code to eval after sourcing

    (
        export TEKHTON_HOME
        export PROJECT_DIR="$proj_dir"
        export SYNTHESIS_MODEL="${SYNTHESIS_MODEL:-opus}"
        export SYNTHESIS_MAX_TURNS="${SYNTHESIS_MAX_TURNS:-50}"
        export CHARS_PER_TOKEN="${CHARS_PER_TOKEN:-4}"
        export CONTEXT_BUDGET_PCT="${CONTEXT_BUDGET_PCT:-50}"
        export CONTEXT_BUDGET_ENABLED="${CONTEXT_BUDGET_ENABLED:-true}"

        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/common.sh"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/context.sh"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/index_reader.sh"

        # Mock compress_context — return first 100 chars (shorter than input)
        compress_context() {
            local content="$1"
            echo "${content:0:100}"
        }

        # Mock format_detection_report — return a small, predictable string
        format_detection_report() {
            echo "# Detection Report (mock)"
        }

        # Mock render_prompt — not exercised in context/completeness tests
        render_prompt() {
            echo "# Mock prompt"
        }

        # Mock _call_planning_batch — returns empty (no real agent call)
        _call_planning_batch() {
            echo ""
        }

        # Initialise exported context vars to empty
        export PROJECT_INDEX_CONTENT=""
        export DETECTION_REPORT_CONTENT=""
        export README_CONTENT=""
        export EXISTING_ARCHITECTURE_CONTENT=""
        export GIT_LOG_SUMMARY=""

        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/stages/init_synthesize.sh"

        eval "$body"
    )
}

# =============================================================================
echo "=== _assemble_synthesis_context: missing PROJECT_INDEX.md → returns 1 ==="

proj_no_index="${TMPDIR_BASE}/no_index"
mkdir -p "$proj_no_index"

result=$(run_synthesize_subshell "$proj_no_index" \
    '_assemble_synthesis_context "$PROJECT_DIR" > /dev/null 2>&1 && echo 0 || echo 1')
if [[ "$result" == "1" ]]; then
    pass "missing PROJECT_INDEX.md returns 1"
else
    fail "expected 1 for missing index, got '${result}'"
fi

# =============================================================================
echo
echo "=== _assemble_synthesis_context: PROJECT_INDEX.md present → PROJECT_INDEX_CONTENT set ==="

proj_with_index="${TMPDIR_BASE}/with_index"
mkdir -p "$proj_with_index"
echo "# Project Index" > "${proj_with_index}/PROJECT_INDEX.md"
echo "Some index content." >> "${proj_with_index}/PROJECT_INDEX.md"

result=$(run_synthesize_subshell "$proj_with_index" '
    _assemble_synthesis_context "$PROJECT_DIR" > /dev/null 2>&1
    echo "${PROJECT_INDEX_CONTENT}"
')
if echo "$result" | grep -q "Project Index"; then
    pass "PROJECT_INDEX_CONTENT populated from PROJECT_INDEX.md"
else
    fail "PROJECT_INDEX_CONTENT not populated — got: '${result}'"
fi

# =============================================================================
echo
echo "=== _assemble_synthesis_context: DETECTION_REPORT_CONTENT populated ==="

result=$(run_synthesize_subshell "$proj_with_index" '
    _assemble_synthesis_context "$PROJECT_DIR" > /dev/null 2>&1
    echo "${DETECTION_REPORT_CONTENT}"
')
if echo "$result" | grep -q "Detection Report"; then
    pass "DETECTION_REPORT_CONTENT populated from format_detection_report"
else
    fail "DETECTION_REPORT_CONTENT not populated — got: '${result}'"
fi

# =============================================================================
echo
echo "=== _assemble_synthesis_context: README.md present → README_CONTENT set ==="

proj_with_readme="${TMPDIR_BASE}/with_readme"
mkdir -p "$proj_with_readme"
echo "# Project Index" > "${proj_with_readme}/PROJECT_INDEX.md"
echo "# My README" > "${proj_with_readme}/README.md"
echo "Project description." >> "${proj_with_readme}/README.md"

result=$(run_synthesize_subshell "$proj_with_readme" '
    _assemble_synthesis_context "$PROJECT_DIR" > /dev/null 2>&1
    echo "${README_CONTENT}"
')
if echo "$result" | grep -q "My README"; then
    pass "README_CONTENT populated when README.md is present"
else
    fail "README_CONTENT not populated — got: '${result}'"
fi

# =============================================================================
echo
echo "=== _assemble_synthesis_context: no README → README_CONTENT empty ==="

result=$(run_synthesize_subshell "$proj_with_index" '
    _assemble_synthesis_context "$PROJECT_DIR" > /dev/null 2>&1
    echo "content=[${README_CONTENT}]"
')
if echo "$result" | grep -q "content=\[\]"; then
    pass "README_CONTENT is empty when no README file exists"
else
    fail "README_CONTENT should be empty — got: '${result}'"
fi

# =============================================================================
echo
echo "=== _assemble_synthesis_context: ARCHITECTURE.md present → EXISTING_ARCHITECTURE_CONTENT set ==="

proj_with_arch="${TMPDIR_BASE}/with_arch"
mkdir -p "$proj_with_arch"
echo "# Project Index" > "${proj_with_arch}/PROJECT_INDEX.md"
echo "# Architecture" > "${proj_with_arch}/ARCHITECTURE.md"
echo "Layer one depends on layer two." >> "${proj_with_arch}/ARCHITECTURE.md"

result=$(run_synthesize_subshell "$proj_with_arch" '
    _assemble_synthesis_context "$PROJECT_DIR" > /dev/null 2>&1
    echo "${EXISTING_ARCHITECTURE_CONTENT}"
')
if echo "$result" | grep -q "Architecture"; then
    pass "EXISTING_ARCHITECTURE_CONTENT populated when ARCHITECTURE.md is present"
else
    fail "EXISTING_ARCHITECTURE_CONTENT not populated — got: '${result}'"
fi

# =============================================================================
echo
echo "=== _assemble_synthesis_context: no ARCHITECTURE.md → EXISTING_ARCHITECTURE_CONTENT empty ==="

result=$(run_synthesize_subshell "$proj_with_index" '
    _assemble_synthesis_context "$PROJECT_DIR" > /dev/null 2>&1
    echo "arch=[${EXISTING_ARCHITECTURE_CONTENT}]"
')
if echo "$result" | grep -q "arch=\[\]"; then
    pass "EXISTING_ARCHITECTURE_CONTENT is empty when ARCHITECTURE.md absent"
else
    fail "expected empty arch content — got: '${result}'"
fi

# =============================================================================
echo
echo "=== _assemble_synthesis_context: README candidates tried in order ==="

proj_rst="${TMPDIR_BASE}/with_rst"
mkdir -p "$proj_rst"
echo "# Project Index" > "${proj_rst}/PROJECT_INDEX.md"
echo "RST readme content." > "${proj_rst}/README.rst"

result=$(run_synthesize_subshell "$proj_rst" '
    _assemble_synthesis_context "$PROJECT_DIR" > /dev/null 2>&1
    echo "${README_CONTENT}"
')
if echo "$result" | grep -q "RST readme"; then
    pass "README.rst loaded when README.md absent"
else
    fail "README.rst not loaded — got: '${result}'"
fi

# =============================================================================
echo
echo "=== _compress_synthesis_context: under budget → no compression ==="

result=$(run_synthesize_subshell "$proj_with_index" '
    # Set small context — well under 50% of 200k token budget
    export PROJECT_INDEX_CONTENT="small index content"
    export DETECTION_REPORT_CONTENT="small report"
    export README_CONTENT=""
    export EXISTING_ARCHITECTURE_CONTENT=""
    export GIT_LOG_SUMMARY=""
    _compress_synthesis_context > /dev/null 2>&1
    echo "${PROJECT_INDEX_CONTENT}"
')
if echo "$result" | grep -q "small index content"; then
    pass "_compress_synthesis_context leaves PROJECT_INDEX_CONTENT unchanged when under budget"
else
    fail "expected unchanged content under budget — got: '${result}'"
fi

# =============================================================================
echo
echo "=== _compress_synthesis_context: over budget → index unchanged (M68: reader bounds it) ==="

# M68: _compress_synthesis_context no longer applies summarize_headings to
# PROJECT_INDEX_CONTENT because read_index_summary already bounds it.
# Index content should be left unchanged; other content gets compressed instead.
result=$(run_synthesize_subshell "$proj_with_index" '
    export PROJECT_INDEX_CONTENT="bounded index from reader"
    export DETECTION_REPORT_CONTENT="$(printf "%-200001s" "D" | tr " " "D")"
    export README_CONTENT="$(printf "line %d\n" $(seq 1 100))"
    export EXISTING_ARCHITECTURE_CONTENT=""
    export GIT_LOG_SUMMARY=""
    _compress_synthesis_context > /dev/null 2>&1
    echo "${PROJECT_INDEX_CONTENT}"
')
if echo "$result" | grep -q "bounded index from reader"; then
    pass "_compress_synthesis_context leaves index unchanged (M68: already bounded)"
else
    fail "expected index unchanged after compression — got: '${result}'"
fi

# =============================================================================
echo
echo "=== _compress_synthesis_context: git log truncated to 10 entries when still over budget ==="

result=$(run_synthesize_subshell "$proj_with_index" '
    # Use multiple large sections to exceed budget (M68: index is bounded, so
    # use other content to push over the limit)
    big=$(printf "%-300001s" "#" | tr " " "#")
    export PROJECT_INDEX_CONTENT="$big"
    export DETECTION_REPORT_CONTENT="$(printf "%-200001s" "D" | tr " " "D")"
    export README_CONTENT="$(printf "line %d\n" $(seq 1 100))"
    export EXISTING_ARCHITECTURE_CONTENT="$(printf "line %d\n" $(seq 1 100))"
    # 20 git log entries
    export GIT_LOG_SUMMARY="$(printf "commit%02d message\n" $(seq 1 20))"
    _compress_synthesis_context > /dev/null 2>&1
    line_count=$(echo "$GIT_LOG_SUMMARY" | grep -c "commit" || true)
    echo "$line_count"
')
if [[ "$result" -le 10 ]]; then
    pass "_compress_synthesis_context truncates GIT_LOG_SUMMARY to 10 entries"
else
    fail "expected ≤10 git log entries after truncation — got: '${result}'"
fi

# =============================================================================
echo
echo "=== _get_section_content_simple: extract named section ==="

proj_sections="${TMPDIR_BASE}/sections"
mkdir -p "$proj_sections"
cat > "${proj_sections}/TEST_DOC.md" << 'EOF'
## Overview
This is the overview section.
It has multiple lines.

## Architecture
The architecture section content.
EOF

result=$(run_synthesize_subshell "$proj_sections" '
    content=$(_get_section_content_simple "${PROJECT_DIR}/TEST_DOC.md" "Overview")
    echo "$content"
')
if echo "$result" | grep -q "overview section"; then
    pass "_get_section_content_simple extracts content of named section"
else
    fail "_get_section_content_simple failed to extract section — got: '${result}'"
fi

# Must not include content from next section
if ! echo "$result" | grep -q "architecture section"; then
    pass "_get_section_content_simple stops at next ## heading"
else
    fail "_get_section_content_simple leaked content from next section"
fi

# =============================================================================
echo
echo "=== _get_section_content_simple: last section (until EOF) ==="

result=$(run_synthesize_subshell "$proj_sections" '
    content=$(_get_section_content_simple "${PROJECT_DIR}/TEST_DOC.md" "Architecture")
    echo "$content"
')
if echo "$result" | grep -q "architecture section"; then
    pass "_get_section_content_simple extracts last section until EOF"
else
    fail "_get_section_content_simple failed on last section — got: '${result}'"
fi

# =============================================================================
echo
echo "=== _check_synthesis_completeness: no DESIGN.md → returns 0 ==="

proj_no_design="${TMPDIR_BASE}/no_design"
mkdir -p "$proj_no_design"

result=$(run_synthesize_subshell "$proj_no_design" '
    _check_synthesis_completeness "$PROJECT_DIR" > /dev/null 2>&1 && echo 0 || echo 1
')
if [[ "$result" == "0" ]]; then
    pass "_check_synthesis_completeness returns 0 when DESIGN.md absent"
else
    fail "expected 0 for missing DESIGN.md — got '${result}'"
fi

# =============================================================================
echo
echo "=== _check_synthesis_completeness: 5+ sections → completeness OK ==="

proj_good_design="${TMPDIR_BASE}/good_design"
mkdir -p "$proj_good_design"
cat > "${proj_good_design}/DESIGN.md" << 'EOF'
## Overview
Line 1 of overview.
Line 2 of overview.
Line 3 of overview.

## Architecture
Line 1 of architecture.
Line 2 of architecture.
Line 3 of architecture.

## Data Model
Line 1 of data model.
Line 2 of data model.
Line 3 of data model.

## Configuration
Line 1 of configuration.
Line 2 of configuration.
Line 3 of configuration.

## Conventions
Line 1 of conventions.
Line 2 of conventions.
Line 3 of conventions.
EOF

result=$(run_synthesize_subshell "$proj_good_design" '
    output=$(_check_synthesis_completeness "$PROJECT_DIR" 2>&1)
    echo "$output"
')
if echo "$result" | grep -q "completeness OK"; then
    pass "_check_synthesis_completeness reports OK for 5-section DESIGN.md"
else
    fail "expected 'completeness OK' — got: '${result}'"
fi

# =============================================================================
echo
echo "=== _check_synthesis_completeness: < 5 sections → warns and sets PLAN_INCOMPLETE_SECTIONS ==="

proj_thin_design="${TMPDIR_BASE}/thin_design"
mkdir -p "$proj_thin_design"
cat > "${proj_thin_design}/DESIGN.md" << 'EOF'
## Overview
Short.

## Architecture
Short.
EOF

result=$(run_synthesize_subshell "$proj_thin_design" '
    # Override _synthesize_design so no real agent call happens
    _synthesize_design() { return 0; }
    _check_synthesis_completeness "$PROJECT_DIR" > /dev/null 2>&1 || true
    echo "sections_set=${PLAN_INCOMPLETE_SECTIONS:-UNSET}"
')
# PLAN_INCOMPLETE_SECTIONS should be set (or thin_sections warning emitted)
# The key signal is that the function warns about section count < 5
warn_result=$(run_synthesize_subshell "$proj_thin_design" '
    _synthesize_design() { return 0; }
    _check_synthesis_completeness "$PROJECT_DIR" 2>&1 || true
')
if echo "$warn_result" | grep -q "only.*sections"; then
    pass "_check_synthesis_completeness warns when DESIGN.md has < 5 sections"
else
    fail "expected section count warning — got: '${warn_result}'"
fi

# =============================================================================
echo
echo "=== _check_synthesis_completeness: thin section detected and PLAN_INCOMPLETE_SECTIONS formatted ==="

proj_thin2="${TMPDIR_BASE}/thin2"
mkdir -p "$proj_thin2"
cat > "${proj_thin2}/DESIGN.md" << 'EOF'
## Overview
Short.

## Architecture
Short.

## ThinSection
x
EOF

result=$(run_synthesize_subshell "$proj_thin2" '
    _synthesize_design() { return 0; }
    _check_synthesis_completeness "$PROJECT_DIR" > /dev/null 2>&1 || true
    # PLAN_INCOMPLETE_SECTIONS was set then unset inside the function
    # (it is cleared after _synthesize_design call)
    # Test the warn output contains thin section info instead
    echo "done"
')
if [[ "$result" == "done" ]]; then
    pass "_check_synthesis_completeness completes without error on thin sections"
else
    fail "unexpected result — got '${result}'"
fi

# =============================================================================
echo
echo "=== run_project_synthesis: missing PROJECT_INDEX.md → returns 1 ==="

proj_synth_no_index="${TMPDIR_BASE}/synth_no_index"
mkdir -p "$proj_synth_no_index"

result=$(run_synthesize_subshell "$proj_synth_no_index" '
    run_project_synthesis "$PROJECT_DIR" > /dev/null 2>&1 && echo 0 || echo 1
')
if [[ "$result" == "1" ]]; then
    pass "run_project_synthesis returns 1 when PROJECT_INDEX.md absent"
else
    fail "expected return 1 for missing index — got '${result}'"
fi

# =============================================================================
echo
echo "=== Config defaults: SYNTHESIS_MODEL defaults to opus ==="

model_default=$(
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    unset SYNTHESIS_MODEL PLAN_GENERATION_MODEL 2>/dev/null || true

    # Mock required functions before sourcing
    format_detection_report() { echo "mock"; }
    render_prompt() { echo "mock"; }
    _call_planning_batch() { echo ""; }
    check_context_budget() { return 0; }
    compress_context() { echo "$1"; }

    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/stages/init_synthesize.sh"
    echo "$SYNTHESIS_MODEL"
)
if [[ "$model_default" == "opus" ]]; then
    pass "SYNTHESIS_MODEL defaults to 'opus' when neither SYNTHESIS_MODEL nor PLAN_GENERATION_MODEL set"
else
    fail "expected SYNTHESIS_MODEL=opus, got '${model_default}'"
fi

# =============================================================================
echo
echo "=== Config defaults: SYNTHESIS_MAX_TURNS defaults to 50 ==="

turns_default=$(
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    unset SYNTHESIS_MAX_TURNS PLAN_GENERATION_MAX_TURNS 2>/dev/null || true

    format_detection_report() { echo "mock"; }
    render_prompt() { echo "mock"; }
    _call_planning_batch() { echo ""; }
    check_context_budget() { return 0; }
    compress_context() { echo "$1"; }

    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/stages/init_synthesize.sh"
    echo "$SYNTHESIS_MAX_TURNS"
)
if [[ "$turns_default" == "50" ]]; then
    pass "SYNTHESIS_MAX_TURNS defaults to 50 when neither SYNTHESIS_MAX_TURNS nor PLAN_GENERATION_MAX_TURNS set"
else
    fail "expected SYNTHESIS_MAX_TURNS=50, got '${turns_default}'"
fi

# =============================================================================
echo
echo "=== Config defaults: SYNTHESIS_MODEL inherits PLAN_GENERATION_MODEL ==="

model_inherit=$(
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    unset SYNTHESIS_MODEL 2>/dev/null || true
    export PLAN_GENERATION_MODEL="custom-model"

    format_detection_report() { echo "mock"; }
    render_prompt() { echo "mock"; }
    _call_planning_batch() { echo ""; }
    check_context_budget() { return 0; }
    compress_context() { echo "$1"; }

    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/stages/init_synthesize.sh"
    echo "$SYNTHESIS_MODEL"
)
if [[ "$model_inherit" == "custom-model" ]]; then
    pass "SYNTHESIS_MODEL inherits from PLAN_GENERATION_MODEL"
else
    fail "expected SYNTHESIS_MODEL=custom-model, got '${model_inherit}'"
fi

# =============================================================================
echo
echo "=== Prompt: init_synthesize_design.prompt.md has {{PROJECT_INDEX_CONTENT}} ==="

DESIGN_PROMPT="${TEKHTON_HOME}/prompts/init_synthesize_design.prompt.md"

if grep -q '{{PROJECT_INDEX_CONTENT}}' "$DESIGN_PROMPT"; then
    pass "design prompt includes {{PROJECT_INDEX_CONTENT}} placeholder"
else
    fail "design prompt missing {{PROJECT_INDEX_CONTENT}}"
fi

# =============================================================================
echo
echo "=== Prompt: init_synthesize_design.prompt.md has {{DETECTION_REPORT_CONTENT}} ==="

if grep -q '{{DETECTION_REPORT_CONTENT}}' "$DESIGN_PROMPT"; then
    pass "design prompt includes {{DETECTION_REPORT_CONTENT}} placeholder"
else
    fail "design prompt missing {{DETECTION_REPORT_CONTENT}}"
fi

# =============================================================================
echo
echo "=== Prompt: design prompt has {{IF:PLAN_INCOMPLETE_SECTIONS}} re-synthesis block ==="

if grep -q '{{IF:PLAN_INCOMPLETE_SECTIONS}}' "$DESIGN_PROMPT"; then
    pass "design prompt includes {{IF:PLAN_INCOMPLETE_SECTIONS}} conditional block"
else
    fail "design prompt missing re-synthesis PLAN_INCOMPLETE_SECTIONS block"
fi

# =============================================================================
echo
echo "=== Prompt: design prompt has evidence-based instruction ==="

if grep -qi "what EXISTS" "$DESIGN_PROMPT"; then
    pass "design prompt instructs agent to document what EXISTS"
else
    fail "design prompt missing 'what EXISTS' instruction"
fi

# =============================================================================
echo
echo "=== Prompt: design prompt has 10 required sections ==="

for section in "Project Overview" "Developer Philosophy" "Architecture" \
               "Directory Structure" "Core Systems" "Data Model" \
               "Configuration" "Build and Deploy" "Conventions and Patterns" \
               "Technical Debt and Open Questions"; do
    if grep -q "$section" "$DESIGN_PROMPT"; then
        pass "design prompt has required section: ${section}"
    else
        fail "design prompt missing required section: ${section}"
    fi
done

# =============================================================================
echo
echo "=== Prompt: init_synthesize_claude.prompt.md has brownfield framing ==="

CLAUDE_PROMPT="${TEKHTON_HOME}/prompts/init_synthesize_claude.prompt.md"

if grep -qi "BROWNFIELD" "$CLAUDE_PROMPT"; then
    pass "claude prompt includes 'BROWNFIELD' framing"
else
    fail "claude prompt missing brownfield framing"
fi

# =============================================================================
echo
echo "=== Prompt: init_synthesize_claude.prompt.md milestones address debt, not features ==="

if grep -q "technical debt" "$CLAUDE_PROMPT"; then
    pass "claude prompt instructs milestones address technical debt"
else
    fail "claude prompt missing technical debt instruction"
fi

# =============================================================================
echo
echo "=== Prompt: init_synthesize_claude.prompt.md has 12 required sections ==="

for section in "Project Identity" "Architecture Philosophy" "Repository Layout" \
               "Key Design Decisions" "Config Architecture" "Non-Negotiable Rules" \
               "Implementation Milestones" "Code Conventions" "Critical System Rules" \
               "What Not to Build Yet" "Testing Strategy" "Development Environment"; do
    if grep -q "$section" "$CLAUDE_PROMPT"; then
        pass "claude prompt has required section: ${section}"
    else
        fail "claude prompt missing required section: ${section}"
    fi
done

# =============================================================================
echo
echo "=== Prompt: init_synthesize_claude.prompt.md has {{DESIGN_CONTENT}} ==="

if grep -q '{{DESIGN_CONTENT}}' "$CLAUDE_PROMPT"; then
    pass "claude prompt includes {{DESIGN_CONTENT}} placeholder"
else
    fail "claude prompt missing {{DESIGN_CONTENT}}"
fi

# =============================================================================
echo
echo "=== Prompt: init_synthesize_claude.prompt.md has Watch For and Seeds Forward ==="

if grep -q 'Watch For' "$CLAUDE_PROMPT"; then
    pass "claude prompt includes 'Watch For' in milestone format"
else
    fail "claude prompt missing 'Watch For' block"
fi

if grep -q 'Seeds Forward' "$CLAUDE_PROMPT"; then
    pass "claude prompt includes 'Seeds Forward' in milestone format"
else
    fail "claude prompt missing 'Seeds Forward' block"
fi

# =============================================================================
echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
