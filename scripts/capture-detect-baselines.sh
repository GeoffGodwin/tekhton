#!/usr/bin/env bash
# =============================================================================
# scripts/capture-detect-baselines.sh — Regenerate the m29 detect parity-gate
# baselines from the current bash detect tree.
#
# Run ONCE at m29.1 close. After m29.1 closes, the baselines are FROZEN; m29.2
# must match them byte-for-byte from the Go engine. A divergence between Go
# output and the captured baseline means the Go port diverged, not that the
# baseline is wrong. If the bash side legitimately needs to change after
# m29.1, that's a new milestone with a fresh baseline capture — do not
# silently regen.
#
# The script sources the canonical lib/detect*.sh tree and writes the bash
# format_detection_report output to tests/testdata/detect/baselines/<fixture>.md
# for each of the three fixtures (monorepo-pnpm, polyglot-services,
# ai-heavy-mess).
#
# Set +e/+u/+o pipefail are deliberate AFTER the source block — every
# lib/detect*.sh file ships with `set -euo pipefail` at the top, which is
# inherited by the sourcing shell. Several detector functions exit non-zero
# in their normal "no signal" path (last test was a missing manifest), so we
# disable strict mode before invoking the report so the function returns
# cleanly instead of killing the shell.
# =============================================================================

set -euo pipefail

TEKHTON_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="${TEKHTON_HOME}/tests/testdata/detect"
BASELINE_DIR="${FIXTURE_ROOT}/baselines"

if [[ ! -d "$FIXTURE_ROOT" ]]; then
    printf 'capture-detect-baselines: fixture root missing: %s\n' "$FIXTURE_ROOT" >&2
    exit 1
fi
mkdir -p -- "$BASELINE_DIR"

# Stub the logging helpers normally provided by lib/common.sh so we can
# source the detect tree standalone.
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# shellcheck disable=SC1091  # sourced at runtime from TEKHTON_HOME — paths resolved per invocation
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/detect_commands.sh"
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/detect_workspaces.sh"
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/detect_services.sh"
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/detect_ci.sh"
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/detect_infrastructure.sh"
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/detect_test_frameworks.sh"
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/detect_doc_quality.sh"
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/detect_report.sh"

# Detector bodies short-circuit via `&&`-chained tests; the trailing test
# returns non-zero in the "no match" path. Disable strict mode so those
# returns don't kill the shell here.
set +e
set +u
set +o pipefail

_capture_one() {
    local fixture="$1"
    local fixture_dir="${FIXTURE_ROOT}/${fixture}"
    local baseline_file="${BASELINE_DIR}/${fixture}.md"

    if [[ ! -d "$fixture_dir" ]]; then
        printf 'capture-detect-baselines: fixture missing: %s\n' "$fixture_dir" >&2
        return 1
    fi

    printf 'capture-detect-baselines: %s -> %s\n' "$fixture" "$baseline_file"
    format_detection_report "$fixture_dir" > "$baseline_file"
}

_capture_one "monorepo-pnpm"
_capture_one "polyglot-services"
_capture_one "ai-heavy-mess"

printf 'capture-detect-baselines: 3 baselines refreshed under %s\n' "$BASELINE_DIR"
