#!/usr/bin/env bash
# Test: Prompt template rendering with variable substitution and conditionals
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"

# Create a test prompt in the prompts dir (temp override)
ORIG_PROMPTS_DIR="${PROMPTS_DIR}"
PROMPTS_DIR="${TMPDIR}/prompts"
mkdir -p "$PROMPTS_DIR"

cat > "${PROMPTS_DIR}/test_render.prompt.md" << 'TMPL'
Hello {{PROJECT_NAME}}, your task is {{TASK}}.
{{IF:OPTIONAL_BLOCK}}
This block should appear: {{OPTIONAL_BLOCK}}
{{ENDIF:OPTIONAL_BLOCK}}
{{IF:MISSING_BLOCK}}
This block should NOT appear.
{{ENDIF:MISSING_BLOCK}}
End of prompt.
TMPL

# Set template variables as shell globals (render_prompt reads these)
PROJECT_NAME="TestApp"
TASK="implement feature"
OPTIONAL_BLOCK="yes it is here"
MISSING_BLOCK=""

# Render using the actual render_prompt function
RESULT=$(render_prompt "test_render")

# Restore
PROMPTS_DIR="${ORIG_PROMPTS_DIR}"

# Verify substitution happened
echo "$RESULT" | grep -q "Hello TestApp" || { echo "PROJECT_NAME not substituted"; exit 1; }
echo "$RESULT" | grep -q "implement feature" || { echo "TASK not substituted"; exit 1; }
echo "$RESULT" | grep -q "yes it is here" || { echo "OPTIONAL_BLOCK not rendered"; exit 1; }
echo "$RESULT" | grep -q "should NOT appear" && { echo "MISSING_BLOCK should have been stripped"; exit 1; }
echo "$RESULT" | grep -q "End of prompt" || { echo "End of prompt missing"; exit 1; }

echo "Prompt rendering test passed"
