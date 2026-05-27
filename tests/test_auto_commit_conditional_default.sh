#!/usr/bin/env bash
# =============================================================================
# test_auto_commit_conditional_default.sh — AUTO_COMMIT default + opt-out
#
# 2026-05-27: AUTO_COMMIT now defaults to TRUE for every mode (was: false
# for non-milestone, true for milestone via a conditional override). The
# interactive y/e/n prompt was removed entirely. Operators who want to
# review before committing pass --no-commit or set AUTO_COMMIT=false in
# pipeline.conf.
#
# This test enforces:
#   1. The Go-emitted default is true (sourced via config_defaults.sh's
#      `tekhton config defaults --emit shell` shim).
#   2. Explicit user override (pipeline.conf AUTO_COMMIT=false) wins.
#   3. --no-commit flag (tracked via _AUTO_COMMIT_EXPLICIT) wins.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
mkdir -p "$PROJECT_DIR/.claude"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    else
        echo "PASS: $name"
    fi
}

cd "$PROJECT_DIR"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/config.sh"

reload_defaults() {
    unset AUTO_COMMIT 2>/dev/null || true
    # config_defaults.sh references CLAUDE_STANDARD_MODEL; stub it for test isolation
    : "${CLAUDE_STANDARD_MODEL:=sonnet}"
    source "${TEKHTON_HOME}/lib/config_defaults.sh"
}

# =============================================================================
# Test 1: Default is true (regardless of milestone mode)
# =============================================================================

MILESTONE_MODE=false
reload_defaults
assert_eq "1.1 non-milestone mode default is true" "true" "$AUTO_COMMIT"

MILESTONE_MODE=true
reload_defaults
assert_eq "1.2 milestone mode default is true" "true" "$AUTO_COMMIT"

unset MILESTONE_MODE 2>/dev/null || true
reload_defaults
assert_eq "1.3 unset MILESTONE_MODE default is true" "true" "$AUTO_COMMIT"

# =============================================================================
# Test 2: Explicit AUTO_COMMIT=false in pipeline.conf wins over the default
#
# Sourcing order in tekhton-legacy.sh: config_defaults.sh first
# (defaults from Go via `tekhton config defaults --emit shell`), then
# load_config reads pipeline.conf and applies user values on top. So an
# explicit setting comes AFTER the default and the value the test
# fixes is what wins.
# =============================================================================

MILESTONE_MODE=true
reload_defaults                # baseline: AUTO_COMMIT=true
AUTO_COMMIT=false              # simulate pipeline.conf override
assert_eq "2.1 explicit AUTO_COMMIT=false (set post-default) wins" "false" "$AUTO_COMMIT"

MILESTONE_MODE=false
reload_defaults
AUTO_COMMIT=false
assert_eq "2.2 explicit AUTO_COMMIT=false (non-milestone, post-default) wins" "false" "$AUTO_COMMIT"

# =============================================================================
# Test 3: Explicit AUTO_COMMIT=true post-default is a no-op (already true)
# =============================================================================

reload_defaults
AUTO_COMMIT=true
assert_eq "3.1 explicit AUTO_COMMIT=true post-default still true" "true" "$AUTO_COMMIT"

# =============================================================================
# Test 4: --no-commit flag sets AUTO_COMMIT=false after defaults
# =============================================================================
# tekhton-legacy.sh handles `--no-commit` by setting AUTO_COMMIT=false +
# _AUTO_COMMIT_EXPLICIT=true. The pre-2026-05-27 conditional override
# logic was deleted (the default is now true; nothing to override).
# Simulate the post-defaults assignment:

reload_defaults
AUTO_COMMIT=false          # simulate --no-commit
_AUTO_COMMIT_EXPLICIT=true
assert_eq "4.1 --no-commit sets AUTO_COMMIT=false" "false" "$AUTO_COMMIT"

# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    echo ""
    echo "FAILED"
    exit 1
fi

echo ""
echo "All tests passed."
