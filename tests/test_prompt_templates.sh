#!/usr/bin/env bash
# Test: All prompt templates exist and contain no syntax errors
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPTS_DIR="${TEKHTON_HOME}/prompts"

EXPECTED_PROMPTS=(
    coder.prompt.md
    coder_rework.prompt.md
    jr_coder.prompt.md
    reviewer.prompt.md
    scout.prompt.md
    tester.prompt.md
    tester_resume.prompt.md
    build_fix.prompt.md
    build_fix_minimal.prompt.md
    analyze_cleanup.prompt.md
    seed_contracts.prompt.md
)

for prompt in "${EXPECTED_PROMPTS[@]}"; do
    FILEPATH="${PROMPTS_DIR}/${prompt}"
    [ -f "$FILEPATH" ] || { echo "Missing prompt: ${prompt}"; exit 1; }

    # Check for unclosed IF/ENDIF pairs
    IF_COUNT=$(grep -c '{{IF:' "$FILEPATH" || true)
    ENDIF_COUNT=$(grep -c '{{ENDIF:' "$FILEPATH" || true)
    [ "$IF_COUNT" = "$ENDIF_COUNT" ] || {
        echo "Mismatched IF/ENDIF in ${prompt}: IF=${IF_COUNT} ENDIF=${ENDIF_COUNT}"
        exit 1
    }

    # Check that all {{IF:VAR}} have matching {{ENDIF:VAR}}
    while IFS= read -r var; do
        grep -q "{{ENDIF:${var}}}" "$FILEPATH" || {
            echo "Unclosed {{IF:${var}}} in ${prompt}"
            exit 1
        }
    done < <(grep -oP '{{IF:\K[A-Za-z_]+(?=}})' "$FILEPATH" 2>/dev/null || true)
done

echo "Prompt templates validation test passed"
