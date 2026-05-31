#!/usr/bin/env bash
# tests/test_crawler_parity.sh — m30.1 parity gate.
#
# Runs `tekhton crawler crawl` against each fixture under
# internal/crawler/testdata/{small_repo,monorepo,with_submodules}/ and
# byte-diffs the produced .claude/index/ artifact set against the frozen
# bash baseline under internal/crawler/testdata/baselines/<fixture>/.
#
# Volatile fields (scan_date / scan_commit in meta.json) are normalised
# via tests/lib/normalize_index.sh before diffing.
#
# Self-skips cleanly when the Go binary is unavailable (so contributors
# who haven't run `make build` aren't blocked).
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEKHTON_DIR="$(cd "${TESTS_DIR}/.." && pwd)"

# Resolve tekhton binary: explicit override, then PATH, then ./tekhton.
TEKHTON_BIN="${TEKHTON_BIN:-}"
if [[ -z "$TEKHTON_BIN" ]]; then
    if command -v tekhton >/dev/null 2>&1; then
        TEKHTON_BIN="$(command -v tekhton)"
    elif [[ -x "${TEKHTON_DIR}/tekhton" ]]; then
        TEKHTON_BIN="${TEKHTON_DIR}/tekhton"
    fi
fi
if [[ -z "$TEKHTON_BIN" ]] || [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "SKIP $(basename "${BASH_SOURCE[0]}"): tekhton Go binary not built (set TEKHTON_BIN or run 'make build')"
    exit 0
fi

# shellcheck source=tests/lib/parity.sh
source "${TESTS_DIR}/lib/parity.sh"

FIXTURE_ROOT="${TEKHTON_DIR}/internal/crawler/testdata"
BASELINES="${FIXTURE_ROOT}/baselines"
WORK="$(mktemp -d -t crawler-parity.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

ARTIFACTS=(
    "tree.txt"
    "inventory.jsonl"
    "dependencies.json"
    "configs.json"
    "tests.json"
    "samples/manifest.json"
    "meta.json"
)

for fixture in small_repo monorepo with_submodules; do
    project="${FIXTURE_ROOT}/${fixture}"
    expected="${BASELINES}/${fixture}"
    actual="${WORK}/${fixture}"

    "${TEKHTON_BIN}" crawler crawl \
        --project-dir "${project}" \
        --index-dir "${actual}" \
        --budget 30000 >/dev/null

    bash "${TESTS_DIR}/lib/normalize_index.sh" "${actual}"

    for f in "${ARTIFACTS[@]}"; do
        parity_assert_equal "${fixture}/${f}" \
            "${expected}/${f}" "${actual}/${f}"
    done
done

parity_summary "crawler-parity"
