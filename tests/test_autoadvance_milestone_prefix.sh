#!/usr/bin/env bash
# =============================================================================
# test_autoadvance_milestone_prefix.sh — m04 regression guard.
#
# What this test covers
# ---------------------
# Before m04, MILESTONE_MODE and _CURRENT_MILESTONE were absent from the bash
# hook subprocess env during auto-advance runs. _hook_commit reads these vars
# at lib/finalize_commit.sh:194 to build ms_num; when they're missing ms_num
# stays empty and generate_commit_message falls through to m44's
# largest-file-fallback subject instead of the [MILESTONE X ✓] prefix.
#
# Two scenarios:
#
#  A. Bash-layer: generate_commit_message produces [MILESTONE X ✓] subject when
#     milestone_num arg is non-empty (COMPLETE_AND_CONTINUE disposition), and
#     produces no prefix when milestone_num is empty. Exercises lib/hooks.sh
#     and lib/milestone_ops.sh directly. This is the primary observable
#     behavior the fix enables.
#
#  B. Go-shim-boundary: when the tekhton binary is built, verify the binary
#     contains the MILESTONE_MODE= env-key string so the m04 propagation code
#     is linked in. Self-skips when the binary isn't built.
#
# Note on full end-to-end
# -----------------------
# A complete "drive 2 milestones with stubbed agents and assert 2 [MILESTONE]
# commits" requires a fake agent emitting CODER_SUMMARY.md with acceptance
# content for every stage — far beyond testdata/fake_agent.sh's shape. The
# Go unit test TestBashHookRunnerFinalizeMillestoneModeEnvContract_M04 in
# internal/runner/hooks_test.go covers the env-contract boundary. This bash
# test covers the generate_commit_message component.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d -t tekhton-m04-prefix-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Always prefer the binary built from this tree so we test the working copy.
LOCAL_BIN="${TEKHTON_HOME}/bin/tekhton"
if [[ -x "$LOCAL_BIN" ]]; then
    TEKHTON_BIN="$LOCAL_BIN"
else
    TEKHTON_BIN="${TEKHTON_BIN:-${LOCAL_BIN}}"
fi

PASS=0
FAIL=0
_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# Scenario A: bash-layer — generate_commit_message honours milestone args
# =============================================================================
echo "=== A: generate_commit_message with milestone args produces [MILESTONE X ✓] ==="

PROJECT_DIR="${TMPDIR}/project"
mkdir -p "${PROJECT_DIR}/.claude" "${PROJECT_DIR}/.tekhton"
(
    cd "$PROJECT_DIR"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false
    printf 'baseline\n' > baseline.sh
    git add baseline.sh
    git commit -q -m "initial"
    # Stage a change so generate_commit_message has a diff for the fallback path.
    printf 'changed\n' > baseline.sh
    git add baseline.sh
)

export PROJECT_DIR
export TEKHTON_HOME
export CODER_SUMMARY_FILE="${PROJECT_DIR}/.tekhton/CODER_SUMMARY.md"

# Minimal CODER_SUMMARY.md so the what-block is available.
cat > "$CODER_SUMMARY_FILE" <<'SUMMARY_EOF'
## What Was Implemented
Env-propagation fix for milestone mode.

## Files Created or Modified
- internal/finalize/shim.go
SUMMARY_EOF

# Source deps. common.sh first (defines log, warn etc.); then stub them
# so the test doesn't emit noisy output.
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null || true

# shellcheck disable=SC2317
log()     { :; }
# shellcheck disable=SC2317
warn()    { :; }
# shellcheck disable=SC2317
success() { :; }

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/milestone_ops.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/hooks.sh"

# Scenario A1: no milestone_num → no [MILESTONE] prefix.
cd "$PROJECT_DIR"
result_a1=$(generate_commit_message "Implement m04 fix" "" "" 2>/dev/null || true)
if echo "$result_a1" | grep -q '^\[MILESTONE'; then
    _fail "A1: expected no [MILESTONE] prefix when milestone_num is empty; got: ${result_a1%%$'\n'*}"
else
    _pass "A1: no [MILESTONE] prefix when milestone_num is empty (non-milestone run path)"
fi

# Scenario A2: milestone_num="m04", COMPLETE_AND_CONTINUE → [MILESTONE m04 ✓] prefix.
result_a2=$(generate_commit_message "Implement m04 fix" "m04" "COMPLETE_AND_CONTINUE" 2>/dev/null || true)
if ! echo "$result_a2" | grep -q '^\[MILESTONE'; then
    _fail "A2: [MILESTONE] prefix missing from subject; got: ${result_a2%%$'\n'*}"
else
    _pass "A2: commit subject starts with [MILESTONE m04 ...]: ${result_a2%%$'\n'*}"
fi
if ! echo "$result_a2" | grep -q 'm04'; then
    _fail "A2: m04 id missing from subject; got: ${result_a2%%$'\n'*}"
else
    _pass "A2: m04 id present in commit subject"
fi

# Scenario A3: milestone_num is empty (pre-m04 env-gap simulation) → no prefix.
# Before m04, _hook_commit's ms_num was always empty because MILESTONE_MODE and
# _CURRENT_MILESTONE weren't in env. generate_commit_message received "" as
# milestone_num and produced the fallback subject.
result_a3=$(generate_commit_message "Implement m04 fix" "" "" 2>/dev/null || true)
if echo "$result_a3" | grep -q '^\[MILESTONE'; then
    _fail "A3: empty milestone_num must not produce [MILESTONE] prefix"
else
    _pass "A3: empty milestone_num (pre-m04 env gap) produces no prefix — confirms root cause"
fi

# =============================================================================
# Scenario B: Go-shim-boundary — binary contains MILESTONE_MODE env-key string
# =============================================================================
echo ""
echo "=== B: binary contains MILESTONE_MODE env-key (m04 fix linked in) ==="

if [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "SKIP: tekhton binary not built (run 'make build' to enable scenario B)"
else
    # Assert the binary's string table contains the MILESTONE_MODE= and
    # _CURRENT_MILESTONE= env-key strings emitted by EnvBuilder.AsKV.
    # The format literals survive -trimpath -ldflags='-s -w' stripping.
    mm_count=$(strings "$TEKHTON_BIN" 2>/dev/null | grep -c -F "MILESTONE_MODE=" || true)
    if (( mm_count > 0 )); then
        _pass "B1: binary contains MILESTONE_MODE= env-key string (m04 env-builder linked)"
    else
        _fail "B1: MILESTONE_MODE= string missing from binary — m04 fix not linked in"
    fi

    cm_count=$(strings "$TEKHTON_BIN" 2>/dev/null | grep -c -F "_CURRENT_MILESTONE=" || true)
    if (( cm_count > 0 )); then
        _pass "B2: binary contains _CURRENT_MILESTONE= env-key string"
    else
        _fail "B2: _CURRENT_MILESTONE= string missing from binary"
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "m04 milestone prefix regression guard passed"
