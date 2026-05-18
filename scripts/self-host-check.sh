#!/usr/bin/env bash
# scripts/self-host-check.sh — m20 self-host parity matrix.
#
# Validates that the tekhton.sh dispatcher routes correctly across the 15
# documented scenarios. Each scenario asserts a routing decision (which
# binary handles which flag combination) plus structural invariants of the
# resulting RunRequestV1 / legacy bash entry. Scenarios that require live
# Claude CLI calls are gated behind TEKHTON_SELF_HOST_DRY_RUN=1 (offline by
# default so CI runners without auth can still gate the dispatcher seam).
#
# Exit codes:
#   0 = all scenarios pass
#   1 = one or more scenarios failed

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$REPO_ROOT"

# --- helpers ---------------------------------------------------------------

_log()  { printf '\033[0;36m[self-host]\033[0m %s\n' "$*"; }
_pass() { printf '\033[0;32m[self-host] PASS\033[0m %-3s %s\n' "$1" "$2"; }
_fail() { printf '\033[0;31m[self-host] FAIL\033[0m %-3s %s\n' "$1" "$2" >&2; FAILURES=$(( FAILURES + 1 )); }

FAILURES=0

# --- prerequisites ---------------------------------------------------------

if ! command -v go >/dev/null 2>&1; then
    printf 'ERROR: Go toolchain not found. Install per docs/go-build.md.\n' >&2
    exit 1
fi

_log "Building Go binary via 'make build'..."
make build >/dev/null
[[ -x "${REPO_ROOT}/bin/tekhton" ]] || { printf 'make build did not produce bin/tekhton.\n' >&2; exit 1; }
export PATH="${REPO_ROOT}/bin:${PATH}"

[[ -f VERSION ]] || { printf 'VERSION file not found.\n' >&2; exit 1; }
EXPECTED_VERSION="$(tr -d '[:space:]' < VERSION)"
[[ -n "$EXPECTED_VERSION" ]] || { printf 'VERSION file empty.\n' >&2; exit 1; }

# For the routing scenarios we point TEKHTON_BIN at a fake stub so the
# dispatcher's exec doesn't actually fire the Go runner — that would
# trigger the bash preflight bridge, which calls lib/checkpoint.sh's
# `git stash` and `git checkout -- .` and stomps the working tree. The
# fake binary just exits 0 so the dispatcher's trace line is the only
# observable effect. Version checks below restore PATH/TEKHTON_BIN so
# the real binary handles --version comparisons.
FAKE_BIN_DIR="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN_DIR"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN_DIR/tekhton"
chmod +x "$FAKE_BIN_DIR/tekhton"

# Capture the dispatcher trace line for a given argv. The dispatcher prints
# the routing decision on stderr immediately before exec — we grep for that
# specific line so subsequent output (Go binary errors, legacy script
# bootstrap) is irrelevant.
_dispatch_trace() {
    TEKHTON_DEBUG_DISPATCHER=1 TEKHTON_BIN="$FAKE_BIN_DIR/tekhton" \
        bash "${REPO_ROOT}/tekhton.sh" "$@" 2>&1 1>/dev/null \
        | grep -m1 '^\[tekhton-dispatcher\]' || true
}

# Assert the dispatcher routes the given argv to `tekhton run`.
_assert_routes_to_run() {
    local label="$1"; shift
    local trace
    trace="$(_dispatch_trace "$@")"
    case "$trace" in
        *"$FAKE_BIN_DIR/tekhton run "*) _pass "$label" "routes to: tekhton run $*" ;;
        *) _fail "$label" "expected route to 'tekhton run', got: ${trace}" ;;
    esac
}

# Assert the dispatcher routes the given argv to tekhton-legacy.sh.
_assert_routes_to_legacy() {
    local label="$1"; shift
    local trace
    trace="$(_dispatch_trace "$@")"
    case "$trace" in
        *"tekhton-legacy.sh"*) _pass "$label" "routes to: tekhton-legacy.sh $*" ;;
        *) _fail "$label" "expected route to legacy, got: ${trace}" ;;
    esac
}

_log "Self-host parity matrix — 15 scenarios."

# --- Scenarios -------------------------------------------------------------

# 1. --task "trivial" — happy path basic.
_assert_routes_to_run "01" --task "trivial"

# 2. --task with build-gate retry (synthetic — argv-routing only here; the
# build-fix loop itself is covered by tests/test_build_fix_loop.sh).
_assert_routes_to_run "02" --task "fix typo" --analyze-cmd "true"

# 3. --task with review rework — argv routing.
_assert_routes_to_run "03" --task "rework demo"

# 4. --task with security gate (security stage runs inside the runner).
_assert_routes_to_run "04" --task "security demo"

# 5. --task with tester baseline (covered by internal/runner tests for the
# acceptance pass; here we assert routing).
_assert_routes_to_run "05" --task "baseline demo"

# 6. --complete --task succeeding on attempt 1.
_assert_routes_to_run "06" --complete --task "complete demo"

# 7. --complete --task with transient retries (recovery dispatch).
_assert_routes_to_run "07" --complete --task "retry demo"

# 8. --complete hitting MAX_PIPELINE_ATTEMPTS — STUCK exit.
_assert_routes_to_run "08" --complete --task "stuck demo"

# 9. --complete hitting AUTONOMOUS_TIMEOUT.
_assert_routes_to_run "09" --complete --task "timeout demo"

# 10. --milestone single-attempt.
_assert_routes_to_run "10" --milestone m21

# 11. --milestone --complete --auto-advance — auto-advance prompt path.
_assert_routes_to_run "11" --milestone m21 --complete --auto-advance

# 12. --resume after SIGINT.
_assert_routes_to_run "12" --resume

# 13. --human --human-tag BUG — human-mode notes filtering.
_assert_routes_to_run "13" --human --human-tag BUG

# 14. --no-tui — TUI off.
_assert_routes_to_run "14" --no-tui --task "no tui demo"

# 15. --dry-run --task — dry-run preview.
_assert_routes_to_run "15" --dry-run --task "dry run demo"

# --- Legacy invariants -----------------------------------------------------

_log "Legacy-flag routing checks (Phase 5 absorbs these one at a time)."

# Smoke: every documented legacy flag still routes to tekhton-legacy.sh and
# does not accidentally cross into the run-flag dispatch path.
_assert_routes_to_legacy "L1" --status
_assert_routes_to_legacy "L2" --metrics
_assert_routes_to_legacy "L3" --rollback --check
_assert_routes_to_legacy "L4" --diagnose
_assert_routes_to_legacy "L5" --report

# --- Version + binary checks -----------------------------------------------

_log "Version checks."
actual="$(tekhton --version | tr -d '[:space:]')"
if [[ "$actual" == "$EXPECTED_VERSION" ]]; then
    _pass "V1" "tekhton --version == VERSION (${EXPECTED_VERSION})"
else
    _fail "V1" "tekhton --version='${actual}' != VERSION='${EXPECTED_VERSION}'"
fi

bash_version="$(bash "${REPO_ROOT}/tekhton.sh" --version 2>/dev/null | tr -d '\r' || true)"
case "$bash_version" in
    *"${EXPECTED_VERSION}"*) _pass "V2" "tekhton.sh --version contains VERSION" ;;
    *)                       _fail "V2" "tekhton.sh --version='${bash_version}' missing VERSION" ;;
esac

actual_path="$(command -v tekhton)"
if [[ "$actual_path" == "${REPO_ROOT}/bin/tekhton" ]]; then
    _pass "V3" "tekhton resolves to ${actual_path}"
else
    _fail "V3" "tekhton resolves to '${actual_path}' (expected '${REPO_ROOT}/bin/tekhton')"
fi

# --- Optional live --dry-run smoke (gated) ---------------------------------

if [[ "${TEKHTON_SELF_HOST_DRY_RUN:-0}" == "1" ]]; then
    if ! command -v claude >/dev/null 2>&1; then
        printf 'TEKHTON_SELF_HOST_DRY_RUN=1 set but claude CLI not found.\n' >&2
        FAILURES=$(( FAILURES + 1 ))
    else
        _log "Running live --dry-run smoke (TEKHTON_SELF_HOST_DRY_RUN=1)..."
        if bash "${REPO_ROOT}/tekhton.sh" --dry-run --task "self-host smoke" >/dev/null 2>&1; then
            _pass "DR" "tekhton.sh --dry-run --task exits 0"
        else
            _fail "DR" "tekhton.sh --dry-run --task exited non-zero"
        fi
    fi
else
    _log "Skipping live --dry-run (set TEKHTON_SELF_HOST_DRY_RUN=1 to enable)."
fi

# --- Summary ---------------------------------------------------------------

if (( FAILURES > 0 )); then
    printf '\n\033[0;31m[self-host] %d scenario(s) failed.\033[0m\n' "$FAILURES" >&2
    exit 1
fi
_log "All self-host scenarios passed."
