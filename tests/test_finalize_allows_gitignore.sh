#!/usr/bin/env bash
# TIMEOUT_SECS=30
# =============================================================================
# test_finalize_allows_gitignore.sh — S1 commit-staging integration guard
# (was: m06 .gitignore allowlist regression)
#
# S1 (2026-06-14) replaced the commit allowlist with a denylist. This test now
# verifies the denylist end-to-end through the real _do_git_commit:
#
#  A. Unit: _is_path_committable allows substantive paths (.gitignore, lib/,
#     internal/) and skips pure transients (.claude/logs/, session dir).
#  B. Integration: _do_git_commit commits an UNDECLARED .gitignore AND an
#     UNDECLARED lib/ change (the exact stranding regression: pre-S1 the
#     allowlist dropped lib/ work the coder didn't list in CODER_SUMMARY).
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0
FAIL=0
_pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
_expect() { # want got msg
    if [[ "$2" == "$1" ]]; then _pass "$3"; else _fail "$3 (got: $2)"; fi
}

TMPDIR_ROOT=$(mktemp -d -t tekhton-s1-commit-XXXXXX)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# shellcheck disable=SC2317
log()     { :; }
# shellcheck disable=SC2317
warn()    { :; }
# shellcheck disable=SC2317
success() { :; }
# shellcheck disable=SC2317
log_verbose() { :; }

# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/finalize_commit_staging.sh"

# =============================================================================
# Scenario A: unit — _is_path_committable denylist semantics
# =============================================================================
echo "=== A: _is_path_committable denylist ==="
export TEKHTON_SESSION_DIR=".tekhton/session-a"

_ck_committable() { _is_path_committable "$1" && echo yes || echo no; }

# A1: .gitignore is substantive → committable (the original m06 concern).
_expect yes "$(_ck_committable .gitignore)" "A1: .gitignore committable"
# A2: lib/ tree committable — the S1 stranding regression surface.
_expect yes "$(_ck_committable lib/quota_probe.sh)" "A2: lib/quota_probe.sh committable (stranding regression)"
# A3: a source file committable.
_expect yes "$(_ck_committable internal/foo.go)" "A3: internal/foo.go committable"
# A4/A5: pure transients skipped.
_expect no "$(_ck_committable .claude/logs/run.log)" "A4: .claude/logs/ skipped"
_expect no "$(_ck_committable .tekhton/session-a/scratch.txt)" "A5: session dir skipped"

# =============================================================================
# Scenario B: integration — _do_git_commit commits undeclared .gitignore + lib/
# =============================================================================
echo ""
echo "=== B: _do_git_commit commits undeclared .gitignore AND lib/ change ==="

PROJECT_DIR="${TMPDIR_ROOT}/project_b"
mkdir -p "${PROJECT_DIR}/.tekhton" "${PROJECT_DIR}/lib"
TEKHTON_DIR="${PROJECT_DIR}/.tekhton"
export PROJECT_DIR TEKHTON_DIR
unset TEKHTON_SESSION_DIR

(
    cd "$PROJECT_DIR"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Tekhton Test"
    git config commit.gpgsign false
    printf '*.log\n' > .gitignore
    printf 'package main\n' > main.go
    printf 'echo old\n' > lib/quota_probe.sh
    git add .gitignore main.go lib/quota_probe.sh
    git commit -q -m "initial"
    # Milestone touches .gitignore AND lib/ — neither declared in CODER_SUMMARY.
    printf '*.log\n.tekhton/.finalize_active\n' > .gitignore
    printf 'echo old\necho new-work\n' > lib/quota_probe.sh
)

CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
export CODER_SUMMARY_FILE
cat > "$CODER_SUMMARY_FILE" <<'SUMMARY_EOF'
## Files Modified
- `main.go`
SUMMARY_EOF

# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/finalize_commit_staging.sh"
if ! declare -f _do_git_commit > /dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$TEKHTON_HOME/lib/finalize_commit.sh" 2>/dev/null || true
fi

if ! declare -f _do_git_commit > /dev/null 2>&1; then
    echo "  SKIP B: _do_git_commit not available — source chain incomplete"
else
    generate_commit_message() { echo "test: S1 staging regression"; }
    export -f generate_commit_message 2>/dev/null || true
    cd "$PROJECT_DIR"

    exit_code=0
    _do_git_commit "S1 staging regression test" >/dev/null 2>&1 || exit_code=$?
    if [[ "$exit_code" -ne 0 ]]; then
        _fail "B0: _do_git_commit exited $exit_code"
    else
        committed=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)
        if echo "$committed" | grep -qF ".gitignore"; then _pass "B1: undeclared .gitignore committed"; else _fail "B1: .gitignore NOT committed"; fi
        if echo "$committed" | grep -qF "lib/quota_probe.sh"; then _pass "B2: undeclared lib/quota_probe.sh committed (no stranding)"; else _fail "B2: lib/quota_probe.sh STRANDED (not committed)"; fi
    fi
fi

echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "S1 commit-staging guard passed"
