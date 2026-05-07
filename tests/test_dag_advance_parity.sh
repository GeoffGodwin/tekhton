#!/usr/bin/env bash
# Test: tekhton dag advance cross-process parity.
#
# Asserts that `tekhton dag advance ID STATUS` correctly mutates the on-disk
# MANIFEST.cfg, and that subsequent bash `load_manifest` + `_DAG_*` array
# queries see the updated status. This is the advance-subcommand gap identified
# in the m14 reviewer report: the parity script verifies frontier/active/
# validate/migrate but not advance.
#
# Requires the `tekhton` binary on PATH (built via `make build`). The test
# runner's preamble builds it; if it's absent the test exits with SKIP.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_DAG_ENABLED=true
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
LOG_DIR="${TMPDIR}/.claude/logs"
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
TEST_CMD=""
ANALYZE_CMD=""
MILESTONE_ARCHIVE_FILE="${TMPDIR}/MILESTONE_ARCHIVE.md"

export MILESTONE_DAG_ENABLED MILESTONE_DIR MILESTONE_MANIFEST

mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}"

source "${TEKHTON_HOME}/lib/state.sh"
run_build_gate() { return 0; }
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"

cd "$TMPDIR"

PASS=0
FAIL=0

assert() {
    local desc="$1" result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# Skip gracefully when the binary isn't available. The test runner builds it
# up-front; absence means Go isn't installed on this machine.
if ! command -v tekhton >/dev/null 2>&1; then
    echo "  SKIP: tekhton binary not on PATH — skipping advance parity test"
    echo ""
    echo "Passed: 0  Failed: 0  Skipped: 1"
    exit 0
fi

# ===========================================================================
# Fixture
# ---------------------------------------------------------------------------
# Layout:  m01 (done)
#           └── m02 (in_progress)  ←── advance target
#           │    └── m03 (pending)
#           └── m04 (pending)
#
# After advancing m02 → done:
#   frontier should include m03 (dep m02 now done) and m04 (dep m01 already done)
#   m01 / m03 / m04 statuses unchanged
# ===========================================================================

MANIFEST_DIR="${TMPDIR}/.claude/milestones"
mkdir -p "$MANIFEST_DIR"
MANIFEST_PATH="${MANIFEST_DIR}/MANIFEST.cfg"

cat > "$MANIFEST_PATH" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Foundation|done||m01.md|
m02|Core Work|in_progress|m01|m02.md|
m03|Next Step|pending|m02|m03.md|
m04|Parallel|pending|m01|m04.md|
EOF

# Touch stub milestone files so validate won't flag missing files.
for f in m01.md m02.md m03.md m04.md; do
    touch "${MANIFEST_DIR}/${f}"
done

# ===========================================================================
echo "--- Test: advance m02 → done ---"

tekhton dag advance --path "$MANIFEST_PATH" m02 done

# Reload manifest into bash _DAG_* arrays to simulate what the bash shim does
# after a cross-process advance.
load_manifest "$MANIFEST_PATH"

result=0
status_m02=$(dag_get_status m02)
[[ "$status_m02" == "done" ]] && result=0 || result=1
assert "dag_get_status m02 == done after advance (got: $status_m02)" "$result"

result=0
status_m01=$(dag_get_status m01)
[[ "$status_m01" == "done" ]] && result=0 || result=1
assert "dag_get_status m01 unchanged (got: $status_m01)" "$result"

result=0
status_m03=$(dag_get_status m03)
[[ "$status_m03" == "pending" ]] && result=0 || result=1
assert "dag_get_status m03 unchanged (got: $status_m03)" "$result"

result=0
status_m04=$(dag_get_status m04)
[[ "$status_m04" == "pending" ]] && result=0 || result=1
assert "dag_get_status m04 unchanged (got: $status_m04)" "$result"

# ===========================================================================
echo "--- Test: frontier after advance includes m03 and m04 ---"

frontier=$(dag_get_frontier)

result=0
echo "$frontier" | grep -qx "m03" && result=0 || result=1
assert "m03 is on frontier after advance (deps now satisfied)" "$result"

result=0
echo "$frontier" | grep -qx "m04" && result=0 || result=1
assert "m04 is on frontier after advance (was already unblocked)" "$result"

result=0
echo "$frontier" | grep -qx "m01" && result=1 || result=0
assert "m01 (done) not on frontier" "$result"

result=0
echo "$frontier" | grep -qx "m02" && result=1 || result=0
assert "m02 (now done) not on frontier" "$result"

# ===========================================================================
echo "--- Test: active is empty after advance ---"

active=$(dag_get_active)

result=0
[[ -z "$active" ]] && result=0 || result=1
assert "active list is empty after advancing m02 to done (got: '$active')" "$result"

# ===========================================================================
echo "--- Test: advance idempotent (done → done) ---"

tekhton dag advance --path "$MANIFEST_PATH" m02 done
rc_idempotent=$?
result=0
[[ "$rc_idempotent" -eq 0 ]] && result=0 || result=1
assert "advance done → done is idempotent (same status no-op)" "$result"

# ===========================================================================
echo "--- Test: invalid transition rejected (done → in_progress) ---"

rc=0
tekhton dag advance --path "$MANIFEST_PATH" m02 in_progress 2>/dev/null && rc=$? || rc=$?
result=0
# exitUsage = 64 per the CLI contract
[[ "$rc" -ne 0 ]] && result=0 || result=1
assert "invalid transition done → in_progress exits non-zero (rc: $rc)" "$result"

result=0
[[ "$rc" -eq 64 ]] && result=0 || result=1
assert "invalid transition exits with code 64 (exitUsage)" "$result"

# ===========================================================================
echo "--- Test: unknown ID rejected ---"

rc=0
tekhton dag advance --path "$MANIFEST_PATH" m99 done 2>/dev/null && rc=$? || rc=$?
result=0
[[ "$rc" -ne 0 ]] && result=0 || result=1
assert "unknown ID exits non-zero (rc: $rc)" "$result"

result=0
# exitNotFound = 1 per the CLI contract
[[ "$rc" -eq 1 ]] && result=0 || result=1
assert "unknown ID exits with code 1 (exitNotFound)" "$result"

# ===========================================================================
echo "--- Test: unknown status rejected ---"

rc=0
tekhton dag advance --path "$MANIFEST_PATH" m03 invalid_status 2>/dev/null && rc=$? || rc=$?
result=0
[[ "$rc" -ne 0 ]] && result=0 || result=1
assert "unknown status exits non-zero (rc: $rc)" "$result"

result=0
[[ "$rc" -eq 64 ]] && result=0 || result=1
assert "unknown status exits with code 64 (exitUsage)" "$result"

# ===========================================================================
echo "--- Test: advance pending → in_progress (transition to active) ---"

tekhton dag advance --path "$MANIFEST_PATH" m03 in_progress
load_manifest "$MANIFEST_PATH"

result=0
status_m03_new=$(dag_get_status m03)
[[ "$status_m03_new" == "in_progress" ]] && result=0 || result=1
assert "dag_get_status m03 == in_progress after second advance (got: $status_m03_new)" "$result"

result=0
active_after=$(dag_get_active)
echo "$active_after" | grep -qx "m03" && result=0 || result=1
assert "m03 appears in active list after advancing to in_progress" "$result"

# ===========================================================================
echo ""
echo "Passed: $PASS  Failed: $FAIL"

[[ "$FAIL" -eq 0 ]]
