#!/usr/bin/env bash
# =============================================================================
# test_autoadvance_per_milestone_commits.sh — m48 shim-boundary integration
# test for the per-iteration sentinel-clear + commit-banner behavior added
# to cmd/tekhton/run.go::runAutoAdvanceLoop.
#
# What this test covers
# ---------------------
# The Go-side reset (clearAutoAdvanceIterationState) and banner
# (emitAutoAdvanceCommitBanner) live inside the runAutoAdvanceLoop, which
# only the tekhton binary can drive. The Go unit tests in
# cmd/tekhton/run_test.go cover the helpers in isolation with full
# pre-/post-conditions; this test crosses the bash-shim ↔ Go binary
# boundary and asserts that the m48 code paths are wired into the
# production binary without regressing its startup, --help, or panic
# behavior.
#
# Scope note
# ----------
# A truly end-to-end "drive 3 milestones with stubbed agents and assert 3
# separate [MILESTONE X.Y ✓] commits land" would require a fake agent that
# emits CODER_SUMMARY.md / REVIEWER_REPORT.md / TESTER_REPORT.md with
# matching verdicts and acceptance content per stage — far beyond
# testdata/fake_agent.sh's two-turn-and-exit shape. The Go unit tests in
# cmd/tekhton/run_test.go cover:
#
#   - TestClearAutoAdvanceIterationState_RemovesSentinels — planted sentinels
#     removed
#   - TestClearAutoAdvanceIterationState_GracefulOnMissing — idempotent on
#     missing files
#   - TestEmitAutoAdvanceCommitBanner_DetectsMilestoneCommit — success banner
#     fires for `[MILESTONE X.Y ✓]` HEAD subjects, warn banner fires for
#     generic subjects, against a real git repo
#
# This shim-boundary test verifies the integration is wired into the binary
# (the m48 code path doesn't panic, --help still works, the binary still
# recognizes --auto-advance + --auto-advance-limit + --milestone, sentinel-
# cleanup helper exists in the binary symbol table indirectly via the call
# site).
#
# Self-skip
# ---------
# Skips cleanly when the tekhton binary is not built (fresh-clone CI before
# `make build`), matching the pattern in tests/test_state_writer_resume_fields.sh.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Always prefer the binary built FROM THIS TREE — this test verifies the
# m48 changes in the working repo, so falling back to an inherited
# TEKHTON_BIN from a parent shell (e.g. tekhton-stable when this suite
# runs as a pipeline TEST_CMD) would test the wrong binary. The
# TEKHTON_BIN env var is honored only when no local binary exists.
LOCAL_BIN="${TEKHTON_HOME}/bin/tekhton"
if [[ -x "$LOCAL_BIN" ]]; then
    TEKHTON_BIN="$LOCAL_BIN"
else
    TEKHTON_BIN="${TEKHTON_BIN:-${LOCAL_BIN}}"
fi

if [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "SKIP: tekhton binary not built (run 'make build' to enable)"
    exit 0
fi

TMPDIR=$(mktemp -d -t tekhton-aa-m48-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0
_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

# ----------------------------------------------------------------------------
# Fixture: minimal greenfield project layout
# ----------------------------------------------------------------------------
PROJECT_DIR="${TMPDIR}/project"
mkdir -p "${PROJECT_DIR}/.tekhton" \
         "${PROJECT_DIR}/.claude/milestones" \
         "${PROJECT_DIR}/.claude/logs" \
         "${PROJECT_DIR}/.claude/agents"

(
    cd "$PROJECT_DIR"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false
)

# Minimal pipeline.conf — supplies just enough for env loaders to settle.
cat > "${PROJECT_DIR}/.claude/pipeline.conf" <<'CONF_EOF'
PROJECT_NAME=m48-aa-fixture
CODER_ROLE_FILE=.claude/agents/coder.md
REVIEWER_ROLE_FILE=.claude/agents/reviewer.md
TESTER_ROLE_FILE=.claude/agents/tester.md
JR_CODER_ROLE_FILE=.claude/agents/jr-coder.md
ARCHITECT_ROLE_FILE=.claude/agents/architect.md
PROJECT_RULES_FILE=CLAUDE.md
ARCHITECTURE_FILE=ARCHITECTURE.md
ANALYZE_CMD=true
TEST_CMD=true
BUILD_CHECK_CMD=true
MAX_REVIEW_CYCLES=1
AUTO_ADVANCE=true
AUTO_ADVANCE_LIMIT=3
CONF_EOF

# Stub agent role files (content not exercised — agent is short-circuited).
for role in coder reviewer tester jr-coder architect; do
    echo "stub" > "${PROJECT_DIR}/.claude/agents/${role}.md"
done

# Three milestone fixture entries.
cat > "${PROJECT_DIR}/.claude/milestones/MANIFEST.cfg" <<'MAN_EOF'
# id|file|deps|status|title
m1|m1-fake.md||todo|First fake milestone
m2|m2-fake.md|m1|todo|Second fake milestone
m3|m3-fake.md|m2|todo|Third fake milestone
MAN_EOF

for n in 1 2 3; do
    cat > "${PROJECT_DIR}/.claude/milestones/m${n}-fake.md" <<EOF
<!-- milestone-meta
id: "${n}"
status: "todo"
-->
# m${n} — Fake milestone ${n}
## Overview
Stub milestone for the m48 shim-boundary test.
## Acceptance Criteria
- [ ] Touch artifact file ${n}.
EOF
done

# Stub CLAUDE.md so any rules-file resolver finds something.
echo "# stub" > "${PROJECT_DIR}/CLAUDE.md"
echo "# stub" > "${PROJECT_DIR}/ARCHITECTURE.md"

(
    cd "$PROJECT_DIR"
    git add -A
    git commit -q -m "initial fixture"
)

# Plant the three sentinels — present-but-untouched is what the regression
# looks like (each iteration after the first inherits them).
printf '1\n# completion_gate_failed_substantive_work_only\n' \
    > "${PROJECT_DIR}/.tekhton/.final_check_result"
printf 'completion_gate_failed_substantive_work_only\n' \
    > "${PROJECT_DIR}/.tekhton/.final_check_reason"
printf 'skipped\n' > "${PROJECT_DIR}/.tekhton/.commit_decision"

# ----------------------------------------------------------------------------
# Drive the binary. TEKHTON_AGENT_BINARY=/bin/false short-circuits any real
# agent invocation. The initial RunSingle will fail, so the auto-advance
# loop body itself won't be entered in this minimal test (gating clearAutoAdvanceIterationState
# is verified at the unit-test layer); we assert here that the binary's m48
# code path doesn't panic and that flag-parsing still works.
# ----------------------------------------------------------------------------
export TEKHTON_HOME
export PROJECT_DIR
export TEKHTON_AGENT_BINARY="/bin/false"
export TEKHTON_TEST_MODE="true"
export TEKHTON_DIR=".tekhton"

RUN_OUT="${TMPDIR}/run.out"
RUN_ERR="${TMPDIR}/run.err"

# Best-effort drive: any non-zero exit is expected (no real agent). The test
# asserts on side effects, not exit code.
"$TEKHTON_BIN" run \
    --milestone m1 \
    --auto-advance \
    --auto-advance-limit 3 \
    --no-tui \
    --project-dir "$PROJECT_DIR" \
    --tekhton-home "$TEKHTON_HOME" \
    > "$RUN_OUT" 2> "$RUN_ERR" || true

# ----------------------------------------------------------------------------
# Assertions
# ----------------------------------------------------------------------------

# Assertion A: binary executed and produced output.
if [[ -s "$RUN_OUT" ]] || [[ -s "$RUN_ERR" ]]; then
    _pass "tekhton run executed (stdout/stderr captured)"
else
    _fail "no run output captured"
fi

# Assertion B: no Go runtime panic on the m48 code path. Panics surface as
# `panic:` or `goroutine N [running]` stack traces in stderr.
panic_count=$(grep -c 'panic:\|goroutine [0-9]* \[running\]' "$RUN_ERR" 2>/dev/null || true)
panic_count="${panic_count:-0}"
if (( panic_count > 0 )); then
    _fail "binary panicked on auto-advance code path"
    echo "--- stderr ---" >&2
    tail -30 "$RUN_ERR" >&2
else
    _pass "no Go runtime panic in auto-advance code path"
fi

# Assertion C: --help works after m48 changes (no build regression).
if "$TEKHTON_BIN" --help >/dev/null 2>&1; then
    _pass "binary --help works after m48 changes"
else
    _fail "binary --help broken — likely build regression"
fi

# Assertion D: the run subcommand accepts --auto-advance-limit (the m48 path
# touches the auto-advance flag handling).
help_out=$("$TEKHTON_BIN" run --help 2>&1 || true)
if grep -q -- '--auto-advance-limit' <<< "$help_out"; then
    _pass "tekhton run --help advertises --auto-advance-limit"
else
    _fail "--auto-advance-limit missing from 'tekhton run --help'"
fi

# Assertion E: the run subcommand accepts --milestone (the loop's required
# precondition).
if grep -q -- '--milestone' <<< "$help_out"; then
    _pass "tekhton run --help advertises --milestone"
else
    _fail "--milestone missing from 'tekhton run --help'"
fi

# Assertion F: the m48 reset symbol — clearAutoAdvanceIterationState's
# warn-on-error path — is linked into the binary. We probe by scanning the
# binary's string table for the unique format literal only this code path
# emits. The literal must survive `-trimpath -ldflags='-s -w'` (which strip
# symbols but preserve string literals used at runtime).
#
# Note: `strings ... | grep -q` under `set -euo pipefail` would surface a
# SIGPIPE (141) from strings being killed when grep exits early. Use a
# count-based form with `|| true` instead.
reset_marker='clear iteration state for'
reset_count=$(strings "$TEKHTON_BIN" 2>/dev/null | grep -c -F "$reset_marker" || true)
reset_count="${reset_count:-0}"
if (( reset_count > 0 )); then
    _pass "binary contains m48 reset format string"
else
    _fail "m48 reset format string missing from binary — code not linked in"
fi

# Documentation: report sentinel state for diagnostic value. The Go unit test
# TestClearAutoAdvanceIterationState_RemovesSentinels is the authoritative
# check for the removal semantics; this echo is informational.
echo "Note: planted sentinels (final state):"
echo "  .final_check_result: $([[ -f "${PROJECT_DIR}/.tekhton/.final_check_result" ]] && echo PRESENT || echo REMOVED)"
echo "  .final_check_reason: $([[ -f "${PROJECT_DIR}/.tekhton/.final_check_reason" ]] && echo PRESENT || echo REMOVED)"
echo "  .commit_decision:    $([[ -f "${PROJECT_DIR}/.tekhton/.commit_decision" ]] && echo PRESENT || echo REMOVED)"

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "m48 shim-boundary integration test passed"
