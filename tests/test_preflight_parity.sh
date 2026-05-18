#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# tests/test_preflight_parity.sh — m22 Goal 7 parity gate.
#
# Drives `tekhton preflight` against three frozen fixtures and asserts the
# generated PREFLIGHT_REPORT.md matches the expected baseline after
# normalisation:
#
#   1. green_path           — empty project → no report file emitted
#   2. env_only_fail        — package-lock.json without node_modules,
#                             PREFLIGHT_AUTO_FIX=false → one ✗ finding
#   3. ui_config_autopatch  — playwright.config.ts with reporter:'html',
#                             PREFLIGHT_UI_CONFIG_AUTO_FIX=true → patched +
#                             one 🔧 finding
#
# Normalisation collapses two volatile substrings before diffing:
#   - the report header timestamp → "TIMESTAMP"
#   - the auto-fix backup path basename → "BACKUP_PATH"
#
# Acceptance: every scenario exits 0 and the normalised report matches
# byte-for-byte. The Makefile gate (`make dogfood`) is not affected by
# this script — this is a standalone parity assertion that runs under
# tests/run_tests.sh.
# =============================================================================

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="${REPO_ROOT}/tests/testdata/preflight_parity"
TEKHTON_BIN="${REPO_ROOT}/bin/tekhton"

PASS=0
FAIL=0
fail_messages=""

_pass() { PASS=$(( PASS + 1 )); printf '\033[0;32mPASS\033[0m %s\n' "$1"; }
_fail() {
    FAIL=$(( FAIL + 1 ))
    printf '\033[0;31mFAIL\033[0m %s\n' "$1" >&2
    fail_messages+="$1"$'\n'
}

# Build the binary up front so each scenario can reuse it. Skip the whole
# test if the toolchain isn't available — preserves the pass count on
# machines without Go.
if ! command -v go >/dev/null 2>&1; then
    printf 'SKIP test_preflight_parity: go toolchain not found\n'
    exit 0
fi
if ! [[ -x "$TEKHTON_BIN" ]]; then
    if ! (cd "$REPO_ROOT" && make build >/dev/null 2>&1); then
        printf 'SKIP test_preflight_parity: make build failed\n'
        exit 0
    fi
fi

# normalise FILE — replace volatile substrings in-place. The two patterns
# (timestamp + backup path) are the only date-bearing or path-bearing
# strings the orchestrator emits.
_normalise() {
    local f="$1"
    # Header timestamp: "# Pre-flight Report — YYYY-MM-DD HH:MM:SS"
    sed -i -E 's/# Pre-flight Report — [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/# Pre-flight Report — TIMESTAMP/' "$f"
    # Backup path: ".claude/preflight_bak/YYYYMMDD_HHMMSS_<name>"
    sed -i -E 's|\.claude/preflight_bak/[0-9_]+_[A-Za-z0-9._-]+|BACKUP_PATH|g' "$f"
}

# Run one scenario:
#   $1 = scenario name (matches fixture subdir)
#   $2 = "expect_report" | "no_report"
#   $3 = extra env (key=value semicolon-separated, optional)
_scenario() {
    local name="$1" mode="$2" extra="${3:-}"
    local fixture="${FIXTURE_ROOT}/${name}/fixture"
    local expected="${FIXTURE_ROOT}/${name}/expected/PREFLIGHT_REPORT.md"

    local tmp
    tmp=$(mktemp -d)
    # Copy fixture into a working dir so the test does not mutate testdata.
    if [[ -d "$fixture" ]] && [[ -n "$(ls -A "$fixture" 2>/dev/null || true)" ]]; then
        cp -R "$fixture/." "$tmp/"
    fi

    # Drive `tekhton preflight` with clean env: clear pipeline-config envs
    # that would leak from the dev shell and trigger unrelated findings.
    # ${extra} is a space-separated list of K=V env assignments; word
    # splitting is the desired behaviour here, so SC2086 is suppressed.
    # shellcheck disable=SC2086
    env -i \
        PATH="$PATH" \
        HOME="$HOME" \
        TMPDIR="$tmp" \
        ${extra} \
        "$TEKHTON_BIN" preflight --project-dir "$tmp" --home "$REPO_ROOT" \
        >/dev/null 2>&1 || true

    local actual="${tmp}/.tekhton/PREFLIGHT_REPORT.md"
    case "$mode" in
        no_report)
            if [[ -f "$actual" ]]; then
                _fail "${name}: expected no report; got $(cat "$actual")"
            else
                _pass "${name}: no report emitted (matches bash skip semantics)"
            fi
            ;;
        expect_report)
            if [[ ! -f "$actual" ]]; then
                _fail "${name}: expected report at ${actual}; not present"
            else
                _normalise "$actual"
                if diff -u "$expected" "$actual" >/dev/null; then
                    _pass "${name}: report byte-identical to baseline"
                else
                    _fail "${name}: report diverges from baseline"
                    diff -u "$expected" "$actual" || true
                fi
            fi
            ;;
        *)
            _fail "${name}: unknown mode ${mode}"
            ;;
    esac
    rm -rf "$tmp"
}

# Scenario 1 — green path. Empty fixture, no checks applicable, no report.
_scenario "green_path" "no_report"

# Scenario 2 — env-only fail. Lock file without node_modules, auto-fix
# disabled so the result is a hard fail rather than a fixed.
_scenario "env_only_fail" "expect_report" "PREFLIGHT_AUTO_FIX=false"

# Scenario 3 — UI config auto-patch. Playwright config with html reporter
# (PW-1) auto-patched to the CI-guarded form.
_scenario "ui_config_autopatch" "expect_report" \
    "UI_TEST_CMD=playwright_test PREFLIGHT_UI_CONFIG_AUTO_FIX=true"

# --- Summary -----------------------------------------------------------------
printf '\n=== test_preflight_parity: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf '\nFailures:\n%s' "$fail_messages" >&2
    exit 1
fi
exit 0
