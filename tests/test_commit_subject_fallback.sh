#!/usr/bin/env bash
# =============================================================================
# test_commit_subject_fallback.sh — m44 acceptance test for the commit-subject
# regression that fell back to ".claude/project_version.cfg" on every
# save_exit commit.
#
# Three scenarios exercise the two halves of the m44 fix:
#
#   Scenario 1 — Empty TASK, empty milestone, mixed diff.
#       Validates Goal 1 (lib/hooks.sh sort-by-lines-changed): with both
#       .claude/project_version.cfg and a larger file in the diff, the
#       refined fallback must NOT pick the alphabetically-first file.
#
#   Scenario 2 — Empty TASK, populated milestone via env export.
#       Validates Goal 2 (lib/orchestrate_save.sh export propagation): a
#       _CURRENT_MILESTONE in the environment must surface in the resulting
#       commit subject (via get_milestone_title + the existing m40.2
#       fallback in generate_commit_message).
#
#   Scenario 3 — Populated TASK, empty milestone.
#       Smoke check that Goals 1+2 do not regress the existing happy path:
#       a real task string must still produce a TASK-derived subject.
#
# Plus one grep-based AC verification (orchestrate_save.sh export presence)
# and one regression guard (no save_exit subject ends in
# .claude/project_version.cfg).
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"

FAIL=0
_pass() { echo "PASS: $*"; }
_fail() { echo "FAIL: $*"; FAIL=1; }

# _seed_repo PROJECT_DIR
# Creates a throwaway git repo with a committed baseline so subsequent edits
# show up in `git diff HEAD --stat`.
_seed_repo() {
    local dir="$1"
    mkdir -p "$dir"
    (
        cd "$dir"
        git init --quiet
        git config user.email "test@example.invalid"
        git config user.name "Test"
        git config commit.gpgsign false
        # Baseline files so we can edit them and see them in the diff.
        mkdir -p .claude
        printf '0.0.1\n' > .claude/project_version.cfg
        printf 'baseline\n' > big_file.sh
        printf 'baseline\n' > medium_file.sh
        git add .claude/project_version.cfg big_file.sh medium_file.sh
        git commit --quiet -m 'baseline'
    )
}

# _seed_diff PROJECT_DIR
# Stages a mixed diff: a small one-line bookkeeping bump in
# .claude/project_version.cfg PLUS a large multi-line edit in big_file.sh,
# PLUS a medium edit in medium_file.sh. After this:
#   - .claude/project_version.cfg: 1 line changed
#   - big_file.sh: ~50 lines changed
#   - medium_file.sh: ~10 lines changed
# The sort-by-lines-changed fallback must pick big_file.sh, never
# .claude/project_version.cfg (which sorts first alphabetically).
_seed_diff() {
    local dir="$1"
    (
        cd "$dir"
        printf '0.0.2\n' > .claude/project_version.cfg
        # Big edit — 50 lines.
        {
            printf 'baseline\n'
            for i in $(seq 1 50); do printf 'line %d\n' "$i"; done
        } > big_file.sh
        # Medium edit — 10 lines.
        {
            printf 'baseline\n'
            for i in $(seq 1 10); do printf 'medium %d\n' "$i"; done
        } > medium_file.sh
    )
}

# _seed_claude_md PROJECT_DIR MILESTONE_NUM TITLE
# Writes a minimal CLAUDE.md the inline parse_milestones path can recognize.
# Disables DAG so the milestone_query falls back to parse_milestones (which
# does not require .claude/milestones/ infra).
_seed_claude_md() {
    local dir="$1"
    local num="$2"
    local title="$3"
    cat > "${dir}/CLAUDE.md" <<EOF
# Project

## Milestones

#### Milestone ${num}: ${title}

##### Acceptance Criteria
- placeholder
EOF
}

# _gen_subject TASK MILESTONE_NUM PROJECT_DIR
# Runs generate_commit_message in a subshell with TEKHTON_HOME set and
# returns the first line (the subject) on stdout. Sources the minimum bash
# surface generate_commit_message needs: common.sh, hooks.sh, and the
# milestone-query chain via milestone_dag.sh → milestone_query.sh.
_gen_subject() {
    local task="$1"
    local ms="$2"
    local dir="$3"
    (
        cd "$dir"
        export TEKHTON_HOME PROJECT_DIR="$dir"
        export MILESTONE_DAG_ENABLED=false
        # generate_commit_message looks up CODER_SUMMARY at this path.
        export CODER_SUMMARY_FILE="${dir}/.tekhton/CODER_SUMMARY.md"
        mkdir -p "${dir}/.tekhton"
        : > "$CODER_SUMMARY_FILE"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/common.sh"
        # milestones.sh hosts parse_milestones (the inline fallback path);
        # milestone_query.sh hosts get_milestone_title (the m40.2 fallback
        # generate_commit_message consults when TASK is empty). milestone_ops
        # is sourced via the same chain used by the in-pipeline render.
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/milestones.sh"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/milestone_query.sh"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/milestone_ops.sh"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/hooks.sh"
        # drift_cleanup.sh is normally sourced before hooks.sh in the
        # pipeline; the guards in generate_commit_message tolerate its
        # absence (get_completed_nonblocking_notes / get_resolved_drift_observations).
        generate_commit_message "$task" "$ms" "" 2>/dev/null | head -1
    )
}

# ---------------------------------------------------------------------------
# Scenario 1: Empty TASK, empty milestone, mixed diff.
# Goal 1 regression guard — must NOT pick .claude/project_version.cfg.
# ---------------------------------------------------------------------------

_S1_DIR="${TMPDIR}/s1"
_seed_repo "$_S1_DIR"
_seed_diff "$_S1_DIR"

_S1_SUBJECT=$(_gen_subject "" "" "$_S1_DIR")
if [[ -z "$_S1_SUBJECT" ]]; then
    _fail "scenario 1: generate_commit_message produced empty subject"
elif [[ "$_S1_SUBJECT" == *".claude/project_version.cfg"* ]]; then
    _fail "scenario 1: subject still falls back to project_version.cfg — got: $_S1_SUBJECT"
elif [[ "$_S1_SUBJECT" == *"big_file.sh"* ]]; then
    _pass "scenario 1: subject picks the most-changed file — $_S1_SUBJECT"
else
    _fail "scenario 1: subject did not name big_file.sh — got: $_S1_SUBJECT"
fi

# Regression guard echoed via the AC's grep assertion.
if echo "$_S1_SUBJECT" | grep -q 'project_version.cfg'; then
    _fail "scenario 1 AC: subject contains 'project_version.cfg' — $_S1_SUBJECT"
else
    _pass "scenario 1 AC: subject does not contain 'project_version.cfg'"
fi

# ---------------------------------------------------------------------------
# Scenario 2: Empty TASK, populated milestone via env export.
# Goal 2 outcome — derives subject from get_milestone_title.
# ---------------------------------------------------------------------------

_S2_DIR="${TMPDIR}/s2"
_seed_repo "$_S2_DIR"
_seed_diff "$_S2_DIR"
_seed_claude_md "$_S2_DIR" "44" "Commit Subject Regression"

_S2_SUBJECT=$(_gen_subject "" "44" "$_S2_DIR")
if [[ -z "$_S2_SUBJECT" ]]; then
    _fail "scenario 2: generate_commit_message produced empty subject"
elif [[ "$_S2_SUBJECT" == *"Commit Subject Regression"* ]]; then
    _pass "scenario 2: subject derived from milestone title — $_S2_SUBJECT"
elif [[ "$_S2_SUBJECT" == *".claude/project_version.cfg"* ]]; then
    _fail "scenario 2: subject fell through to project_version.cfg fallback — $_S2_SUBJECT"
else
    _fail "scenario 2: subject did not derive from milestone title — got: $_S2_SUBJECT"
fi

# ---------------------------------------------------------------------------
# Scenario 3: Populated TASK, empty milestone.
# Smoke check — TASK-driven subject path must still win.
# ---------------------------------------------------------------------------

_S3_DIR="${TMPDIR}/s3"
_seed_repo "$_S3_DIR"
_seed_diff "$_S3_DIR"

_S3_SUBJECT=$(_gen_subject "Implement feature X" "" "$_S3_DIR")
if [[ "$_S3_SUBJECT" == *"Implement feature X"* ]]; then
    _pass "scenario 3: subject derived from TASK — $_S3_SUBJECT"
else
    _fail "scenario 3: subject did not derive from TASK — got: $_S3_SUBJECT"
fi

# ---------------------------------------------------------------------------
# AC grep verification: _orch_record_save_state exports TASK,
# _CURRENT_MILESTONE, and MILESTONE_MODE before its finalize_run 1 call.
# ---------------------------------------------------------------------------

_EXPORT_HITS=$(grep -cE "^[[:space:]]*export (TASK|_CURRENT_MILESTONE|MILESTONE_MODE)" \
    "${TEKHTON_HOME}/lib/orchestrate_save.sh" || true)
if [[ "$_EXPORT_HITS" -eq 3 ]]; then
    _pass "orchestrate_save.sh exports all three env vars (TASK / _CURRENT_MILESTONE / MILESTONE_MODE)"
else
    _fail "orchestrate_save.sh: expected 3 export lines, found $_EXPORT_HITS"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "commit subject fallback test passed"
