#!/usr/bin/env bash
# scripts/self-host-check.sh — V4 self-host smoke harness.
#
# Adds two changes vs the V3 self-host smoke run:
#   1. Builds the Go binary first via `make build` and prepends `bin/` to $PATH.
#   2. Asserts `tekhton --version` matches the contents of repo-root VERSION.
#
# The bash pipeline runs the same way it did before — the Go binary's presence
# on $PATH is observed but unused. This script must remain idempotent.
#
# Exit codes:
#   0 = all checks passed
#   1 = one or more checks failed

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$REPO_ROOT"

# --- helpers ---------------------------------------------------------------

_log()  { printf '\033[0;36m[self-host]\033[0m %s\n' "$*"; }
_ok()   { printf '\033[0;32m[self-host] PASS\033[0m %s\n' "$*"; }
_fail() { printf '\033[0;31m[self-host] FAIL\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Build Go binary ---------------------------------------------------

if ! command -v go >/dev/null 2>&1; then
    _fail "Go toolchain not found on PATH. Install per docs/go-build.md."
fi

_log "Building Go binary via 'make build'..."
make build >/dev/null

[[ -x "${REPO_ROOT}/bin/tekhton" ]] || _fail "make build did not produce bin/tekhton."
_ok "bin/tekhton built."

# --- 2. Prepend bin/ to PATH ---------------------------------------------

export PATH="${REPO_ROOT}/bin:${PATH}"
_log "PATH now begins with ${REPO_ROOT}/bin"

# --- 3. Assert tekhton --version matches VERSION -------------------------

[[ -f VERSION ]] || _fail "VERSION file not found at repo root."
expected="$(tr -d '[:space:]' < VERSION)"
[[ -n "$expected" ]] || _fail "VERSION file is empty."

actual="$(tekhton --version | tr -d '[:space:]')"
[[ "$actual" == "$expected" ]] \
    || _fail "tekhton --version output '${actual}' does not match VERSION '${expected}'."
_ok "tekhton --version matches VERSION (${expected})."

# --- 4. Confirm bash pipeline starts with Go binary on PATH --------------
# tekhton.sh --version is a no-op early exit — it proves the bash entry point
# loads, finds VERSION, and exits cleanly with the Go binary now reachable on
# PATH. Heavier --dry-run smoke runs are gated behind TEKHTON_SELF_HOST_DRY_RUN
# because they invoke Claude CLI agents and require auth not present in CI.

_log "Running tekhton.sh --version (bash entry point)..."
bash_version="$(./tekhton.sh --version | tr -d '\r')"
case "$bash_version" in
    *"${expected}"*) _ok "tekhton.sh --version reports ${bash_version}." ;;
    *) _fail "tekhton.sh --version did not surface VERSION '${expected}': '${bash_version}'." ;;
esac

if [[ "${TEKHTON_SELF_HOST_DRY_RUN:-0}" == "1" ]]; then
    if ! command -v claude >/dev/null 2>&1; then
        _fail "TEKHTON_SELF_HOST_DRY_RUN=1 set but 'claude' CLI not found."
    fi
    _log "Running tekhton.sh --dry-run on fixture task..."
    fixture_task="self-host-check fixture: smoke verify only"
    ./tekhton.sh --dry-run "$fixture_task" >/dev/null \
        || _fail "tekhton.sh --dry-run exited non-zero."
    _ok "tekhton.sh --dry-run smoke run exited 0."
else
    _log "Skipping --dry-run (set TEKHTON_SELF_HOST_DRY_RUN=1 to enable; needs Claude CLI auth)."
fi

# --- 5. Verify bin/tekhton is reachable as just 'tekhton' on PATH --------

actual_path="$(command -v tekhton)"
[[ "$actual_path" == "${REPO_ROOT}/bin/tekhton" ]] \
    || _fail "tekhton resolves to '${actual_path}', expected '${REPO_ROOT}/bin/tekhton'."
_ok "tekhton resolves to ${actual_path}."

_log "All self-host checks passed."
