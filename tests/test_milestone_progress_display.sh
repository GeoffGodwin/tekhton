#!/usr/bin/env bash
# Test: _render_milestone_progress() — progress bar, status markers, fallbacks
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Stubs for config values
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
TEST_CMD=""
ANALYZE_CMD=""
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "${TMPDIR}/.claude/milestones" "${LOG_DIR}"

MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_DAG_ENABLED=true
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
MILESTONE_AUTO_MIGRATE=true
MILESTONE_ARCHIVE_FILE="${TMPDIR}/MILESTONE_ARCHIVE.md"

export MILESTONE_DAG_ENABLED MILESTONE_DIR MILESTONE_MANIFEST

source "${TEKHTON_HOME}/lib/state.sh"
run_build_gate() { return 0; }
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_query.sh"
source "${TEKHTON_HOME}/lib/milestone_archival_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"
source "${TEKHTON_HOME}/lib/milestone_ops.sh"
source "${TEKHTON_HOME}/lib/milestone_progress_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_progress.sh"

cd "$TMPDIR"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $1"; FAIL=$(( FAIL + 1 )); }

# --- Helper: write manifest ---
write_manifest() {
    local dir="${TMPDIR}/.claude/milestones"
    mkdir -p "$dir"
    cat > "${dir}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
EOF
    cat >> "${dir}/MANIFEST.cfg"
    _DAG_LOADED=false
}

# ── Test 1: Mixed done/pending milestones ────────────────────────────
echo "Test 1: Mixed done/pending milestones"
write_manifest << 'DATA'
m01|User Auth|done||m01-auth.md|
m02|Database Schema|done||m02-db.md|
m03|API Gateway|done||m03-api.md|
m04|Payment Processing|pending|m03|m04-pay.md|
m05|Email Notifications|pending|m04|m05-email.md|
DATA
# Create minimal milestone files
for f in m01-auth.md m02-db.md m03-api.md m04-pay.md m05-email.md; do
    echo "# Milestone" > "${TMPDIR}/.claude/milestones/$f"
done

output=$(_render_milestone_progress 2>/dev/null)
if echo "$output" | grep -q "3 done / 5 total (60%)"; then
    pass "Shows correct progress counts"
else
    fail "Expected '3 done / 5 total (60%)' in output: $output"
fi
if echo "$output" | grep -q "Payment Processing"; then
    pass "Shows next milestone name"
else
    fail "Expected 'Payment Processing' in output: $output"
fi
if echo "$output" | grep -q 'tekhton --milestone'; then
    pass "Shows run command"
else
    fail "Expected run command in output: $output"
fi

# ── Test 2: No manifest → graceful message ───────────────────────────
echo "Test 2: No manifest — graceful message"
rm -f "${TMPDIR}/.claude/milestones/MANIFEST.cfg"
_DAG_LOADED=false
output=$(_render_milestone_progress 2>/dev/null)
if echo "$output" | grep -q "No milestones found"; then
    pass "Graceful 'No milestones found' message"
else
    fail "Expected 'No milestones found': $output"
fi

# ── Test 3: --all flag shows completed milestones ─────────────────────
echo "Test 3: --all flag shows completed milestones"
write_manifest << 'DATA'
m01|User Auth|done||m01-auth.md|
m02|Database Schema|done||m02-db.md|
m03|API Gateway|pending||m03-api.md|
DATA

output=$(_render_milestone_progress --all 2>/dev/null)
if echo "$output" | grep -q "User Auth" && echo "$output" | grep -q "Database Schema"; then
    pass "--all shows completed milestones"
else
    fail "Expected completed milestones with --all: $output"
fi

# ── Test 4: --deps flag shows dependency edges ────────────────────────
echo "Test 4: --deps flag shows dependency edges"
write_manifest << 'DATA'
m01|Foundation|done||m01-auth.md|
m02|Feature A|pending|m01|m02-db.md|
m03|Feature B|pending|m01,m02|m03-api.md|
DATA

output=$(_render_milestone_progress --deps 2>/dev/null)
if echo "$output" | grep -q "depends: m01"; then
    pass "--deps shows dependency info"
else
    fail "Expected 'depends: m01' with --deps: $output"
fi

# ── Test 5: DAG disabled → fallback with note ────────────────────────
echo "Test 5: DAG disabled — fallback note"
MILESTONE_DAG_ENABLED=false
_DAG_LOADED=false
# parse_milestones_auto needs an inline source — but with no CLAUDE.md,
# it will return empty. Verify the "No milestones found" message.
output=$(_render_milestone_progress 2>/dev/null)
if echo "$output" | grep -q "No milestones found\|dependency tracking requires"; then
    pass "DAG disabled shows fallback message"
else
    fail "Expected fallback message when DAG disabled: $output"
fi
MILESTONE_DAG_ENABLED=true

# ── Test 6: All milestones done ──────────────────────────────────────
echo "Test 6: All milestones done"
write_manifest << 'DATA'
m01|Feature One|done||m01-auth.md|
m02|Feature Two|done||m02-db.md|
DATA

output=$(_render_milestone_progress 2>/dev/null)
if echo "$output" | grep -q "All milestones complete"; then
    pass "All-done message shown"
else
    fail "Expected 'All milestones complete': $output"
fi

# ── Test 7: UTF-8 vs ASCII terminal detection ────────────────────────
echo "Test 7: ASCII fallback when no UTF-8"
write_manifest << 'DATA'
m01|Done Item|done||m01-auth.md|
m02|Next Item|pending||m02-db.md|
DATA
old_lang="${LANG:-}"
old_lc_all="${LC_ALL:-}"
LANG="C"
LC_ALL="C"
output=$(_render_milestone_progress 2>/dev/null)
LANG="$old_lang"
LC_ALL="$old_lc_all"
# ASCII mode should use '+' for done items (not UTF-8 ✓/▶).
# Positive assertion: verify the ASCII '+' marker appears in milestone lines.
# (Avoids grep -P which requires PCRE and silently passes when unavailable.)
if echo "$output" | grep -q '  + '; then
    pass "ASCII mode uses fallback symbols"
else
    fail "Expected '  + ' ASCII marker in output: $output"
fi

# ── Results ──────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
exit "$FAIL"
