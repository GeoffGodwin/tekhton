#!/usr/bin/env bash
# =============================================================================
# test_dashboard_parse_parity.sh — m33.2 contract gate.
#
# Drives `tekhton dashboard parse <kind>` against fixed fixtures and asserts
# the emitted JSON carries the documented shape. m33.1's emit-side parity
# gate (test_dashboard_emit_parity.sh) covers the WRITE path; this gate
# covers the READ path (the StatusReader behind the parse subcommands).
#
# Since the bash parsers are deleted at m33.2, "parity" here means
# "Go output round-trips through proto.* Validate() AND matches the
# documented bash output shape on representative fixtures." The legacy
# bash side is gone, so byte-for-byte gating against a captured bash baseline
# would defeat the wedge cleanup; instead we lock the contract through
# shape assertions on six well-known scenarios.
#
# Scenarios:
#   1. security report  — 4 findings: CRITICAL/HIGH/MEDIUM/LOW + OWASP categories
#   2. intake inline    — Verdict: PASS, Confidence: 82
#   3. intake header    — header-followed-by-value form
#   4. coder summary    — 4 file entries (2 Created + 2 Modified)
#   5. reviewer report  — Verdict: APPROVED_WITH_NOTES
#   6. runs metrics     — JSONL primary path: filters zero-turn, newest-first
#   7. runs files       — RUN_SUMMARY_*.json fallback path
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${TEKHTON_BIN:-${TEKHTON_HOME}/bin/tekhton}"
TESTDATA="${TEKHTON_HOME}/internal/dashboard/testdata/parsers"

if [[ ! -x "$BIN" ]]; then
    echo "SKIP: tekhton binary not built (run 'make build')"
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed — parity gate needs key-sorted comparison"
    exit 0
fi

PASS=0
FAIL=0
FAILED=()

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); FAILED+=("$*"); }

# assert_json_path LABEL JSON JQ_QUERY EXPECTED
assert_json_path() {
    local label="$1" json="$2" query="$3" expected="$4"
    local got
    got=$(printf '%s' "$json" | jq -r "$query" 2>/dev/null || echo "<jq-error>")
    if [[ "$got" == "$expected" ]]; then
        pass "$label"
    else
        fail "$label — expected $expected, got $got"
    fi
}

# Scenario 1: security report — 4 findings + OWASP categories.
scenario_security() {
    echo "=== Scenario 1: security report ==="
    local out
    out=$("$BIN" dashboard parse security "${TESTDATA}/security/golden.md")
    if ! printf '%s' "$out" | jq . >/dev/null 2>&1; then
        fail "scenario1: security output is not valid JSON"
        return
    fi
    # 4 from Findings + 1 from Resolved Findings = 5 findings.
    assert_json_path "scenario1: 5 findings total (incl. Resolved)" "$out" '.findings | length' "5"
    assert_json_path "scenario1: first finding is CRITICAL" "$out" '.findings[0].severity' "CRITICAL"
    assert_json_path "scenario1: first finding category A03" "$out" '.findings[0].category' "A03"
    assert_json_path "scenario1: second finding HIGH/A01" "$out" '.findings[1].severity' "HIGH"
    assert_json_path "scenario1: third finding MEDIUM" "$out" '.findings[2].severity' "MEDIUM"
    assert_json_path "scenario1: fourth finding LOW" "$out" '.findings[3].severity' "LOW"
}

# Scenario 2 + 3: intake — inline + header formats.
scenario_intake_inline() {
    echo "=== Scenario 2: intake inline format ==="
    local out
    out=$("$BIN" dashboard parse intake "${TESTDATA}/intake/inline.md")
    if ! printf '%s' "$out" | jq . >/dev/null 2>&1; then
        fail "scenario2: intake inline output is not valid JSON"
        return
    fi
    assert_json_path "scenario2: verdict=PASS" "$out" '.verdict' "PASS"
    assert_json_path "scenario2: confidence=82" "$out" '.confidence' "82"
    assert_json_path "scenario2: task_text non-empty" "$out" '.task_text | length > 0' "true"
}

scenario_intake_header() {
    echo "=== Scenario 3: intake header format ==="
    local out
    out=$("$BIN" dashboard parse intake "${TESTDATA}/intake/header.md")
    if ! printf '%s' "$out" | jq . >/dev/null 2>&1; then
        fail "scenario3: intake header output is not valid JSON"
        return
    fi
    assert_json_path "scenario3: verdict=NEEDS_WORK" "$out" '.verdict' "NEEDS_WORK"
    assert_json_path "scenario3: confidence=40" "$out" '.confidence' "40"
}

# Scenario 4: coder summary — file count.
scenario_coder() {
    echo "=== Scenario 4: coder summary ==="
    local out
    out=$("$BIN" dashboard parse coder "${TESTDATA}/coder/golden.md")
    if ! printf '%s' "$out" | jq . >/dev/null 2>&1; then
        fail "scenario4: coder output is not valid JSON"
        return
    fi
    assert_json_path "scenario4: status=COMPLETE" "$out" '.status' "COMPLETE"
    assert_json_path "scenario4: files_modified=4" "$out" '.files_modified' "4"
}

# Scenario 5: reviewer report.
scenario_reviewer() {
    echo "=== Scenario 5: reviewer report ==="
    local out
    out=$("$BIN" dashboard parse reviewer "${TESTDATA}/reviewer/golden.md")
    if ! printf '%s' "$out" | jq . >/dev/null 2>&1; then
        fail "scenario5: reviewer output is not valid JSON"
        return
    fi
    assert_json_path "scenario5: verdict=APPROVED_WITH_NOTES" "$out" '.verdict' "APPROVED_WITH_NOTES"
}

# Scenario 6: runs from metrics.jsonl (primary path).
scenario_runs_jsonl() {
    echo "=== Scenario 6: runs from metrics.jsonl ==="
    local out
    out=$("$BIN" dashboard parse runs --metrics "${TESTDATA}/runs/metrics.jsonl" --depth 50)
    if ! printf '%s' "$out" | jq . >/dev/null 2>&1; then
        fail "scenario6: runs output is not valid JSON"
        return
    fi
    # 4 records in fixture, 1 zero-turn → 3 after filter.
    assert_json_path "scenario6: 3 records after zero-turn filter" "$out" 'length' "3"
    # Newest-first ordering: milestone record first.
    assert_json_path "scenario6: newest-first ordering — milestone first" "$out" '.[0].run_type' "milestone"
    assert_json_path "scenario6: bug record second" "$out" '.[1].run_type' "human_bug"
    assert_json_path "scenario6: feature record third" "$out" '.[2].run_type' "human_feat"
    # Bug record has reviewer.cycles populated.
    assert_json_path "scenario6: reviewer.cycles populated" "$out" '.[1].stages.reviewer.cycles' "2"
}

# Scenario 7: runs from RUN_SUMMARY_*.json fallback.
scenario_runs_files() {
    echo "=== Scenario 7: runs from RUN_SUMMARY fallback ==="
    local tmp
    tmp=$(mktemp -d)
    cp "${TESTDATA}/runs/RUN_SUMMARY_20260402_120000.json" "$tmp/"
    cp "${TESTDATA}/runs/RUN_SUMMARY_20260402_130000.json" "$tmp/"
    local out
    # No --metrics → falls back to scanning --summaries dir.
    out=$("$BIN" dashboard parse runs --summaries "$tmp" --depth 50)
    if ! printf '%s' "$out" | jq . >/dev/null 2>&1; then
        fail "scenario7: runs fallback output is not valid JSON"
        rm -rf "$tmp"
        return
    fi
    assert_json_path "scenario7: 2 records from fallback" "$out" 'length' "2"
    # Newest first: 130000 file before 120000 file.
    assert_json_path "scenario7: newest fallback record first" "$out" '.[0].task_label' "Legacy fallback test 2"
    # Total turns mapped from total_agent_calls in the older record.
    assert_json_path "scenario7: total_agent_calls fallback" "$out" '.[1].total_turns' "25"
    # M132 enrichment present on the newer record.
    assert_json_path "scenario7: build_fix_outcome=passed" "$out" '.[0].build_fix_outcome' "passed"
    assert_json_path "scenario7: recovery_route=retry" "$out" '.[0].recovery_route' "retry"
    rm -rf "$tmp"
}

scenario_security
scenario_intake_inline
scenario_intake_header
scenario_coder
scenario_reviewer
scenario_runs_jsonl
scenario_runs_files

echo "========================================"
echo "dashboard_parse_parity: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
fi
exit 0
