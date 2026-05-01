#!/usr/bin/env bash
# Test: M80 empty IF block removal
# Verifies the dead {{IF:DRAFT_SEED_DESCRIPTION}} block is removed
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"

test_empty_block_pair_removed() {
    # Verify the empty {{IF:DRAFT_SEED_DESCRIPTION}}{{ENDIF:...}} pair is gone.
    # The legitimate non-empty block should remain (only one IF, one ENDIF).
    local if_count
    if_count=$(grep -c "{{IF:DRAFT_SEED_DESCRIPTION}}" "${TEKHTON_HOME}/prompts/draft_milestones.prompt.md" || echo 0)
    [[ "$if_count" -eq 1 ]]
}

test_prompt_file_exists() {
    # Verify the prompt file exists
    [[ -f "${TEKHTON_HOME}/prompts/draft_milestones.prompt.md" ]]
}

# Run tests
result=0

if test_empty_block_pair_removed; then
    echo "PASS: Empty {{IF:DRAFT_SEED_DESCRIPTION}} block pair removed"
else
    echo "FAIL: Empty {{IF:DRAFT_SEED_DESCRIPTION}} block pair still present"
    result=1
fi

if test_prompt_file_exists; then
    echo "PASS: Prompt file exists"
else
    echo "FAIL: Prompt file missing"
    result=1
fi

exit $result
