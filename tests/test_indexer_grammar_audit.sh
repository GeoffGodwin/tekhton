#!/usr/bin/env bash
# =============================================================================
# Test: Indexer grammar audit (M123)
#
# Verifies:
#   - `python repo_map.py --audit-grammars` exits 0 and emits one JSON entry
#     per declared extension.
#   - For every extension whose module is importable, the audit reports
#     language_loaded=True. A failure here means a newly-added grammar has a
#     novel API convention and needs a loader update.
#
# Skips cleanly if jq, python, or the indexer venv is missing.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# --- Skip gates ---------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed"
    exit 0
fi

VENV_PY="${TEKHTON_HOME}/.claude/indexer-venv/bin/python"
if [[ ! -x "$VENV_PY" ]]; then
    echo "SKIP: indexer venv not found at $VENV_PY"
    exit 0
fi

REPO_MAP_SCRIPT="${TEKHTON_HOME}/tools/repo_map.py"
if [[ ! -f "$REPO_MAP_SCRIPT" ]]; then
    echo "SKIP: repo_map.py not found at $REPO_MAP_SCRIPT"
    exit 0
fi

# --- Run the audit -----------------------------------------------------------
audit_output=$("$VENV_PY" "$REPO_MAP_SCRIPT" --audit-grammars 2>/dev/null) || {
    fail "repo_map.py --audit-grammars exited non-zero"
    exit 1
}

if [[ -z "$audit_output" ]]; then
    fail "audit output is empty"
    exit 1
fi

if ! echo "$audit_output" | jq . >/dev/null 2>&1; then
    fail "audit output is not valid JSON"
    echo "--- output was ---"
    echo "$audit_output"
    exit 1
fi
pass "audit output is valid JSON"

# --- Assert: one entry per declared extension --------------------------------
declared_count=$("$VENV_PY" -c "
import sys, os
sys.path.insert(0, os.path.join('${TEKHTON_HOME}', 'tools'))
from tree_sitter_languages import _EXT_TO_LANG
print(len(_EXT_TO_LANG))
")

audit_count=$(echo "$audit_output" | jq 'keys | length')
if [[ "$audit_count" == "$declared_count" ]]; then
    pass "audit covers all ${declared_count} declared extensions"
else
    fail "audit covers ${audit_count} extensions but ${declared_count} are declared"
fi

# --- Assert: every importable module loads its language ----------------------
# Find extensions where module_importable=true but language_loaded=false.
# A non-empty result means a grammar's API has drifted — the M123 regression gate.
mismatches=$(echo "$audit_output" | jq -r '
    to_entries
    | map(select(.value.module_importable == true and .value.language_loaded == false))
    | .[]
    | "\(.key)\t\(.value.module)\t\(.value.error)"
')

if [[ -z "$mismatches" ]]; then
    pass "every importable grammar module also loads its language"
else
    fail "grammar API mismatches detected (M123 regression gate):"
    while IFS=$'\t' read -r ext mod err; do
        echo "    - ${ext} (${mod}): ${err}"
    done <<< "$mismatches"
fi

# --- Summary -----------------------------------------------------------------
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
