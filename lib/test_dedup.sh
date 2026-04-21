#!/usr/bin/env bash
# =============================================================================
# test_dedup.sh — Test run deduplication via working-tree fingerprinting (M105)
#
# Skips redundant TEST_CMD executions when the working tree is byte-identical to
# the state captured during the last successful test pass. A fingerprint change
# (modified/staged/untracked/deleted files, or a TEST_CMD config change)
# invalidates the cache, forcing a re-run.
#
# Sourced by tekhton.sh after gates_completion.sh — do not run directly.
# Expects: TEKHTON_DIR, TEST_CMD, TEST_DEDUP_ENABLED (from config).
#
# Provides:
#   _test_dedup_fingerprint — compute hash of working-tree state + TEST_CMD
#   test_dedup_record_pass  — cache the current fingerprint as "last passing"
#   test_dedup_can_skip     — return 0 if the cached fingerprint matches now
#   test_dedup_reset        — clear the cached fingerprint
# =============================================================================
set -euo pipefail

# _test_dedup_hash
# Portable hash helper. Prefers `shasum` (present on macOS + Linux); falls back
# to `md5sum` (GNU) and then `md5` (BSD/macOS). Emits only the hex digest.
_test_dedup_hash() {
    if command -v shasum &>/dev/null; then
        shasum | cut -d' ' -f1
    elif command -v md5sum &>/dev/null; then
        md5sum | cut -d' ' -f1
    elif command -v md5 &>/dev/null; then
        md5 -q
    else
        # No hasher available — return input unchanged so the fingerprint
        # remains deterministic per working-tree state.
        cat
    fi
}

# _test_dedup_fingerprint
# Emits a stable hash of HEAD identity + working-tree state + the active
# TEST_CMD. Including HEAD prevents clean-tree collisions across different
# commits (M112). In a non-git directory (or if git fails), emits a unique
# value per call so callers can never match a previous fingerprint — dedup
# degrades gracefully to "always re-run". The fallback must never repeat
# within a run; `$RANDOM` plus PID + seconds works on both macOS and Linux
# (unlike `date +%s%N`, which is GNU-only).
_test_dedup_fingerprint() {
    if command -v git &>/dev/null \
       && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        local head_sha
        head_sha=$(git rev-parse HEAD 2>/dev/null || echo "no-head")
        # git status --porcelain covers modified, staged, untracked, deleted.
        # Including TEST_CMD ensures a config change invalidates the cache.
        # Including HEAD ensures a clean tree at a different commit does not
        # match a prior pass fingerprint.
        {
            echo "head:${head_sha}"
            git status --porcelain 2>/dev/null
            echo "cmd:${TEST_CMD:-}"
        } | _test_dedup_hash
    else
        echo "no-git-$$-$(date +%s)-${RANDOM}${RANDOM}"
    fi
}

# _test_dedup_fingerprint_file
# Resolves the on-disk path used to persist the "last passing" fingerprint.
_test_dedup_fingerprint_file() {
    echo "${TEKHTON_DIR:-.tekhton}/test_dedup.fingerprint"
}

# test_dedup_record_pass
# Caches the current fingerprint so the next test invocation with an identical
# working tree can skip. No-op when TEST_DEDUP_ENABLED is not "true".
test_dedup_record_pass() {
    [[ "${TEST_DEDUP_ENABLED:-true}" = "true" ]] || return 0
    local fp_file
    fp_file=$(_test_dedup_fingerprint_file)
    local fp
    fp=$(_test_dedup_fingerprint)
    mkdir -p "$(dirname "$fp_file")" 2>/dev/null || true
    printf '%s\n' "$fp" > "$fp_file"
}

# test_dedup_can_skip
# Returns 0 (skip tests) when the current fingerprint matches the cached
# "last passing" fingerprint. Returns 1 (must run) otherwise — including when
# dedup is disabled, no fingerprint is cached, or git is unavailable.
test_dedup_can_skip() {
    [[ "${TEST_DEDUP_ENABLED:-true}" = "true" ]] || return 1
    local fp_file
    fp_file=$(_test_dedup_fingerprint_file)
    [[ -f "$fp_file" ]] || return 1
    local current previous
    current=$(_test_dedup_fingerprint)
    previous=$(cat "$fp_file" 2>/dev/null || echo "")
    [[ -n "$previous" ]] || return 1
    [[ "$current" = "$previous" ]]
}

# test_dedup_reset
# Removes the cached fingerprint. Called once at pipeline start so stale state
# from a previous run never leaks into a new run.
test_dedup_reset() {
    local fp_file
    fp_file=$(_test_dedup_fingerprint_file)
    rm -f "$fp_file" 2>/dev/null || true
}
