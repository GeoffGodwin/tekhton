#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_preflight_ui_config.sh — Unit tests for M131 UI test framework config audit
#
# Covers _preflight_check_ui_test_config and the four scanners in
# lib/preflight_checks_ui.sh:
#   T1  PW-1 html reporter — fail (no auto-fix) and fixed (auto-fix)
#   T2  Playwright reporter: 'dot' — no false positive
#   T3  PW-2 video: 'on' — warn only
#   T4  PW-3 reuseExistingServer: false — warn only
#   T5  No playwright config — silent skip
#   T6  JV-1 watch mode — fail; auto-fix never patches
#   T7  CY-1 cypress video: true — warn only
#   T8  PREFLIGHT_UI_* contract triple exported when PW-1 fires
#   T9  Already-CI-guarded reporter — pattern does not match
#   T10 UI_TEST_CMD unset — full no-op
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

# Source dependencies (preflight.sh defines _pf_record / counters).
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight_checks_ui.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then pass; else fail "$desc — expected '$expected', got '$actual'"; fi
}

# Reset preflight counters and contract vars between tests.
_reset_pf_state() {
    _PF_PASS=0
    _PF_WARN=0
    _PF_FAIL=0
    _PF_REMEDIATED=0
    _PF_REPORT_LINES=()
    unset PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED \
          PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE \
          PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE \
          PREFLIGHT_UI_REPORTER_PATCHED
}

_make_proj() {
    mktemp -d
}

_cleanup() { [[ -n "${1:-}" ]] && rm -rf "$1"; }

# Common per-test setup: fresh temp project, UI_TEST_CMD configured to a
# non-no-op value so the dispatcher doesn't short-circuit.
_setup() {
    PROJECT_DIR=$(_make_proj)
    export PROJECT_DIR
    export UI_TEST_CMD="npx playwright test"
    _reset_pf_state
}

# =============================================================================
# T1: PW-1 html reporter — fail-no-patch, fixed (auto-fix), legacy fallback
# =============================================================================
echo "=== T1: PW-1 html reporter ==="

# T1.a: PREFLIGHT_UI_CONFIG_AUTO_FIX=false → fail (no patch)
_setup
cat > "$PROJECT_DIR/playwright.config.ts" <<'EOF'
import { defineConfig } from '@playwright/test';
export default defineConfig({
  reporter: 'html',
});
EOF
PREFLIGHT_UI_CONFIG_AUTO_FIX=false _preflight_check_ui_test_config
assert_eq "T1.a _PF_FAIL incremented" "1" "$_PF_FAIL"
assert_eq "T1.a contract DETECTED=1" "1" "${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED:-}"
assert_eq "T1.a contract RULE=PW-1" "PW-1" "${PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE:-}"
assert_eq "T1.a contract REPORTER_PATCHED=0" "0" "${PREFLIGHT_UI_REPORTER_PATCHED:-}"
# Manual-fix instructions present in report
report_text="${_PF_REPORT_LINES[*]}"
if [[ "$report_text" == *"REQUIRED MANUAL FIX"* ]]; then pass; else fail "T1.a missing manual-fix instructions"; fi
# Source untouched
if grep -q "reporter: 'html'" "$PROJECT_DIR/playwright.config.ts"; then pass; else fail "T1.a source was modified despite auto-fix off"; fi
_cleanup "$PROJECT_DIR"

# T1.b: PREFLIGHT_UI_CONFIG_AUTO_FIX=true → fixed (patch)
_setup
cat > "$PROJECT_DIR/playwright.config.ts" <<'EOF'
import { defineConfig } from '@playwright/test';
export default defineConfig({
  reporter: 'html',
});
EOF
PREFLIGHT_UI_CONFIG_AUTO_FIX=true _preflight_check_ui_test_config
assert_eq "T1.b _PF_REMEDIATED incremented" "1" "$_PF_REMEDIATED"
assert_eq "T1.b contract REPORTER_PATCHED=1" "1" "${PREFLIGHT_UI_REPORTER_PATCHED:-}"
# Source rewritten to CI-guarded form
if grep -q "process.env.CI ? 'dot' : 'html'" "$PROJECT_DIR/playwright.config.ts"; then pass; else fail "T1.b source was not rewritten"; fi
# Backup created with timestamp prefix (8-digit date + _ + 6-digit time)
bak_match=$(find "$PROJECT_DIR/.claude/preflight_bak" -maxdepth 1 -type f -name '*_playwright.config.ts' 2>/dev/null | head -1)
if [[ -n "$bak_match" ]] && [[ "$(basename "$bak_match")" =~ ^[0-9]{8}_[0-9]{6}_playwright.config.ts$ ]]; then
    pass
else
    fail "T1.b backup file with <YYYYMMDD_HHMMSS>_<basename> format not found"
fi
_cleanup "$PROJECT_DIR"

# T1.c: legacy fallback — PREFLIGHT_UI_CONFIG_AUTO_FIX unset, PREFLIGHT_AUTO_FIX=false
_setup
cat > "$PROJECT_DIR/playwright.config.ts" <<'EOF'
export default { reporter: 'html' };
EOF
unset PREFLIGHT_UI_CONFIG_AUTO_FIX
PREFLIGHT_AUTO_FIX=false _preflight_check_ui_test_config
assert_eq "T1.c legacy fallback _PF_FAIL=1" "1" "$_PF_FAIL"
assert_eq "T1.c legacy fallback REPORTER_PATCHED=0" "0" "${PREFLIGHT_UI_REPORTER_PATCHED:-}"
unset PREFLIGHT_AUTO_FIX
_cleanup "$PROJECT_DIR"

# =============================================================================
# T2: reporter: 'dot' — no false positive
# =============================================================================
echo "=== T2: reporter: 'dot' ==="
_setup
cat > "$PROJECT_DIR/playwright.config.ts" <<'EOF'
export default { reporter: 'dot' };
EOF
_preflight_check_ui_test_config
assert_eq "T2 _PF_PASS=1" "1" "$_PF_PASS"
assert_eq "T2 _PF_FAIL=0" "0" "$_PF_FAIL"
assert_eq "T2 _PF_REMEDIATED=0" "0" "$_PF_REMEDIATED"
_cleanup "$PROJECT_DIR"

# =============================================================================
# T3: PW-2 video: 'on' — warn only
# =============================================================================
echo "=== T3: PW-2 video: 'on' ==="
_setup
cat > "$PROJECT_DIR/playwright.config.ts" <<'EOF'
export default { use: { video: 'on' } };
EOF
_preflight_check_ui_test_config
assert_eq "T3 _PF_WARN>=1" "1" "$([[ $_PF_WARN -ge 1 ]] && echo 1 || echo 0)"
assert_eq "T3 _PF_FAIL=0" "0" "$_PF_FAIL"
_cleanup "$PROJECT_DIR"

# =============================================================================
# T4: PW-3 reuseExistingServer: false — warn only
# =============================================================================
echo "=== T4: PW-3 reuseExistingServer: false ==="
_setup
cat > "$PROJECT_DIR/playwright.config.ts" <<'EOF'
export default { webServer: { reuseExistingServer: false } };
EOF
_preflight_check_ui_test_config
assert_eq "T4 _PF_WARN>=1" "1" "$([[ $_PF_WARN -ge 1 ]] && echo 1 || echo 0)"
assert_eq "T4 _PF_FAIL=0" "0" "$_PF_FAIL"
_cleanup "$PROJECT_DIR"

# =============================================================================
# T5: No playwright config — silent skip (no record emitted)
# =============================================================================
echo "=== T5: no playwright config ==="
_setup
# Do not create any *.config files
_preflight_check_ui_test_config
assert_eq "T5 _PF_PASS=0" "0" "$_PF_PASS"
assert_eq "T5 _PF_WARN=0" "0" "$_PF_WARN"
assert_eq "T5 _PF_FAIL=0" "0" "$_PF_FAIL"
assert_eq "T5 _PF_REMEDIATED=0" "0" "$_PF_REMEDIATED"
_cleanup "$PROJECT_DIR"

# =============================================================================
# T6: JV-1 watch: true — fail; auto-fix never patches
# =============================================================================
echo "=== T6: JV-1 watch: true ==="
_setup
cat > "$PROJECT_DIR/vitest.config.ts" <<'EOF'
export default {
  test: {
    watch: true,
  },
};
EOF
PREFLIGHT_UI_CONFIG_AUTO_FIX=true _preflight_check_ui_test_config
assert_eq "T6 _PF_FAIL=1" "1" "$_PF_FAIL"
assert_eq "T6 _PF_REMEDIATED=0" "0" "$_PF_REMEDIATED"
assert_eq "T6 RULE=JV-1" "JV-1" "${PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE:-}"
assert_eq "T6 REPORTER_PATCHED=0" "0" "${PREFLIGHT_UI_REPORTER_PATCHED:-}"
# Source must remain untouched (watch mode never auto-patched)
if grep -q "watch: true" "$PROJECT_DIR/vitest.config.ts"; then pass; else fail "T6 vitest source was modified — watch must not be auto-patched"; fi
_cleanup "$PROJECT_DIR"

# =============================================================================
# T7: CY-1 cypress video: true — warn only
# =============================================================================
echo "=== T7: CY-1 cypress video: true ==="
_setup
cat > "$PROJECT_DIR/cypress.config.ts" <<'EOF'
export default { video: true };
EOF
_preflight_check_ui_test_config
assert_eq "T7 _PF_WARN>=1" "1" "$([[ $_PF_WARN -ge 1 ]] && echo 1 || echo 0)"
assert_eq "T7 _PF_FAIL=0" "0" "$_PF_FAIL"
_cleanup "$PROJECT_DIR"

# =============================================================================
# T8: Full PREFLIGHT_UI_* contract triple exported when PW-1 fires
# =============================================================================
echo "=== T8: contract triple ==="
_setup
cat > "$PROJECT_DIR/playwright.config.ts" <<'EOF'
export default { reporter: 'html' };
EOF
PREFLIGHT_UI_CONFIG_AUTO_FIX=true _preflight_check_ui_test_config
assert_eq "T8 DETECTED=1" "1" "${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED:-}"
assert_eq "T8 RULE=PW-1" "PW-1" "${PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE:-}"
assert_eq "T8 FILE=playwright.config.ts" "playwright.config.ts" "${PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE:-}"
assert_eq "T8 REPORTER_PATCHED=1 (auto-fix)" "1" "${PREFLIGHT_UI_REPORTER_PATCHED:-}"
_cleanup "$PROJECT_DIR"

# =============================================================================
# T9: already CI-guarded reporter — pattern does not match
# =============================================================================
echo "=== T9: already CI-guarded ==="
_setup
cat > "$PROJECT_DIR/playwright.config.ts" <<'EOF'
export default { reporter: process.env.CI ? 'dot' : 'html' };
EOF
_preflight_check_ui_test_config
assert_eq "T9 _PF_PASS=1" "1" "$_PF_PASS"
assert_eq "T9 _PF_FAIL=0" "0" "$_PF_FAIL"
assert_eq "T9 _PF_REMEDIATED=0" "0" "$_PF_REMEDIATED"
# Source untouched
if grep -q "process.env.CI ? 'dot' : 'html'" "$PROJECT_DIR/playwright.config.ts"; then pass; else fail "T9 source was modified"; fi
_cleanup "$PROJECT_DIR"

# =============================================================================
# T10: UI_TEST_CMD unset — full no-op
# =============================================================================
echo "=== T10: UI_TEST_CMD unset ==="
_setup
cat > "$PROJECT_DIR/playwright.config.ts" <<'EOF'
export default { reporter: 'html' };
EOF
unset UI_TEST_CMD
_preflight_check_ui_test_config
assert_eq "T10 _PF_PASS=0" "0" "$_PF_PASS"
assert_eq "T10 _PF_WARN=0" "0" "$_PF_WARN"
assert_eq "T10 _PF_FAIL=0" "0" "$_PF_FAIL"
assert_eq "T10 _PF_REMEDIATED=0" "0" "$_PF_REMEDIATED"
assert_eq "T10 contract var DETECTED unset" "" "${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED:-}"
_cleanup "$PROJECT_DIR"

# Also: UI_TEST_CMD=true (the no-op default) → same skip
_setup
export UI_TEST_CMD="true"
cat > "$PROJECT_DIR/playwright.config.ts" <<'EOF'
export default { reporter: 'html' };
EOF
_preflight_check_ui_test_config
assert_eq "T10b UI_TEST_CMD=true → no-op" "0" "$_PF_FAIL"
_cleanup "$PROJECT_DIR"

# Disabled toggle: PREFLIGHT_UI_CONFIG_AUDIT_ENABLED=false → no-op
_setup
cat > "$PROJECT_DIR/playwright.config.ts" <<'EOF'
export default { reporter: 'html' };
EOF
PREFLIGHT_UI_CONFIG_AUDIT_ENABLED=false _preflight_check_ui_test_config
assert_eq "T10c audit disabled → no fail" "0" "$_PF_FAIL"
assert_eq "T10c audit disabled → contract DETECTED unset" "" "${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED:-}"
_cleanup "$PROJECT_DIR"

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  M131 preflight UI config: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] || exit 1
