#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# preflight_checks_ui.sh — UI Test Framework Config Audit (M131)
#
# Sourced by tekhton.sh after preflight_checks_env.sh — do not run directly.
# Provides:
#   _preflight_check_ui_test_config (dispatcher)
#   _pf_uitest_playwright            (scanner)
#   _pf_uitest_playwright_fix_reporter (auto-fix helper)
#   _pf_uitest_cypress               (scanner)
#   _pf_uitest_jest_watch            (scanner)
# Depends on: preflight.sh (_pf_record)
#
# Detects test framework config patterns that would cause Tekhton's gated
# subprocess execution to hang on an interactive serve-and-wait loop or
# never-terminating watch mode. The four PREFLIGHT_UI_* env vars exported
# below are public contract consumed by the UI gate normalizer, RUN_SUMMARY
# enrichment, diagnose rules, and integration tests. Renaming or changing
# value semantics breaks downstream consumers silently — see Watch For in
# m131 milestone definition.
# =============================================================================

# =============================================================================
# Dispatcher: _preflight_check_ui_test_config
# =============================================================================
_preflight_check_ui_test_config() {
    local proj="${PROJECT_DIR:-.}"

    # Reset module state so a re-invocation in the same shell starts clean.
    # PREFLIGHT_UI_* vars are public contract consumed by downstream consumers;
    # they must reflect this preflight run only, not stale values from a prior
    # run in the same shell. Preflight runs once per pipeline invocation — do NOT
    # reset between iterations of run_complete_loop — only here at the top of
    # preflight.
    unset PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED \
          PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE \
          PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE \
          PREFLIGHT_UI_REPORTER_PATCHED

    # m136 enable knob; inline default keeps m131 functional pre-m136.
    [[ "${PREFLIGHT_UI_CONFIG_AUDIT_ENABLED:-true}" == "true" ]] || return 0

    # Only run when a UI test command is configured (skip the no-op default).
    [[ -z "${UI_TEST_CMD:-}" || "${UI_TEST_CMD}" == "true" ]] && return 0

    _pf_uitest_playwright "$proj"
    _pf_uitest_cypress    "$proj"
    _pf_uitest_jest_watch "$proj"
}

# =============================================================================
# Playwright scanner
# =============================================================================
_pf_uitest_playwright() {
    local proj="$1"
    local cfg_file=""
    local f

    local candidates=(
        "${proj}/playwright.config.ts"
        "${proj}/playwright.config.js"
        "${proj}/playwright.config.mjs"
        "${proj}/playwright.config.cjs"
    )
    for f in "${candidates[@]}"; do
        if [[ -f "$f" ]]; then
            cfg_file="$f"
            break
        fi
    done

    [[ -z "$cfg_file" ]] && return 0

    local issues_found=0

    # PW-1: html reporter (FAIL — auto-fix candidate). Pattern is conservative;
    # CI-guarded forms like `process.env.CI ? 'dot' : 'html'` do not match.
    if grep -qP "reporter\s*:\s*['\"]html['\"]|reporter\s*:\s*\[\s*['\"]html['\"]\s*\]" \
        "$cfg_file" 2>/dev/null; then
        _pf_uitest_playwright_fix_reporter "$cfg_file" "$proj"
        issues_found=1
    fi

    # PW-2: video on / retain-on-failure (WARN only — trade-off decision).
    if grep -qP "video\s*:\s*['\"]on['\"]|video\s*:\s*['\"]retain-on-failure['\"]" \
        "$cfg_file" 2>/dev/null; then
        _pf_record "warn" "UI Config (Playwright) — video recording" \
"playwright.config video='on' or 'retain-on-failure' produces large artifacts.
Consider: video: process.env.CI ? 'off' : 'retain-on-failure'"
        issues_found=1
    fi

    # PW-3: webServer.reuseExistingServer: false (WARN only).
    if grep -qP "reuseExistingServer\s*:\s*false" "$cfg_file" 2>/dev/null; then
        _pf_record "warn" "UI Config (Playwright) — reuseExistingServer: false" \
"playwright.config webServer.reuseExistingServer=false can cause the test runner
to hang if the dev server port is already in use.
Consider: reuseExistingServer: !process.env.CI"
        issues_found=1
    fi

    if [[ "$issues_found" -eq 0 ]]; then
        _pf_record "pass" "UI Config (Playwright)" \
            "No interactive-mode config issues detected in ${cfg_file##*/}."
    fi
}

# =============================================================================
# Playwright auto-fix helper for PW-1
# =============================================================================
_pf_uitest_playwright_fix_reporter() {
    local cfg_file="$1"
    local proj="$2"
    # PREFLIGHT_BAK_DIR is m136-declared; m135 reads via the same fallback.
    local bak_dir="${PREFLIGHT_BAK_DIR:-${proj}/.claude/preflight_bak}"
    # Filename: <YYYYMMDD_HHMMSS>_<basename> — m135 retention sort relies on
    # lexicographic == chronological ordering. Format mismatch silently
    # breaks trim ordering.
    local ts base
    ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo "00000000_000000")
    base=$(basename "$cfg_file")
    local bak_file="${bak_dir}/${ts}_${base}"

    # m136-specific knob takes precedence; legacy m55 PREFLIGHT_AUTO_FIX is
    # the fallback so existing user configs still work; default true.
    if [[ "${PREFLIGHT_UI_CONFIG_AUTO_FIX:-${PREFLIGHT_AUTO_FIX:-true}}" != "true" ]]; then
        _pf_record "fail" "UI Config (Playwright) — html reporter" \
"${cfg_file##*/} sets reporter: 'html'. Playwright's HTML reporter launches an
interactive serve-and-wait loop that is incompatible with Tekhton's timed gates.

REQUIRED MANUAL FIX:
  Change:  reporter: 'html'
  To:      reporter: process.env.CI ? 'dot' : 'html'

Or, in tekhton pipeline.conf:
  PLAYWRIGHT_HTML_OPEN=never
  CI=1  (forces non-interactive mode without changing source)

Auto-fix is disabled (PREFLIGHT_UI_CONFIG_AUTO_FIX=false, or legacy
PREFLIGHT_AUTO_FIX=false). Set either to true to allow Tekhton to patch
the config file automatically."
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE="PW-1"
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE="${cfg_file##*/}"
        export PREFLIGHT_UI_REPORTER_PATCHED=0
        return
    fi

    mkdir -p "$bak_dir" 2>/dev/null || true
    if ! cp "$cfg_file" "$bak_file" 2>/dev/null; then
        _pf_record "fail" "UI Config (Playwright) — html reporter" \
"Failed to create backup at ${bak_file##"$proj"/}. Skipping auto-patch."
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE="PW-1"
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE="${cfg_file##*/}"
        export PREFLIGHT_UI_REPORTER_PATCHED=0
        return
    fi

    # In-place sed: rewrite simple scalar and single-entry array forms only.
    # Nested tuple reporters fall through to m126's runtime detection path.
    if sed -i \
        -e "s|reporter: 'html'|reporter: process.env.CI ? 'dot' : 'html'|g" \
        -e "s|reporter: \"html\"|reporter: process.env.CI ? 'dot' : 'html'|g" \
        -e "s|reporter: \['html'\]|reporter: process.env.CI ? 'dot' : 'html'|g" \
        -e "s|reporter: \[\"html\"\]|reporter: process.env.CI ? 'dot' : 'html'|g" \
        "$cfg_file" 2>/dev/null; then
        _pf_record "fixed" "UI Config (Playwright) — html reporter" \
"Auto-patched reporter: 'html' → CI-guarded form in ${cfg_file##*/}.
Original saved to: ${bak_file##"$proj"/}
The gate will use 'dot' reporter in CI mode (no interactive server).
Review and commit the change when satisfied."
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE="PW-1"
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE="${cfg_file##*/}"
        export PREFLIGHT_UI_REPORTER_PATCHED=1
        if command -v emit_event >/dev/null 2>&1; then
            emit_event "preflight_ui_config_patch" "preflight" \
                "{\"file\":\"${cfg_file##*/}\",\"rule\":\"PW-1\",\"action\":\"reporter_ci_guard\"}" \
                "" "" "" >/dev/null 2>&1 || true
        fi
        # m135 retention trim — defensive declare-f guard so this ships
        # cleanly before m135 lands.
        if declare -f _trim_preflight_bak_dir >/dev/null 2>&1; then
            _trim_preflight_bak_dir "$bak_dir" || true
        fi
    else
        _pf_record "fail" "UI Config (Playwright) — html reporter" \
"Failed to auto-patch ${cfg_file##*/}. See manual fix instructions.
Backup (if created): ${bak_file##"$proj"/}"
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE="PW-1"
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE="${cfg_file##*/}"
        export PREFLIGHT_UI_REPORTER_PATCHED=0
    fi
}

# =============================================================================
# Cypress scanner — WARN-only rules, no auto-patch
# =============================================================================
_pf_uitest_cypress() {
    local proj="$1"
    local cfg_file=""
    local f

    local candidates=(
        "${proj}/cypress.config.ts"
        "${proj}/cypress.config.js"
        "${proj}/cypress.config.mjs"
    )
    for f in "${candidates[@]}"; do
        if [[ -f "$f" ]]; then
            cfg_file="$f"
            break
        fi
    done

    [[ -z "$cfg_file" ]] && return 0

    local issues_found=0

    # CY-1: video: true (WARN — large artifacts but not blocking).
    if grep -qP "video\s*:\s*true" "$cfg_file" 2>/dev/null; then
        _pf_record "warn" "UI Config (Cypress) — video: true" \
"cypress.config has video: true (default). Video recording produces large artifacts.
Consider: video: !!process.env.CI === false"
        issues_found=1
    fi

    # CY-2: mochawesome reporter without --exit (WARN — may orphan reporter).
    if grep -qP "reporter\s*:\s*['\"]mochawesome['\"]" "$cfg_file" 2>/dev/null; then
        if ! printf '%s' "${UI_TEST_CMD:-}" | grep -q -- "--exit"; then
            _pf_record "warn" "UI Config (Cypress) — mochawesome reporter" \
"cypress.config uses mochawesome reporter. Without --exit in UI_TEST_CMD, the
reporter process may not terminate.
Consider adding: --exit to UI_TEST_CMD in pipeline.conf"
            issues_found=1
        fi
    fi

    if [[ "$issues_found" -eq 0 ]]; then
        _pf_record "pass" "UI Config (Cypress)" \
            "No interactive-mode config issues detected in ${cfg_file##*/}."
    fi
}

# =============================================================================
# Jest / Vitest watch-mode scanner — FAIL, no auto-patch
# =============================================================================
_pf_uitest_jest_watch() {
    local proj="$1"
    local cfg_file=""
    local f

    local candidates=(
        "${proj}/vitest.config.ts"
        "${proj}/vitest.config.js"
        "${proj}/jest.config.ts"
        "${proj}/jest.config.js"
        "${proj}/jest.config.mjs"
    )
    for f in "${candidates[@]}"; do
        if [[ -f "$f" ]]; then
            cfg_file="$f"
            break
        fi
    done

    [[ -z "$cfg_file" ]] && return 0

    local issues_found=0

    # JV-1: watch: true / watchAll: true (FAIL — process never terminates).
    if grep -qP "^\s*(watch|watchAll)\s*:\s*true" "$cfg_file" 2>/dev/null; then
        _pf_record "fail" "UI Config (Jest/Vitest) — watch mode enabled" \
"${cfg_file##*/} has watch: true or watchAll: true. Watch mode causes the test
process to run indefinitely, which will always trigger Tekhton's UI_TEST_TIMEOUT.

REQUIRED FIX — choose one:
  a) Remove watch: true from ${cfg_file##*/}
  b) Add --run flag to TEST_CMD in pipeline.conf (Vitest: vitest run ...)
  c) Set CI=true in the environment (disables watch in most frameworks)

Tekhton does not auto-patch watch mode config. This requires deliberate choice."
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE="JV-1"
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE="${cfg_file##*/}"
        export PREFLIGHT_UI_REPORTER_PATCHED=0
        issues_found=1
    fi

    if [[ "$issues_found" -eq 0 ]]; then
        _pf_record "pass" "UI Config (Jest/Vitest)" \
            "No watch-mode config issues detected in ${cfg_file##*/}."
    fi
}
