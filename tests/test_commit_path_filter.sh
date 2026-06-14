#!/usr/bin/env bash
# =============================================================================
# test_commit_path_filter.sh — S1 denylist staging filter
# (lib/finalize_commit_staging.sh::_is_path_committable)
#
# Replaces the pre-S1 allowlist test. The commit staging filter is now a
# DENYLIST: every dirty path is committed EXCEPT pure run transients. This
# directly guards the stranding regression that recurred multiple times — the
# bash pipeline tree (lib/, stages/, prompts/, platforms/) MUST be committable,
# because the old allowlist dropped it and stranded real milestone work.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
FAIL=0
_pass() { echo "PASS: $*"; }
_fail() { echo "FAIL: $*"; FAIL=1; }

# Run the predicate in a subshell with a known session dir so the session-dir
# transient rule is exercised deterministically.
_committable() {
    local path="$1"
    (
        unset CODER_SUMMARY_FILE
        export TEKHTON_SESSION_DIR=".tekhton/session-abc"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/finalize_commit_staging.sh"
        if _is_path_committable "$path"; then echo committable; else echo skipped; fi
    )
}

# --- MUST be committable (substantive — the regression surface) -------------
for p in \
    lib/quota_probe.sh \
    lib/common.sh \
    stages/coder.sh \
    prompts/reviewer.prompt.md \
    platforms/web/_adapter.sh \
    internal/finalize/orchestrator.go \
    cmd/tekhton/run.go \
    .claude/milestones/MANIFEST.cfg \
    .claude/milestones/m99-foo.md \
    VERSION \
    docs/x.md \
    some_new_toplevel_dir/file.go ; do
    r=$(_committable "$p")
    if [[ "$r" == committable ]]; then _pass "committable: $p"; else _fail "STRANDED: $p (got $r)"; fi
done

# --- MUST be skipped (pure transients) -------------------------------------
for p in \
    .claude/logs/run.log \
    .claude/indexer-venv/bin/python \
    .claude/serena/cache.json \
    .tekhton/session-abc/tui_status.json ; do
    r=$(_committable "$p")
    if [[ "$r" == skipped ]]; then _pass "skipped transient: $p"; else _fail "transient committed: $p (got $r)"; fi
done

# --- .tekhton reports (non-session) ARE versioned → committable ------------
r=$(_committable ".tekhton/RUN_RESULT.json")
if [[ "$r" == committable ]]; then _pass ".tekhton report committable"; else _fail ".tekhton report skipped (got $r)"; fi

if [[ "$FAIL" -ne 0 ]]; then exit 1; fi
echo "commit path filter test passed"
