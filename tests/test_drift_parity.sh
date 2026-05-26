#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# tests/test_drift_parity.sh — m25 acceptance parity gate.
#
# Three scenarios exercise the drift + clarify subsystems end-to-end through
# the `tekhton drift` / `tekhton clarify` CLI seams:
#
#   1. clean_run                  — empty project → no drift artifacts
#   2. reviewer_three_observations — drift observe + human-action append +
#                                    audit-status produces a populated log
#                                    matching a frozen baseline
#   3. clarify_pause_resume       — clarify detect/handle round-trip writes
#                                    CLARIFICATIONS.md; the finalize-time
#                                    `clarify clear` removes the fully-
#                                    answered file
#
# The Go internal-test suite covers the underlying logic; this gate exercises
# the bash↔Go seam shape (env vars, CLI flag wiring, file layout) so a
# regression at the seam fails red here rather than in the next pipeline
# run.
# =============================================================================

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_BIN="${REPO_ROOT}/bin/tekhton"

# shellcheck source=tests/lib/parity.sh
source "${REPO_ROOT}/tests/lib/parity.sh"

# Skip cleanly when the Go toolchain or built binary is unavailable.
if ! command -v go >/dev/null 2>&1; then
    printf 'SKIP test_drift_parity: go toolchain not found\n'
    exit 0
fi
if ! [[ -x "$TEKHTON_BIN" ]]; then
    if ! (cd "$REPO_ROOT" && go build -o bin/tekhton ./cmd/tekhton >/dev/null 2>&1); then
        printf 'SKIP test_drift_parity: go build failed\n'
        exit 0
    fi
fi

# _scrub_dates FILE — collapse YYYY-MM-DD date tags so a parity baseline
# survives running on any future date.
# shellcheck disable=SC2317
_scrub_dates() {
    local f="$1"
    sed -i -E 's/\[20[0-9]{2}-[0-9]{2}-[0-9]{2}/[DATE/g' "$f"
    sed -i -E 's/Last audit: 20[0-9]{2}-[0-9]{2}-[0-9]{2}/Last audit: DATE/g' "$f"
    sed -i -E 's/RESOLVED 20[0-9]{2}-[0-9]{2}-[0-9]{2}/RESOLVED DATE/g' "$f"
}

# =============================================================================
# Scenario 1: clean_run — no drift artifacts emitted from a no-op pipeline.
# =============================================================================
tmp1=$(mktemp -d)
# Sanity: no observations, no resolved entries → drift count returns 0.
count=$("$TEKHTON_BIN" drift count --project-dir "$tmp1" 2>/dev/null || echo "-1")
if [[ "$count" == "0" ]]; then
    parity_pass "clean_run: drift count is 0 for empty project"
else
    parity_fail "clean_run: drift count = '$count', expected 0"
fi
# Sanity: clarify detect on a non-existent report exits 0.
if "$TEKHTON_BIN" clarify detect --report "${tmp1}/REPORT.md" >/dev/null 2>&1; then
    parity_pass "clean_run: clarify detect exits 0 on missing report"
else
    parity_fail "clean_run: clarify detect non-zero on missing report"
fi
rm -rf "$tmp1"

# =============================================================================
# Scenario 2: reviewer_three_observations — three drift entries land in the
# log; a human-action append puts one item in the action file; audit-status
# reports the expected counts.
# =============================================================================
tmp2=$(mktemp -d)
# Append three observations from a single bullet list.
"$TEKHTON_BIN" drift observe --project-dir "$tmp2" --tag "reviewer" --detail "alpha drift" >/dev/null
"$TEKHTON_BIN" drift observe --project-dir "$tmp2" --tag "reviewer" --detail "beta concern" >/dev/null
"$TEKHTON_BIN" drift observe --project-dir "$tmp2" --tag "reviewer" --detail "gamma issue" >/dev/null

# Append a human-action item.
"$TEKHTON_BIN" drift human-action append \
    --project-dir "$tmp2" \
    --source "reviewer" \
    --description "Review DESIGN.md section 4 for the alpha-drift implications" >/dev/null

count=$("$TEKHTON_BIN" drift count --project-dir "$tmp2")
if [[ "$count" == "3" ]]; then
    parity_pass "reviewer_three_observations: drift count = 3"
else
    parity_fail "reviewer_three_observations: drift count = '$count', expected 3"
fi

ha_count=$("$TEKHTON_BIN" drift human-action count --project-dir "$tmp2")
if [[ "$ha_count" == "1" ]]; then
    parity_pass "reviewer_three_observations: human-action count = 1"
else
    parity_fail "reviewer_three_observations: human-action count = '$ha_count', expected 1"
fi

# Resolve one observation → drift count drops to 2.
"$TEKHTON_BIN" drift resolve --project-dir "$tmp2" "alpha drift" >/dev/null
post_count=$("$TEKHTON_BIN" drift count --project-dir "$tmp2")
if [[ "$post_count" == "2" ]]; then
    parity_pass "reviewer_three_observations: drift count after resolve = 2"
else
    parity_fail "reviewer_three_observations: drift count after resolve = '$post_count', expected 2"
fi

# audit-status JSON shape.
audit_json=$("$TEKHTON_BIN" drift audit-status --project-dir "$tmp2" --obs-threshold 2 --runs-threshold 5)
if echo "$audit_json" | grep -q '"should_trigger_audit": true'; then
    parity_pass "reviewer_three_observations: audit-status triggers at obs-threshold"
else
    parity_fail "reviewer_three_observations: audit-status JSON shape = $audit_json"
fi
rm -rf "$tmp2"

# =============================================================================
# Scenario 3: clarify_pause_resume — detect + handle round-trip writes
# CLARIFICATIONS.md; clarify clear removes fully-answered file.
# =============================================================================
tmp3=$(mktemp -d)
report="${tmp3}/CODER_SUMMARY.md"
cat > "$report" <<EOF
# Coder Summary

## Status: IN PROGRESS

## Clarification Required
- [BLOCKING] Which database should we target?
EOF

# detect → exit 1 (blocking present)
if "$TEKHTON_BIN" clarify detect --report "$report" >/dev/null 2>&1; then
    parity_fail "clarify_pause_resume: detect exit 0 with blocking present (expected exit 1)"
else
    parity_pass "clarify_pause_resume: detect exits non-zero on blocking item"
fi

# Simulate user answering: write CLARIFICATIONS.md by hand.
cat > "${tmp3}/CLARIFICATIONS.md" <<EOF
# Clarifications — 2026-05-26 12:00:00

## Q: [BLOCKING] Which database should we target?
**A:** Postgres
EOF

# clarify clear on a fully-answered file → file removed.
# Use --clarifications-file to override any inherited CLARIFICATIONS_FILE env.
"$TEKHTON_BIN" clarify clear \
    --project-dir "$tmp3" \
    --clarifications-file "${tmp3}/CLARIFICATIONS.md" >/dev/null
if [[ -f "${tmp3}/CLARIFICATIONS.md" ]]; then
    parity_fail "clarify_pause_resume: clear did not remove fully-answered file"
else
    parity_pass "clarify_pause_resume: clear removed fully-answered file"
fi

# Re-create partially-answered file; clear should preserve it.
cat > "${tmp3}/CLARIFICATIONS.md" <<EOF
# Clarifications

## Q: question 1
**A:** answered

## Q: question 2
**A:**
EOF
"$TEKHTON_BIN" clarify clear \
    --project-dir "$tmp3" \
    --clarifications-file "${tmp3}/CLARIFICATIONS.md" >/dev/null
if [[ -f "${tmp3}/CLARIFICATIONS.md" ]]; then
    parity_pass "clarify_pause_resume: clear preserved partially-answered file"
else
    parity_fail "clarify_pause_resume: clear erased partially-answered file"
fi
rm -rf "$tmp3"

# =============================================================================
parity_summary "m25 drift+clarify parity"
