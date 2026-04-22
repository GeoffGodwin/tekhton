#!/usr/bin/env bash
# test_m119_deliverables.sh — Structural verification of M119 deliverables.
#
# Checks that:
#   - docs/tui-lifecycle-model.md exists with all 10 required sections
#   - Lifecycle model pointer comments appear in the 3 production files
#   - CLAUDE.md links to the new doc
#   - tests/test_tui_lifecycle_invariants.sh exists with all 9 invariant headers
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

DOC="${TEKHTON_HOME}/docs/tui-lifecycle-model.md"
INVTEST="${TEKHTON_HOME}/tests/test_tui_lifecycle_invariants.sh"

# --- 1. docs/tui-lifecycle-model.md exists ---
if [[ -f "$DOC" ]]; then
    pass "docs/tui-lifecycle-model.md exists"
else
    fail "doc exists" "docs/tui-lifecycle-model.md not found — deliverable missing"
fi

# --- 2. Required section headings ---
declare -a required_sections=(
    "## 1. Three surfaces"
    "## 2. Stage classes"
    "## 3. Lifecycle helpers"
    "## 4. Status file schema"
    "## 5. Event attribution"
    "## 6. Adding a new stage"
    "## 7. Adding a new sub-stage"
    "## 8. Adding a new"
    "## 9. Debugging checklist"
    "## 10. Where to make changes"
)
for section in "${required_sections[@]}"; do
    if grep -qF "$section" "$DOC" 2>/dev/null; then
        pass "doc section: $section"
    else
        fail "doc section missing" "'$section' not found in docs/tui-lifecycle-model.md"
    fi
done

# --- 3. Pointer comments in production files ---
for f in "${TEKHTON_HOME}/lib/tui_ops.sh" \
          "${TEKHTON_HOME}/tools/tui_render.py" \
          "${TEKHTON_HOME}/tools/tui_render_timings.py"; do
    base=$(basename "$f")
    if grep -q "docs/tui-lifecycle-model.md" "$f" 2>/dev/null; then
        pass "$base has lifecycle model pointer"
    else
        fail "$base pointer" "$base missing 'docs/tui-lifecycle-model.md' reference"
    fi
done

# --- 4. CLAUDE.md links to the new doc ---
if grep -q "docs/tui-lifecycle-model.md" "${TEKHTON_HOME}/CLAUDE.md" 2>/dev/null; then
    pass "CLAUDE.md links to docs/tui-lifecycle-model.md"
else
    fail "CLAUDE.md link" "CLAUDE.md missing reference to docs/tui-lifecycle-model.md"
fi

# --- 5. tests/test_tui_lifecycle_invariants.sh exists ---
if [[ -f "$INVTEST" ]]; then
    pass "tests/test_tui_lifecycle_invariants.sh exists"
else
    fail "invariants test exists" "tests/test_tui_lifecycle_invariants.sh not found"
fi

# --- 6. All 9 invariant section headers present ---
for i in $(seq 1 9); do
    if grep -q "=== Invariant ${i}:" "$INVTEST" 2>/dev/null; then
        pass "invariant $i header present"
    else
        fail "invariant $i header" "=== Invariant ${i}: header not found in test file"
    fi
done

# --- 7. Invariants file references M119 ---
if grep -q "M119" "$INVTEST" 2>/dev/null; then
    pass "tests/test_tui_lifecycle_invariants.sh references M119"
else
    fail "M119 reference" "test file does not reference M119"
fi

# --- 8. No production code logic changed (only comment additions) ---
# Production shell files under lib/ and stages/ must not define new functions
# beyond what was present before M119. We check that tui_ops_substage.sh
# and tui_ops.sh function signatures are unchanged by verifying the
# known M113/M115 functions are declared (implementation intact).
for fn in tui_substage_begin tui_substage_end _tui_autoclose_substage_if_open run_op; do
    found_in=""
    for src in "${TEKHTON_HOME}/lib/tui_ops.sh" \
                "${TEKHTON_HOME}/lib/tui_ops_substage.sh"; do
        if grep -q "^${fn}()" "$src" 2>/dev/null; then
            found_in="$src"
            break
        fi
    done
    if [[ -n "$found_in" ]]; then
        pass "function $fn() still declared ($(basename "$found_in"))"
    else
        fail "function $fn()" "$fn() not found in tui_ops.sh or tui_ops_substage.sh"
    fi
done

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
