#!/usr/bin/env bash
# =============================================================================
# tests/test_detect_parity.sh — m29 parity gate (extended for m29.2).
#
# Scope: asserts byte-identical output between the captured bash baselines
# (tests/testdata/detect/baselines/<fixture>.md) and the Go engine's
# `tekhton detect summary --markdown` output across the ENTIRE rendered
# markdown — no per-section extraction, no normalization beyond timestamps.
# Every detector ported in m29.1 + m29.2 contributes to the diff.
#
# The baselines were captured once via scripts/capture-detect-baselines.sh
# at m29.1 close (the three production fixtures) and during m29.2 (the
# empty fixture). They are FROZEN — drift here means the Go port diverged,
# not that the baseline is stale.
#
# Skips cleanly when the Go toolchain or built binary is unavailable so the
# test never blocks contributors who haven't run `make build`.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="${REPO_ROOT}/tests/testdata/detect"
BASELINE_DIR="${FIXTURE_ROOT}/baselines"
TEKHTON_BIN="${REPO_ROOT}/bin/tekhton"

# shellcheck source=tests/lib/parity.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/tests/lib/parity.sh"

if ! command -v go >/dev/null 2>&1; then
    printf 'SKIP test_detect_parity: go toolchain not found\n'
    exit 0
fi
if ! [[ -x "$TEKHTON_BIN" ]]; then
    if ! (cd -- "$REPO_ROOT" && make build >/dev/null 2>&1); then
        printf 'SKIP test_detect_parity: make build failed\n'
        exit 0
    fi
fi

_scenario() {
    local fixture="$1"
    local baseline="${BASELINE_DIR}/${fixture}.md"
    local actual
    actual=$(mktemp)
    "${TEKHTON_BIN}" detect summary \
        --markdown \
        --project-dir "${FIXTURE_ROOT}/${fixture}" \
        > "$actual" 2>/dev/null || {
            parity_fail "${fixture}: tekhton detect summary exited non-zero"
            rm -f -- "$actual"
            return
        }

    parity_assert_equal "${fixture}" "$baseline" "$actual"
}

_scenario "monorepo-pnpm"
_scenario "polyglot-services"
_scenario "ai-heavy-mess"
_scenario "empty"

parity_summary "test_detect_parity" || exit 1
exit 0
