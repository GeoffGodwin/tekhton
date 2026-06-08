#!/usr/bin/env bash
# =============================================================================
# test_manifest_write_guard.sh — m50 shim-boundary test for the manifest
# write guard. Drives lib/finalize_commit.sh::_check_manifest_write_guard
# across three scenarios:
#
#   1. Stage-time commit with MANIFEST.cfg staged and no .finalize_active
#      sentinel → guard unstages MANIFEST.cfg, exits 0, emits warn.
#   2. Finalize-time commit with the sentinel planted → guard is a no-op,
#      MANIFEST.cfg stays staged.
#   3. Operator override TEKHTON_MANIFEST_WRITE_OVERRIDE=1 with no
#      sentinel → guard skips the unstage, emits "override set" warn,
#      MANIFEST.cfg stays staged.
#
# Self-skips cleanly when bash + git aren't available — matches the
# tests/test_state_writer_resume_fields.sh pattern.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

if ! command -v git >/dev/null 2>&1; then
    echo "SKIP: git not on PATH"
    exit 0
fi

FAIL=0
_pass() { echo "PASS: $*"; }
_fail() { echo "FAIL: $*"; FAIL=1; }

# _seed_repo PROJECT_DIR
# Initializes a throwaway git repo with the MANIFEST.cfg parent directories
# and a baseline tracked file (so HEAD exists and `git restore --staged`
# has something to revert against).
_seed_repo() {
    local proj="$1"
    mkdir -p "$proj/.claude/milestones" "$proj/.tekhton"
    (
        cd "$proj"
        git init -q
        git config user.email test@example.com
        git config user.name Test
        git config commit.gpgsign false
        printf 'm01|done\n' > .claude/milestones/MANIFEST.cfg
        git add .claude/milestones/MANIFEST.cfg
        git commit -q -m 'seed: manifest baseline'
    )
}

# _run_guard PROJECT_DIR [SENTINEL_PRESENT] [OVERRIDE]
# Sources lib/finalize_commit.sh in a fresh subshell against the given
# project directory, plants the sentinel if requested, and invokes
# _check_manifest_write_guard. Returns the captured stderr so tests can
# assert on warning text.
_run_guard() {
    local proj="$1"
    local sentinel_present="${2:-false}"
    local override="${3:-}"
    (
        export PROJECT_DIR="$proj"
        export TEKHTON_HOME
        export TEKHTON_DIR=".tekhton"
        if [[ "$sentinel_present" = "true" ]]; then
            printf 'active\n' > "${proj}/.tekhton/.finalize_active"
        fi
        if [[ -n "$override" ]]; then
            export TEKHTON_MANIFEST_WRITE_OVERRIDE="$override"
        fi
        cd "$proj"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/common.sh"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/finalize_commit.sh"
        _check_manifest_write_guard
    )
}

# ---------------------------------------------------------------------------
# Scenario 1: stage-time write with no sentinel — guard must unstage and warn.
# ---------------------------------------------------------------------------
PROJ1="${TMPDIR}/scenario1"
_seed_repo "$PROJ1"
# Stage a rogue MANIFEST.cfg edit.
(
    cd "$PROJ1"
    printf 'm01|split\nm01.1|todo\n' > .claude/milestones/MANIFEST.cfg
    git add .claude/milestones/MANIFEST.cfg
)

_OUT1=$(_run_guard "$PROJ1" false "" 2>&1) || true
# After the guard, MANIFEST.cfg should not be staged.
if (cd "$PROJ1" && git diff --cached --name-only) | grep -qx '.claude/milestones/MANIFEST.cfg'; then
    _fail "scenario 1: MANIFEST.cfg still staged after guard (out: $_OUT1)"
else
    _pass "scenario 1: MANIFEST.cfg unstaged after guard"
fi
if echo "$_OUT1" | grep -q 'Refusing to commit'; then
    _pass "scenario 1: guard emitted Refusing-to-commit warning"
else
    _fail "scenario 1: missing warning (out: $_OUT1)"
fi

# ---------------------------------------------------------------------------
# Scenario 2: finalize-time write WITH sentinel — guard is a no-op.
# ---------------------------------------------------------------------------
PROJ2="${TMPDIR}/scenario2"
_seed_repo "$PROJ2"
(
    cd "$PROJ2"
    printf 'm01|done\nm02|done\n' > .claude/milestones/MANIFEST.cfg
    git add .claude/milestones/MANIFEST.cfg
)

_OUT2=$(_run_guard "$PROJ2" true "" 2>&1) || true
if (cd "$PROJ2" && git diff --cached --name-only) | grep -qx '.claude/milestones/MANIFEST.cfg'; then
    _pass "scenario 2: MANIFEST.cfg stays staged with finalize sentinel"
else
    _fail "scenario 2: MANIFEST.cfg unstaged even with sentinel (out: $_OUT2)"
fi
if echo "$_OUT2" | grep -q 'Refusing to commit'; then
    _fail "scenario 2: guard emitted warning when sentinel present"
else
    _pass "scenario 2: guard silent when sentinel present"
fi

# ---------------------------------------------------------------------------
# Scenario 3: operator override — no sentinel but TEKHTON_MANIFEST_WRITE_OVERRIDE=1.
# ---------------------------------------------------------------------------
PROJ3="${TMPDIR}/scenario3"
_seed_repo "$PROJ3"
(
    cd "$PROJ3"
    printf 'm99|todo\n' >> .claude/milestones/MANIFEST.cfg
    git add .claude/milestones/MANIFEST.cfg
)

_OUT3=$(_run_guard "$PROJ3" false "1" 2>&1) || true
if (cd "$PROJ3" && git diff --cached --name-only) | grep -qx '.claude/milestones/MANIFEST.cfg'; then
    _pass "scenario 3: MANIFEST.cfg stays staged under operator override"
else
    _fail "scenario 3: override did not bypass guard (out: $_OUT3)"
fi
if echo "$_OUT3" | grep -q 'override set'; then
    _pass "scenario 3: guard emitted override-set warning"
else
    _fail "scenario 3: missing override-set warning (out: $_OUT3)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "manifest write guard test passed"
