#!/usr/bin/env bash
# =============================================================================
# test_notes_normalization.sh — m24 update.
#
# The bash `_normalize_markdown_blank_runs` helper moved from the
# deleted lib/notes_core_normalize.sh to lib/markdown_helpers.sh. The
# notes-side normalization is no longer relevant (the Go writer in
# internal/notes/parser.go controls blank-line layout directly). This
# stub exercises the surviving helper to keep its behaviour pinned.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/markdown_helpers.sh
source "${TEKHTON_HOME}/lib/markdown_helpers.sh"

FAIL=0
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Test 1: Collapses interior blank-line runs.
printf 'line1\n\n\nline2\n' > "$tmp"
_normalize_markdown_blank_runs "$tmp"
if [[ "$(cat "$tmp")" != $'line1\n\nline2' ]]; then
    echo "FAIL: interior blank-line collapse"
    cat -A "$tmp"
    FAIL=1
fi

# Test 2: Idempotent.
_normalize_markdown_blank_runs "$tmp"
if [[ "$(cat "$tmp")" != $'line1\n\nline2' ]]; then
    echo "FAIL: not idempotent"
    FAIL=1
fi

# Test 3: Preserves fenced code blocks.
printf '```\n\n\n\n```\n' > "$tmp"
_normalize_markdown_blank_runs "$tmp"
if ! grep -q '^```$' "$tmp"; then
    echo "FAIL: fenced code preservation"
    FAIL=1
fi

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "test_notes_normalization.sh: PASS (lib/markdown_helpers.sh)"
exit 0
