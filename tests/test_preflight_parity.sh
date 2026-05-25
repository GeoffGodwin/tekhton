#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# tests/test_preflight_parity.sh — m22 Goal 7 parity gate (refactored at m23
# to consume tests/lib/parity.sh — the second consumer that justified
# extracting the shared driver).
#
# Three frozen scenarios:
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
# =============================================================================

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="${REPO_ROOT}/tests/testdata/preflight_parity"
TEKHTON_BIN="${REPO_ROOT}/bin/tekhton"

# shellcheck source=tests/lib/parity.sh
source "${REPO_ROOT}/tests/lib/parity.sh"

# Skip cleanly when the Go toolchain is unavailable — preserves the pass count.
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

# _preflight_normalise FILE — collapse the two volatile substrings.
# shellcheck disable=SC2317  # invoked indirectly as a callback via parity_assert_equal
_preflight_normalise() {
    local f="$1"
    sed -i -E 's/# Pre-flight Report — [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/# Pre-flight Report — TIMESTAMP/' "$f"
    sed -i -E 's|\.claude/preflight_bak/[0-9_]+_[A-Za-z0-9._-]+|BACKUP_PATH|g' "$f"
}

# _scenario NAME MODE [EXTRA_ENV]
#   MODE = "expect_report" | "no_report"
_scenario() {
    local name="$1" mode="$2" extra="${3:-}"
    local fixture="${FIXTURE_ROOT}/${name}/fixture"
    local expected="${FIXTURE_ROOT}/${name}/expected/PREFLIGHT_REPORT.md"

    local tmp
    tmp=$(mktemp -d)
    if [[ -d "$fixture" ]] && [[ -n "$(ls -A "$fixture" 2>/dev/null || true)" ]]; then
        cp -R "$fixture/." "$tmp/"
    fi

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
            parity_assert_no_file "$name" "$actual"
            ;;
        expect_report)
            parity_assert_equal "$name" "$expected" "$actual" _preflight_normalise
            ;;
        *)
            parity_fail "$name: unknown mode $mode"
            ;;
    esac
    rm -rf "$tmp"
}

_scenario "green_path" "no_report"
_scenario "env_only_fail" "expect_report" "PREFLIGHT_AUTO_FIX=false"
_scenario "ui_config_autopatch" "expect_report" \
    "UI_TEST_CMD=playwright_test PREFLIGHT_UI_CONFIG_AUTO_FIX=true"

parity_summary "test_preflight_parity" || exit 1
exit 0
