#!/usr/bin/env bash
# Test: _lint_extract_criteria code-block guard ordering (M85 drift observation)
#
# Verifies that a "##" heading INSIDE a fenced code block in the Acceptance
# Criteria section does NOT prematurely terminate criteria extraction.
# Drift observation: lib/milestone_acceptance_lint.sh lines 30-31 —
# the break-out check runs before the in-code-block guard.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/milestone_acceptance_lint.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "--- _lint_extract_criteria: ## heading inside fenced code block ---"

# Create a milestone file where the Acceptance Criteria section contains a
# fenced code block that itself has a "## heading" line inside it.
# Criteria after the code block must still be extracted.
cat > "${TMPDIR}/m_codeblock_hash.md" << 'MILESTONE'
# Milestone 99: Code Block Hash Test

## Overview

Tests the criteria extractor code-block guard.

## Acceptance Criteria

- [ ] The pipeline emits a valid JSON report

```bash
## This "##" heading is inside the code block and must NOT terminate extraction
grep -r "something" .
```

- [ ] The pipeline handles edge cases correctly

## Implementation Notes

Nothing here.
MILESTONE

# Extract criteria from the file
extracted=$(_lint_extract_criteria "${TMPDIR}/m_codeblock_hash.md")

# The two real criteria lines (outside the code block) must both be present.
if echo "$extracted" | grep -q 'emits a valid JSON report'; then
    pass "First criterion (before code block) is extracted"
else
    fail "First criterion (before code block) was NOT extracted — got: ${extracted}"
fi

if echo "$extracted" | grep -q 'handles edge cases'; then
    pass "Second criterion (after code block) is extracted"
else
    fail "Second criterion (after code block) was NOT extracted (premature break?) — got: ${extracted}"
fi

# The code-block content must NOT appear in the extracted criteria.
if echo "$extracted" | grep -q 'grep -r'; then
    fail "Code block contents leaked into extracted criteria"
else
    pass "Code block contents are correctly stripped"
fi

# The ## heading inside the code block must NOT appear in criteria either.
if echo "$extracted" | grep -qE '^##[[:space:]]'; then
    fail "## heading inside code block leaked into extracted criteria"
else
    pass "## heading inside code block is correctly stripped"
fi

echo
echo "--- lint_acceptance_criteria: no false warning from code-block ## ---"

# Behavioral keyword appears ONLY after the code block. A broken extractor
# that stops at "## heading" inside the code block would drop the only
# behavioral criterion, causing a false lint warning.
cat > "${TMPDIR}/m_behavioral_after_codeblock.md" << 'MILESTONE'
# Milestone 97: Behavioral After Code Block

## Acceptance Criteria

- [ ] The pipeline exits cleanly with status zero

```bash
## this heading must not terminate extraction
echo "example"
```

- [ ] The pipeline emits a structured JSON report on success

## Implementation Notes

Nothing here.
MILESTONE

result=$(lint_acceptance_criteria "${TMPDIR}/m_behavioral_after_codeblock.md")
if [[ -z "$result" ]]; then
    pass "lint_acceptance_criteria sees behavioral criterion after code-block boundary"
else
    fail "lint_acceptance_criteria missed behavioral criterion after code block: ${result}"
fi

echo
echo "--- _lint_extract_criteria: ## heading terminates only outside code block ---"

# Create a file where a "##" heading appears OUTSIDE the code block after the
# Acceptance Criteria section (the normal section-end case). Criteria extraction
# must stop before the next real section heading.
cat > "${TMPDIR}/m_normal_break.md" << 'MILESTONE'
# Milestone 98: Normal Break Test

## Acceptance Criteria

- [ ] The pipeline detects the error condition

## Implementation Notes

This text must NOT appear in criteria.
MILESTONE

extracted2=$(_lint_extract_criteria "${TMPDIR}/m_normal_break.md")

if echo "$extracted2" | grep -q 'detects the error condition'; then
    pass "Criterion before next ## section is extracted"
else
    fail "Criterion before next ## section was NOT extracted — got: ${extracted2}"
fi

if echo "$extracted2" | grep -q 'must NOT appear'; then
    fail "Text after next ## section leaked into criteria"
else
    pass "Text after next ## section is correctly excluded"
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
