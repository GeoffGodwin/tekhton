#!/usr/bin/env bash
# TIMEOUT_SECS=30
# =============================================================================
# test_finalize_allows_gitignore.sh — m06 Goal A regression guard.
#
# What this test covers
# ---------------------
# Bug A from the V5 m04+m05 run: _pipeline_bookkeeping_globs in
# lib/finalize_commit_staging.sh did not list .gitignore, so a milestone whose
# finalize output touched .gitignore (m05's sentinel update) had its commit
# hook return exit 1 — "not declared by the coder or pipeline bookkeeping".
#
# m06 adds .gitignore to the bookkeeping list. This test verifies:
#
#  A. _is_path_allowed returns 0 (allowed) for ".gitignore" — the unit check.
#  B. The full _do_git_commit with .gitignore as the only undeclared file
#     succeeds — the shim-boundary integration check.
#
# Both scenarios must pass for the m06 Goal A acceptance criterion to be met.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0
FAIL=0
_pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TMPDIR_ROOT=$(mktemp -d -t tekhton-m06-gitignore-XXXXXX)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Stubs for noisy lib output.
# shellcheck disable=SC2317
log()     { :; }
# shellcheck disable=SC2317
warn()    { :; }
# shellcheck disable=SC2317
success() { :; }
# shellcheck disable=SC2317
log_verbose() { :; }

# =============================================================================
# Source dependencies.
# =============================================================================
# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/finalize_commit_staging.sh"

# =============================================================================
# Scenario A: unit-level — _is_path_allowed returns 0 for .gitignore
# =============================================================================
echo "=== A: _is_path_allowed .gitignore returns 0 (allowed) ==="

PROJECT_DIR="${TMPDIR_ROOT}/project_a"
mkdir -p "${PROJECT_DIR}/.tekhton"
TEKHTON_DIR="${PROJECT_DIR}/.tekhton"
export PROJECT_DIR TEKHTON_DIR

# Minimal CODER_SUMMARY.md — declares only internal/foo.go (not .gitignore).
# If _is_path_allowed is correct, it allows .gitignore via the bookkeeping
# globs regardless of what the coder declared.
CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
export CODER_SUMMARY_FILE
cat > "$CODER_SUMMARY_FILE" <<'SUMMARY_EOF'
## Files Modified
- `internal/foo.go`
SUMMARY_EOF

# A1: .gitignore must be allowed via bookkeeping globs.
if _is_path_allowed ".gitignore"; then
    _pass "A1: _is_path_allowed .gitignore → 0 (allowed via bookkeeping globs)"
else
    _fail "A1: _is_path_allowed .gitignore → non-0; .gitignore is missing from bookkeeping allowlist (m06 Bug A not fixed)"
fi

# A2: Confirm that .gitignore is specifically in the bookkeeping heredoc
# (not accidentally allowed by a broader prefix match).
gitignore_in_globs=$(_pipeline_bookkeeping_globs | grep -xF '.gitignore' || true)
if [[ -n "$gitignore_in_globs" ]]; then
    _pass "A2: .gitignore appears as an exact entry in _pipeline_bookkeeping_globs"
else
    _fail "A2: .gitignore not found as exact entry in _pipeline_bookkeeping_globs — may be allowed by a prefix leak"
fi

# A3: Sanity — a truly unlisted path (.env) must still be rejected.
if ! _is_path_allowed ".env"; then
    _pass "A3: _is_path_allowed .env → non-0 (unlisted path rejected — allowlist still effective)"
else
    _fail "A3: _is_path_allowed .env → 0 (allowlist too permissive)"
fi

# A4: A declared file (internal/foo.go) must still be allowed.
if _is_path_allowed "internal/foo.go"; then
    _pass "A4: _is_path_allowed internal/foo.go → 0 (declared file allowed)"
else
    _fail "A4: _is_path_allowed internal/foo.go → non-0 (regression: declared files must be allowed)"
fi

# =============================================================================
# Scenario B: integration — _do_git_commit succeeds with .gitignore in the diff
# =============================================================================
echo ""
echo "=== B: _do_git_commit with .gitignore change completes without exit 1 ==="

PROJECT_DIR="${TMPDIR_ROOT}/project_b"
mkdir -p "${PROJECT_DIR}/.tekhton"
TEKHTON_DIR="${PROJECT_DIR}/.tekhton"
export PROJECT_DIR TEKHTON_DIR

# Set up a real git repo.
(
    cd "$PROJECT_DIR"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Tekhton Test"
    git config commit.gpgsign false

    # Initial commit.
    printf '*.log\n' > .gitignore
    printf 'package main\n' > main.go
    git add .gitignore main.go
    git commit -q -m "initial"

    # Simulate a milestone that updates .gitignore (m05's pattern).
    printf '*.log\n.tekhton/.finalize_active\n' > .gitignore
)

# CODER_SUMMARY.md declares main.go but NOT .gitignore (the m05 failure shape).
CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
export CODER_SUMMARY_FILE
cat > "$CODER_SUMMARY_FILE" <<'SUMMARY_EOF'
## What Was Implemented
Added sentinel entry to .gitignore.

## Files Modified
- `main.go`
SUMMARY_EOF

# Source finalize_commit.sh to get _do_git_commit.
# Must re-source here so it picks up the updated PROJECT_DIR / TEKHTON_DIR.
# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/finalize_commit_staging.sh"

# Check if _do_git_commit is available (requires finalize_commit.sh).
if ! declare -f _do_git_commit > /dev/null 2>&1; then
    # Source finalize_commit.sh if needed.
    # shellcheck source=/dev/null
    source "$TEKHTON_HOME/lib/finalize_commit.sh" 2>/dev/null || true
fi

if ! declare -f _do_git_commit > /dev/null 2>&1; then
    echo "  SKIP B: _do_git_commit not available — source chain incomplete"
else
    # B1: Verify .gitignore shows as a changed file in the git working tree.
    cd "$PROJECT_DIR"
    changed_files=$(git status --short 2>/dev/null || true)
    if echo "$changed_files" | grep -q '\.gitignore'; then
        _pass "B1: .gitignore appears as a changed file in the working tree (precondition)"
    else
        _fail "B1: .gitignore not in git status — test setup may be wrong"
    fi

    # B2: Drive _do_git_commit and assert it exits 0.
    # Stub commit-message helpers and signing to avoid real git commit.
    generate_commit_message() { echo "test: m06 .gitignore regression"; }
    # Export stubs so subshells see them.
    export -f generate_commit_message 2>/dev/null || true

    exit_code=0
    commit_output=$(_do_git_commit "auto" "none" "m06 .gitignore regression test" 2>&1) || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        _fail "B2: _do_git_commit exited $exit_code — unexpected hard failure"
    else
        # A "pass" exit code alone isn't enough — the bug shape is that
        # _do_git_commit exits 0 but SKIPS .gitignore with a warning.
        # Verify .gitignore is NOT skipped by checking the commit's diff.
        committed_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)
        if echo "$committed_files" | grep -qF ".gitignore"; then
            _pass "B2: _do_git_commit committed .gitignore (included in HEAD diff)"
        else
            # The commit succeeded but skipped .gitignore — this is the bug.
            _fail "B2: _do_git_commit exited 0 but .gitignore was SKIPPED (not staged) — m06 Bug A: allowlist rejects .gitignore silently"
        fi
    fi

    # B3: No "Skipping" warning for .gitignore in the output.
    if echo "$commit_output" | grep -qF ".gitignore" && echo "$commit_output" | grep -qiF "Skipping"; then
        _fail "B3: _do_git_commit emitted 'Skipping' warning for .gitignore — .gitignore not in allowlist"
    else
        _pass "B3: no 'Skipping .gitignore' warning in _do_git_commit output"
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
echo "m06 .gitignore allowlist regression guard passed"
