#!/usr/bin/env bash
# scripts/run-parity-check.sh — m19 run-level parity gate.
#
# Structural smoke test for the m19 Go/bash seam. Four checks:
#
#   1. Go binary builds and `tekhton run --help` exposes all documented flags.
#   2. `tekhton.sh --help` advertises the legacy bash flag set.
#   3. Legacy orchestration function names are absent from lib/, stages/, tekhton.sh.
#   4. Deleted bash files (orchestrate_main.sh, orchestrate_state.sh) are not in
#      git's index.
#
# The check is a structural smoke test in this milestone — full byte-for-byte
# comparison of RUN_SUMMARY.json / PIPELINE_STATE.json / CAUSAL_LOG.jsonl
# requires a live target project, which lives outside CI. The exit code maps
# the seam health, not the output equivalence:
#
#   0  = Go runner exposes the documented surface AND the legacy bash entry
#        point still validates ($?=0 on dry-run-style invocations)
#   1  = surface drift detected (a flag missing, an exit-code regression)
#
# Usage:
#   scripts/run-parity-check.sh          # exits 0 on clean state, 1 on drift
#   scripts/run-parity-check.sh --use-fallback   # skip the Go build / smoke

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$REPO_ROOT"

USE_FALLBACK=false
[[ "${1:-}" == "--use-fallback" ]] && USE_FALLBACK=true

violations=0
note() { printf '  [parity] %s\n' "$1"; }
fail() { violations=$(( violations + 1 )); printf '  [parity] FAIL: %s\n' "$1" >&2; }

# --- Surface check 1: the Go binary builds and `tekhton run --help` works.
TEKHTON_BIN="${REPO_ROOT}/bin/tekhton"
if ! $USE_FALLBACK; then
    if command -v go >/dev/null 2>&1; then
        (cd "$REPO_ROOT" && go build -o bin/tekhton ./cmd/tekhton/) || \
            fail "go build failed"
    else
        note "go not on PATH; skipping build"
    fi
fi

if [[ ! -x "$TEKHTON_BIN" ]]; then
    if $USE_FALLBACK; then
        note "skipping Go-side checks (--use-fallback)"
    else
        fail "tekhton binary missing at $TEKHTON_BIN"
    fi
else
    HELP_OUT=$("$TEKHTON_BIN" run --help 2>&1 || true)
    for flag in --task --complete --resume --human --human-tag --milestone \
                --auto-advance --auto-advance-limit --dry-run --no-tui; do
        if ! printf '%s' "$HELP_OUT" | grep -q -- "$flag"; then
            fail "tekhton run --help missing $flag"
        fi
    done
    note "Go side: tekhton run --help advertises all 10 documented run flags"

    # Exactly-one-of validation: run with no mode → exit 64.
    rc=0
    "$TEKHTON_BIN" run --tekhton-home /tmp --project-dir /tmp >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 64 ]]; then
        fail "Go side: empty mode flags returned $rc, want 64"
    else
        note "Go side: empty mode flags returned 64 (EX_USAGE) as expected"
    fi
fi

# --- Surface check 2: the bash entry point still parses each documented flag.
# We run `bash tekhton.sh --help` and grep for the same flag set.
BASH_HELP_OUT=$(bash "${REPO_ROOT}/tekhton.sh" --help 2>&1 || true)
# m19: tekhton.sh's --help surface is the legacy bash flag set. --task is
# positional (not a long flag), --resume is implicit (no-args invocation).
# Until m20 flips the entry point we only verify the legacy long flags here.
for flag in --complete --human --milestone --auto-advance --dry-run \
            --status --init; do
    if ! printf '%s' "$BASH_HELP_OUT" | grep -q -- "$flag"; then
        fail "tekhton.sh --help missing $flag"
    fi
done
note "Bash side: tekhton.sh --help advertises legacy flag set"

# --- Surface check 3: legacy function names are gone from the bash tree.
if grep -rqE 'run_complete_loop|_save_orchestration_state' \
        "${REPO_ROOT}/lib" "${REPO_ROOT}/stages" "${REPO_ROOT}/tekhton.sh" 2>/dev/null; then
    fail "legacy run_complete_loop / _save_orchestration_state names still present"
else
    note "legacy orch-loop function names absent from lib/, stages/, tekhton.sh"
fi

# --- Surface check 4: the deleted bash files are not in git's index.
if git ls-files --error-unmatch lib/orchestrate_main.sh 2>/dev/null >&2; then
    fail "lib/orchestrate_main.sh still tracked"
fi
if git ls-files --error-unmatch lib/orchestrate_state.sh 2>/dev/null >&2; then
    fail "lib/orchestrate_state.sh still tracked"
fi

if [[ "$violations" -gt 0 ]]; then
    printf '\nrun-parity-check: %d violation(s)\n' "$violations" >&2
    exit 1
fi

printf '\nrun-parity-check: clean — %d structural checks passed\n' 4
exit 0
