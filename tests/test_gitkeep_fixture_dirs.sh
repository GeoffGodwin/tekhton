#!/usr/bin/env bash
# tests/test_gitkeep_fixture_dirs.sh — m25 acceptance: .gitkeep files exist in
# all 16 fixture agent_logs directories and are not gitignored; pipeline.conf
# ANALYZE_CMD contains make lint.
#
# Coverage:
#   A — all 15 internal/diagnose/testdata/fixtures_v3/*/inputs/agent_logs/.gitkeep exist
#   B — tests/fixtures/qwen_local_smoke/.claude/logs/.gitkeep exists
#   C — total count is exactly 16
#   D — git check-ignore exits 1 (non-zero = no output) for agent_logs .gitkeep paths
#   E — .claude/pipeline.conf ANALYZE_CMD line contains "make lint"
set -uo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $1 — $2"; FAIL=$(( FAIL + 1 )); }

# ---------------------------------------------------------------------------
# Test A: all 15 diagnose fixture agent_logs/.gitkeep files exist
# ---------------------------------------------------------------------------
SCENARIOS=(
    build-failure
    build-fix-exhausted
    intake-clarity
    max-turns-coder
    no-state
    preflight-interactive-config
    quota-exhausted
    review-rejection-loop
    rule-emit-format
    security-halt
    success-run
    transient-error
    ui-gate-interactive-reporter
    unknown-fallback
    version-mismatch
)
FIXTURE_BASE="${TEKHTON_HOME}/internal/diagnose/testdata/fixtures_v3"
missing_a=0
for scenario in "${SCENARIOS[@]}"; do
    gk="${FIXTURE_BASE}/${scenario}/inputs/agent_logs/.gitkeep"
    if [[ ! -f "$gk" ]]; then
        echo "  MISSING: $gk"
        missing_a=$(( missing_a + 1 ))
    fi
done
if [[ "$missing_a" -eq 0 ]]; then
    pass "A: all 15 diagnose fixture agent_logs/.gitkeep files exist"
else
    fail "A: all 15 diagnose fixture agent_logs/.gitkeep files exist" \
        "${missing_a} of 15 missing"
fi

# ---------------------------------------------------------------------------
# Test B: qwen_local_smoke logs/.gitkeep exists
# ---------------------------------------------------------------------------
QWEN_GK="${TEKHTON_HOME}/tests/fixtures/qwen_local_smoke/.claude/logs/.gitkeep"
if [[ -f "$QWEN_GK" ]]; then
    pass "B: tests/fixtures/qwen_local_smoke/.claude/logs/.gitkeep exists"
else
    fail "B: tests/fixtures/qwen_local_smoke/.claude/logs/.gitkeep exists" \
        "file not found: ${QWEN_GK}"
fi

# ---------------------------------------------------------------------------
# Test C: total .gitkeep count is 16
# ---------------------------------------------------------------------------
count_c=$(find \
    "${FIXTURE_BASE}"/*/inputs/agent_logs \
    "${TEKHTON_HOME}/tests/fixtures/qwen_local_smoke/.claude/logs" \
    -name .gitkeep 2>/dev/null | wc -l)
if [[ "$count_c" -eq 16 ]]; then
    pass "C: exactly 16 .gitkeep files found (${count_c})"
else
    fail "C: exactly 16 .gitkeep files found" \
        "got ${count_c}, want 16"
fi

# ---------------------------------------------------------------------------
# Test D: git check-ignore exits non-zero (= no files are gitignored)
#         Only meaningful when files actually exist; skip gracefully otherwise.
# ---------------------------------------------------------------------------
SAMPLE_GK="${FIXTURE_BASE}/no-state/inputs/agent_logs/.gitkeep"
if [[ ! -f "$SAMPLE_GK" ]]; then
    fail "D: git check-ignore: .gitkeep files are not gitignored" \
        "prerequisite missing — .gitkeep files do not exist yet (Test A failed)"
else
    cd "$TEKHTON_HOME" || exit 1
    ignored_out=$(git check-ignore \
        "${FIXTURE_BASE}"/*/inputs/agent_logs/.gitkeep \
        "${QWEN_GK}" 2>/dev/null || true)
    if [[ -z "$ignored_out" ]]; then
        pass "D: git check-ignore exits non-zero — no .gitkeep files are gitignored"
    else
        fail "D: git check-ignore exits non-zero — no .gitkeep files are gitignored" \
            "gitignored: ${ignored_out}"
    fi
fi

# ---------------------------------------------------------------------------
# Test E: pipeline.conf ANALYZE_CMD contains "make lint"
# ---------------------------------------------------------------------------
PIPELINE_CONF="${TEKHTON_HOME}/.claude/pipeline.conf"
if grep -q 'make lint' "$PIPELINE_CONF"; then
    pass "E: pipeline.conf ANALYZE_CMD contains 'make lint'"
else
    fail "E: pipeline.conf ANALYZE_CMD contains 'make lint'" \
        "not found in ANALYZE_CMD line of ${PIPELINE_CONF}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: PASS=${PASS} FAIL=${FAIL}"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
