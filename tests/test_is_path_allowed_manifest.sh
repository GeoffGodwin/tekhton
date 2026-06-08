#!/usr/bin/env bash
# =============================================================================
# test_is_path_allowed_manifest.sh — m50 coverage gap: unit tests for
# _is_path_allowed in lib/finalize_commit_staging.sh, specifically verifying
# that .claude/milestones/MANIFEST.cfg is admitted by the bookkeeping
# allowlist (so the guard, not the allowlist, is the control point).
#
# The security review identified this gap: "The guard intercepts regardless
# of the allowlist decision, so there is no correctness gap today. Worth a
# unit test if the allowlist logic changes in the future."
#
# Tests:
#   1. MANIFEST.cfg is allowed by _pipeline_bookkeeping_globs (exact entry).
#   2. A milestone file (.claude/milestones/m01_foo.md) is allowed by the
#      `.claude/milestones/m` prefix entry.
#   3. Bookkeeping dirs (.tekhton/, internal/, cmd/, tests/) are allowed.
#   4. An unrelated file (random_file.txt) is NOT allowed.
#   5. A near-miss path (.claude/milestones/OTHER.cfg) is NOT allowed by
#      exact-match semantics (the prefix entry covers `m` files and the
#      explicit entry covers MANIFEST.cfg only).
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

FAIL=0
_pass() { echo "PASS: $*"; }
_fail() { echo "FAIL: $*"; FAIL=1; }

# Source the staging helpers directly. common.sh is not needed — the helpers
# have no dependency on log/warn. Using a subshell ensures the global
# CODER_SUMMARY_FILE is unset so _coder_declared_files returns empty output
# and only the bookkeeping globs contribute to the allowlist.
_is_allowed_in_subshell() {
    local path="$1"
    (
        unset CODER_SUMMARY_FILE
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/finalize_commit_staging.sh"
        if _is_path_allowed "$path"; then
            echo "allowed"
        else
            echo "denied"
        fi
    )
}

# ---------------------------------------------------------------------------
# 1. MANIFEST.cfg — explicit bookkeeping entry.
# ---------------------------------------------------------------------------
result=$(_is_allowed_in_subshell ".claude/milestones/MANIFEST.cfg")
if [[ "$result" == "allowed" ]]; then
    _pass "1: .claude/milestones/MANIFEST.cfg is in bookkeeping allowlist"
else
    _fail "1: .claude/milestones/MANIFEST.cfg denied by allowlist (got: $result)"
fi

# ---------------------------------------------------------------------------
# 2. Milestone file — matched by the .claude/milestones/m prefix.
# ---------------------------------------------------------------------------
result=$(_is_allowed_in_subshell ".claude/milestones/m01_feature.md")
if [[ "$result" == "allowed" ]]; then
    _pass "2: .claude/milestones/m01_feature.md allowed by milestone prefix"
else
    _fail "2: .claude/milestones/m01_feature.md denied (got: $result)"
fi

# ---------------------------------------------------------------------------
# 3a. .tekhton/ prefix entry — pipeline state files.
# ---------------------------------------------------------------------------
result=$(_is_allowed_in_subshell ".tekhton/STATE.json")
if [[ "$result" == "allowed" ]]; then
    _pass "3a: .tekhton/STATE.json allowed by bookkeeping prefix"
else
    _fail "3a: .tekhton/STATE.json denied (got: $result)"
fi

# ---------------------------------------------------------------------------
# 3b. internal/ — Go implementation tree added for m34.2/m35.x dogfooding.
# ---------------------------------------------------------------------------
result=$(_is_allowed_in_subshell "internal/finalize/orchestrator.go")
if [[ "$result" == "allowed" ]]; then
    _pass "3b: internal/finalize/orchestrator.go allowed by internal/ prefix"
else
    _fail "3b: internal/finalize/orchestrator.go denied (got: $result)"
fi

# ---------------------------------------------------------------------------
# 3c. cmd/ prefix.
# ---------------------------------------------------------------------------
result=$(_is_allowed_in_subshell "cmd/tekhton/run.go")
if [[ "$result" == "allowed" ]]; then
    _pass "3c: cmd/tekhton/run.go allowed by cmd/ prefix"
else
    _fail "3c: cmd/tekhton/run.go denied (got: $result)"
fi

# ---------------------------------------------------------------------------
# 4. Unrelated file — must NOT be allowed.
# ---------------------------------------------------------------------------
result=$(_is_allowed_in_subshell "random_file.txt")
if [[ "$result" == "denied" ]]; then
    _pass "4: random_file.txt correctly denied"
else
    _fail "4: random_file.txt allowed (allowlist too broad)"
fi

# ---------------------------------------------------------------------------
# 5. Near-miss: .claude/milestones/OTHER.cfg — must NOT be allowed.
#    The explicit entry is MANIFEST.cfg; the prefix entry starts with `m`
#    so OTHER.cfg does not match either.
# ---------------------------------------------------------------------------
result=$(_is_allowed_in_subshell ".claude/milestones/OTHER.cfg")
if [[ "$result" == "denied" ]]; then
    _pass "5: .claude/milestones/OTHER.cfg correctly denied (not MANIFEST.cfg, not m-prefix)"
else
    _fail "5: .claude/milestones/OTHER.cfg incorrectly allowed"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "is_path_allowed manifest test passed"
