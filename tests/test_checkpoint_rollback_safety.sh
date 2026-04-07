#!/usr/bin/env bash
# =============================================================================
# test_checkpoint_rollback_safety.sh — rollback_last_run safety check edge cases
#
# Tests:
#   1. Rollback fails when CHECKPOINT_ENABLED=false
#   2. Rollback fails when no checkpoint file exists
#   3. Rollback fails when uncommitted changes exist in the working tree
#   4. Rollback fails when current_head != commit_sha (commits added after run)
#      — This is the primary Coverage Gap identified by the reviewer
#   5. Rollback succeeds when current_head == commit_sha (committed path)
#   6. Rollback succeeds for the uncommitted-changes path (no auto-commit)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

source "${TEKHTON_HOME}/lib/common.sh"

# _make_git_repo — create a minimal git repo with one initial commit
# Usage: _make_git_repo <dir>
_make_git_repo() {
    local dir="$1"
    mkdir -p "$dir/.claude"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@tekhton.local"
    git -C "$dir" config user.name "Tekhton Test"
    echo "initial" > "$dir/initial.txt"
    git -C "$dir" add .
    git -C "$dir" commit -q -m "Initial commit"
}

# _write_checkpoint — write a CHECKPOINT_META.json into a repo's .claude/
# Usage: _write_checkpoint <dir> <head_sha> <auto_committed> <commit_sha> \
#                          <had_uncommitted> <stash_ref>
_write_checkpoint() {
    local dir="$1" head_sha="$2" auto_committed="$3" commit_sha="$4"
    local had_uncommitted="${5:-false}" stash_ref="${6:-}"

    local commit_sha_json
    if [[ "$commit_sha" == "null" || -z "$commit_sha" ]]; then
        commit_sha_json="null"
    else
        commit_sha_json="\"${commit_sha}\""
    fi

    cat > "$dir/.claude/CHECKPOINT_META.json" << EOF
{
  "timestamp": "2024-01-01T12:00:00Z",
  "head_sha": "${head_sha}",
  "had_uncommitted": ${had_uncommitted},
  "stash_ref": "${stash_ref}",
  "task": "test task",
  "milestone": "",
  "auto_committed": ${auto_committed},
  "commit_sha": ${commit_sha_json}
}
EOF
}

# =============================================================================
# Test 1: Rollback fails when CHECKPOINT_ENABLED=false
# =============================================================================
echo "=== Test 1: CHECKPOINT_ENABLED=false blocks rollback ==="

(
    REPO="$TMPDIR/t1"
    _make_git_repo "$REPO"
    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=false

    source "${TEKHTON_HOME}/lib/checkpoint.sh"

    if rollback_last_run 2>/dev/null; then
        echo "FAIL: 1.1 rollback should return 1 when disabled"
        exit 1
    fi
    echo "PASS: 1.1 rollback returns 1 when CHECKPOINT_ENABLED=false"
)
[[ $? -eq 0 ]] && pass "1.1 rollback rejected when CHECKPOINT_ENABLED=false" \
               || { fail "1.1 rollback rejected when CHECKPOINT_ENABLED=false"; }

# =============================================================================
# Test 2: Rollback fails when no checkpoint file exists
# =============================================================================
echo "=== Test 2: No checkpoint file ==="

(
    REPO="$TMPDIR/t2"
    _make_git_repo "$REPO"
    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=true
    # Do NOT write a checkpoint file

    source "${TEKHTON_HOME}/lib/checkpoint.sh"

    if rollback_last_run 2>/dev/null; then
        echo "FAIL: 2.1 rollback should return 1 when no checkpoint file"
        exit 1
    fi
    echo "PASS: 2.1 rollback returns 1 when no checkpoint exists"
)
[[ $? -eq 0 ]] && pass "2.1 rollback rejected when no checkpoint file" \
               || { fail "2.1 rollback rejected when no checkpoint file"; }

# =============================================================================
# Test 3: Rollback fails when uncommitted changes exist
# =============================================================================
echo "=== Test 3: Uncommitted changes block rollback ==="

(
    REPO="$TMPDIR/t3"
    _make_git_repo "$REPO"
    HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

    # Create a subsequent commit as the "pipeline" commit
    echo "pipeline change" > "$REPO/pipeline.txt"
    git -C "$REPO" add pipeline.txt
    git -C "$REPO" commit -q -m "Pipeline: test"
    PIPELINE_SHA=$(git -C "$REPO" rev-parse HEAD)

    _write_checkpoint "$REPO" "$HEAD_SHA" true "$PIPELINE_SHA"

    # Leave an uncommitted change
    echo "dirty" >> "$REPO/pipeline.txt"

    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=true

    cd "$REPO"
    source "${TEKHTON_HOME}/lib/checkpoint.sh"

    if rollback_last_run 2>/dev/null; then
        echo "FAIL: 3.1 rollback should return 1 when uncommitted changes exist"
        exit 1
    fi
    echo "PASS: 3.1 rollback rejected when uncommitted changes exist"
)
[[ $? -eq 0 ]] && pass "3.1 rollback rejected when uncommitted changes exist" \
               || { fail "3.1 rollback rejected when uncommitted changes exist"; }

# =============================================================================
# Test 4: Rollback fails when current_head != commit_sha (user added commits)
#
# This is the PRIMARY coverage gap: the fixed safety check (review cycle 1
# rework) unconditionally rejects rollback when any commit exists on top of
# the pipeline commit. Verifies the regression fix stays correct.
# =============================================================================
echo "=== Test 4: current_head != commit_sha blocks rollback ==="

(
    REPO="$TMPDIR/t4"
    _make_git_repo "$REPO"
    HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

    # Make the pipeline commit
    echo "pipeline output" > "$REPO/pipeline_output.txt"
    git -C "$REPO" add pipeline_output.txt
    git -C "$REPO" commit -q -m "Pipeline: implement feature"
    PIPELINE_SHA=$(git -C "$REPO" rev-parse HEAD)

    # Create checkpoint reflecting this pipeline run
    _write_checkpoint "$REPO" "$HEAD_SHA" true "$PIPELINE_SHA"

    # Simulate a user commit added AFTER the pipeline run (the safety gap trigger)
    echo "user work" > "$REPO/user_work.txt"
    git -C "$REPO" add user_work.txt
    git -C "$REPO" commit -q -m "User: manual follow-up"
    CURRENT_HEAD=$(git -C "$REPO" rev-parse HEAD)

    # Verify setup: current HEAD is different from checkpoint commit_sha
    if [[ "$CURRENT_HEAD" == "$PIPELINE_SHA" ]]; then
        echo "SETUP ERROR: current_head == commit_sha — test setup is wrong"
        exit 1
    fi

    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=true
    PIPELINE_STATE_FILE=".claude/PIPELINE_STATE.md"

    cd "$REPO"
    source "${TEKHTON_HOME}/lib/checkpoint.sh"

    # Capture both output and exit code in a single call.
    # Using `|| rollback_exit=$?` prevents set -e from aborting the subshell.
    rollback_exit=0
    error_output=$(rollback_last_run 2>&1) || rollback_exit=$?

    if [[ "$rollback_exit" -eq 0 ]]; then
        echo "FAIL: 4.1 rollback should return 1 when user committed after pipeline"
        exit 1
    fi
    echo "PASS: 4.1 rollback returns 1 when current_head != commit_sha"

    # Verify the error message mentions git revert
    if echo "$error_output" | grep -qi "git revert"; then
        echo "PASS: 4.2 error message references git revert"
    else
        echo "FAIL: 4.2 error message should reference git revert, got: $error_output"
        exit 1
    fi

    # Verify the pipeline commit's sha is mentioned in the error
    short_sha=$(git -C "$REPO" rev-parse --short "$PIPELINE_SHA" 2>/dev/null || echo "$PIPELINE_SHA")
    if echo "$error_output" | grep -qF "$PIPELINE_SHA" || echo "$error_output" | grep -qF "$short_sha"; then
        echo "PASS: 4.3 error message includes the commit sha to revert"
    else
        echo "FAIL: 4.3 error message should include commit sha, got: $error_output"
        exit 1
    fi

    # Verify git history is NOT modified (user commit must still be there)
    post_head=$(git -C "$REPO" rev-parse HEAD)
    if [[ "$post_head" == "$CURRENT_HEAD" ]]; then
        echo "PASS: 4.4 git history unchanged after rejected rollback"
    else
        echo "FAIL: 4.4 git history should be unchanged, HEAD moved from $CURRENT_HEAD to $post_head"
        exit 1
    fi
)
[[ $? -eq 0 ]] && pass "4 current_head != commit_sha edge case (primary coverage gap)" \
               || { fail "4 current_head != commit_sha edge case (primary coverage gap)"; }

# =============================================================================
# Test 5: Rollback succeeds when current_head == commit_sha (committed path)
# =============================================================================
echo "=== Test 5: Happy path — committed rollback ==="

(
    REPO="$TMPDIR/t5"
    _make_git_repo "$REPO"
    HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

    # Pipeline commit
    echo "pipeline output" > "$REPO/pipeline_output.txt"
    git -C "$REPO" add pipeline_output.txt
    git -C "$REPO" commit -q -m "Pipeline: implement feature"
    PIPELINE_SHA=$(git -C "$REPO" rev-parse HEAD)

    # Checkpoint with auto_committed=true and commit_sha == current HEAD
    _write_checkpoint "$REPO" "$HEAD_SHA" true "$PIPELINE_SHA"

    # No additional commits — current_head == commit_sha

    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=true
    PIPELINE_STATE_FILE=".claude/PIPELINE_STATE.md"

    cd "$REPO"
    source "${TEKHTON_HOME}/lib/checkpoint.sh"

    if rollback_last_run 2>/dev/null; then
        echo "PASS: 5.1 rollback succeeded when current_head == commit_sha"
    else
        echo "FAIL: 5.1 rollback should succeed when current_head == commit_sha"
        exit 1
    fi

    # Verify the revert commit was created (HEAD moved forward with a revert)
    post_head=$(git -C "$REPO" rev-parse HEAD)
    if [[ "$post_head" != "$PIPELINE_SHA" ]]; then
        echo "PASS: 5.2 a revert commit was added (HEAD is now $post_head)"
    else
        echo "FAIL: 5.2 revert commit should have been created"
        exit 1
    fi

    # Verify checkpoint file was cleaned up
    if [[ ! -f "$REPO/.claude/CHECKPOINT_META.json" ]]; then
        echo "PASS: 5.3 checkpoint file cleaned up after successful rollback"
    else
        echo "FAIL: 5.3 checkpoint file should be removed after rollback"
        exit 1
    fi
)
[[ $? -eq 0 ]] && pass "5 happy path: committed rollback succeeds" \
               || { fail "5 happy path: committed rollback succeeds"; }

# =============================================================================
# Test 6: Rollback succeeds for uncommitted-changes path (no auto-commit)
# =============================================================================
echo "=== Test 6: Happy path — uncommitted rollback ==="

(
    REPO="$TMPDIR/t6"
    _make_git_repo "$REPO"
    HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

    # Checkpoint with auto_committed=false (pipeline made no commit)
    _write_checkpoint "$REPO" "$HEAD_SHA" false "null"

    # Pipeline created an untracked file (not staged — safety check only blocks
    # staged/unstaged changes to tracked files, not untracked files)
    echo "pipeline artifact" > "$REPO/artifact.txt"

    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=true
    PIPELINE_STATE_FILE=".claude/PIPELINE_STATE.md"

    cd "$REPO"
    source "${TEKHTON_HOME}/lib/checkpoint.sh"

    if rollback_last_run 2>/dev/null; then
        echo "PASS: 6.1 rollback succeeded for uncommitted path"
    else
        echo "FAIL: 6.1 rollback should succeed for uncommitted path"
        exit 1
    fi

    # Verify staged artifact was cleaned up
    if [[ ! -f "$REPO/artifact.txt" ]]; then
        echo "PASS: 6.2 uncommitted pipeline artifact removed"
    else
        echo "FAIL: 6.2 pipeline artifact should be removed after rollback"
        exit 1
    fi

    # Verify HEAD unchanged (no new commits)
    post_head=$(git -C "$REPO" rev-parse HEAD)
    if [[ "$post_head" == "$HEAD_SHA" ]]; then
        echo "PASS: 6.3 HEAD unchanged for uncommitted rollback"
    else
        echo "FAIL: 6.3 HEAD should be unchanged, was $HEAD_SHA, now $post_head"
        exit 1
    fi
)
[[ $? -eq 0 ]] && pass "6 happy path: uncommitted rollback succeeds" \
               || { fail "6 happy path: uncommitted rollback succeeds"; }

# =============================================================================
# Test 7: create_run_checkpoint preserves working tree after stashing
# =============================================================================
echo "=== Test 7: Stash preserves working tree ==="

(
    REPO="$TMPDIR/t7"
    _make_git_repo "$REPO"

    # Simulate user edits (e.g. adding a BUG to HUMAN_NOTES.md)
    mkdir -p "$REPO/.claude"
    echo "- [ ] BUG: three tests are failing" > "$REPO/HUMAN_NOTES.md"
    echo "modified" >> "$REPO/initial.txt"

    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=true
    TASK="test task"
    _CURRENT_MILESTONE=""

    cd "$REPO"
    source "${TEKHTON_HOME}/lib/checkpoint.sh"

    create_run_checkpoint 2>/dev/null

    # 7.1 Stash entry exists
    if git stash list 2>/dev/null | grep -qF "tekhton-checkpoint-"; then
        echo "PASS: 7.1 stash entry created"
    else
        echo "FAIL: 7.1 stash entry should exist in git stash list"
        exit 1
    fi

    # 7.2 HUMAN_NOTES.md still present in working tree with correct content
    if grep -qF "BUG: three tests are failing" "$REPO/HUMAN_NOTES.md" 2>/dev/null; then
        echo "PASS: 7.2 HUMAN_NOTES.md preserved in working tree"
    else
        echo "FAIL: 7.2 HUMAN_NOTES.md should still contain the BUG entry"
        exit 1
    fi

    # 7.3 Tracked file modifications preserved
    if grep -qF "modified" "$REPO/initial.txt" 2>/dev/null; then
        echo "PASS: 7.3 tracked file modifications preserved in working tree"
    else
        echo "FAIL: 7.3 tracked file modifications should still be present"
        exit 1
    fi

    # 7.4 Checkpoint metadata created with had_uncommitted=true
    if grep -q '"had_uncommitted": true' "$REPO/.claude/CHECKPOINT_META.json" 2>/dev/null; then
        echo "PASS: 7.4 checkpoint metadata records had_uncommitted=true"
    else
        echo "FAIL: 7.4 checkpoint should record had_uncommitted=true"
        exit 1
    fi
)
[[ $? -eq 0 ]] && pass "7 stash preserves working tree (HUMAN_NOTES.md bug fix)" \
               || { fail "7 stash preserves working tree (HUMAN_NOTES.md bug fix)"; }

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    echo "  FAIL: $FAIL test(s) failed"
    exit 1
fi

echo "All tests passed."
exit 0
