#!/usr/bin/env bash
# =============================================================================
# tests/test_detect_parity.sh — m29.1 parity gate.
#
# Scope: asserts byte-identical output between the captured bash baselines
# (tests/testdata/detect/baselines/<fixture>.md) and the Go engine's
# `tekhton detect summary --markdown` output for the three sections m29.1
# ports:
#
#   ### Project Type
#   ### Languages
#   ### Frameworks
#
# Every other section of the bash baseline is rendered from the bash
# detectors still in lib/detect*.sh — m29.1 does NOT port those, so the Go
# engine emits stub rows for them. m29.2 extends this gate to assert every
# section once those detectors land.
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

# _extract_sections FILE — keep only the Project Type line, the Languages
# table block, and the Frameworks block. Stop at the next "###" header that
# is not one of these three. Empty leading/trailing whitespace is trimmed.
# shellcheck disable=SC2317  # invoked via parity_assert_equal callback
_extract_sections() {
    local f="$1"
    local tmp
    tmp=$(mktemp)
    awk '
        /^### Project Type:/  { keep=1 }
        /^### Languages/      { keep=1 }
        /^### Frameworks/     { keep=1 }
        /^### / && $0 !~ /^### (Project Type|Languages|Frameworks)/ { keep=0 }
        keep { print }
    ' "$f" > "$tmp"
    mv -- "$tmp" "$f"
}

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

    local expected_extracted
    expected_extracted=$(mktemp)
    cp -- "$baseline" "$expected_extracted"
    _extract_sections "$expected_extracted"

    parity_assert_equal "${fixture}" "$expected_extracted" "$actual" _extract_sections
    rm -f -- "$expected_extracted"
}

_scenario "monorepo-pnpm"
_scenario "polyglot-services"
_scenario "ai-heavy-mess"

parity_summary "test_detect_parity" || exit 1
exit 0
