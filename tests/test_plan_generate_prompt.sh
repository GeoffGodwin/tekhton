#!/usr/bin/env bash
# Test: prompts/plan_generate.prompt.md — content verification
# Verifies all 12 required section headings, milestone format blocks,
# and output rules are present in the generation prompt.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPT_FILE="${TEKHTON_HOME}/prompts/plan_generate.prompt.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

contains() {
    local pattern="$1"
    local label="$2"
    if grep -qF "$pattern" "$PROMPT_FILE"; then
        pass "$label"
    else
        fail "$label — pattern not found: '$pattern'"
    fi
}

contains_pattern() {
    local pattern="$1"
    local label="$2"
    if grep -qE "$pattern" "$PROMPT_FILE"; then
        pass "$label"
    else
        fail "$label — regex not found: '$pattern'"
    fi
}

echo "=== Prompt File Existence ==="

if [ -f "$PROMPT_FILE" ]; then
    pass "plan_generate.prompt.md exists"
else
    fail "plan_generate.prompt.md missing at ${PROMPT_FILE}"
    echo "  Passed: ${PASS}  Failed: ${FAIL}"
    exit 1
fi

echo
echo "=== DESIGN_CONTENT Variable ==="

contains "{{DESIGN_CONTENT}}" "prompt references {{DESIGN_CONTENT}} variable"

echo
echo "=== Required Section Headings (all 12) ==="

contains "### 1. Project Identity" "section 1: Project Identity present"
contains "### 2. Architecture Philosophy" "section 2: Architecture Philosophy present"
contains "### 3. Repository Layout" "section 3: Repository Layout present"
contains "### 4. Key Design Decisions" "section 4: Key Design Decisions present"
contains "### 5. Config Architecture" "section 5: Config Architecture present"
contains "### 6. Non-Negotiable Rules" "section 6: Non-Negotiable Rules present"
contains "### 7. Implementation Milestones" "section 7: Implementation Milestones present"
contains "### 8. Code Conventions" "section 8: Code Conventions present"
contains "### 9. Critical System Rules" "section 9: Critical System Rules present"
contains "### 10. What Not to Build Yet" "section 10: What Not to Build Yet present"
contains "### 11. Testing Strategy" "section 11: Testing Strategy present"
contains "### 12. Development Environment" "section 12: Development Environment present"

echo
echo "=== Milestone Format Blocks ==="

contains "**Watch For:**" "milestone format includes Watch For block"
contains "**Seeds Forward:**" "milestone format includes Seeds Forward block"
contains "**Scope:**" "milestone format includes Scope block"
contains "**Deliverables:**" "milestone format includes Deliverables block"
contains "**Files to create or modify:**" "milestone format includes Files block"
contains "**Acceptance criteria:**" "milestone format includes Acceptance criteria block"
contains "**Tests:**" "milestone format includes Tests block"

echo
echo "=== Non-Negotiable Rules Requirements ==="

contains_pattern "10.{0,5}20" "prompt specifies 10–20 non-negotiable rules"

echo
echo "=== Milestone Range Requirements ==="

contains_pattern "6.{0,5}12" "prompt specifies 6–12 milestones"

echo
echo "=== Output Rules ==="

contains "Output CLAUDE.md content directly to stdout" "output rule: write to stdout"
contains "Seeds Forward" "Seeds Forward mentioned in output rules"
contains "Watch For" "Watch For mentioned in output rules"
contains_pattern "500.{0,5}1500" "output rule: target length 500–1500 lines"

echo
echo "=== Milestone Ordering Rules ==="

contains "Milestone 1 should be the foundation" "milestone ordering: milestone 1 is foundation"
contains "Seeds Forward" "milestone ordering section references Seeds Forward"

echo
echo "=== Project Identity Languages Format ==="

contains '**Languages:**' "Project Identity instructs LLM to emit **Languages:** label"
contains "machine-read" "Languages list noted as machine-read by Tekhton"
contains "do not merge multiple languages onto one line" "Languages list prohibits multi-language lines"

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
