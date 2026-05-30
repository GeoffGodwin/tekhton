#!/usr/bin/env bash
# =============================================================================
# scripts/capture-detect-baselines.sh — Regenerate the m29 detect parity-gate
# baselines from the Go engine.
#
# At m29.1 close the baselines were captured once from the bash detect tree
# (the parity contract). At m29.2 the bash detect files were deleted; the
# Go engine is now the canonical implementation. This script captures Go
# output for any NEW fixture added after m29.2 — it does NOT regenerate the
# m29.1-locked baselines (those stay frozen as the bash⇄Go parity record).
#
# To capture a new fixture: add it to FIXTURES below, run the script, commit
# the new baseline alongside the fixture. The existing baselines stay
# untouched.
# =============================================================================

set -euo pipefail

TEKHTON_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="${TEKHTON_HOME}/tests/testdata/detect"
BASELINE_DIR="${FIXTURE_ROOT}/baselines"
TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"

if [[ ! -d "$FIXTURE_ROOT" ]]; then
    printf 'capture-detect-baselines: fixture root missing: %s\n' "$FIXTURE_ROOT" >&2
    exit 1
fi
if [[ ! -x "$TEKHTON_BIN" ]]; then
    if ! (cd -- "$TEKHTON_HOME" && make build >/dev/null 2>&1); then
        printf 'capture-detect-baselines: bin/tekhton missing and make build failed\n' >&2
        exit 1
    fi
fi
mkdir -p -- "$BASELINE_DIR"

_capture_one() {
    local fixture="$1"
    local fixture_dir="${FIXTURE_ROOT}/${fixture}"
    local baseline_file="${BASELINE_DIR}/${fixture}.md"

    if [[ ! -d "$fixture_dir" ]]; then
        printf 'capture-detect-baselines: fixture missing: %s\n' "$fixture_dir" >&2
        return 1
    fi

    printf 'capture-detect-baselines: %s -> %s\n' "$fixture" "$baseline_file"
    "$TEKHTON_BIN" detect summary --markdown --project-dir "$fixture_dir" > "$baseline_file"
}

FIXTURES=("monorepo-pnpm" "polyglot-services" "ai-heavy-mess" "empty")
for f in "${FIXTURES[@]}"; do
    _capture_one "$f"
done

printf 'capture-detect-baselines: %d baselines refreshed under %s\n' "${#FIXTURES[@]}" "$BASELINE_DIR"
