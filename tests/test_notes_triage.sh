#!/usr/bin/env bash
# Test: Note triage — heuristic scoring, metadata caching, report output, promotion
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
export PROJECT_DIR="$TEST_TMPDIR"
export TEKHTON_VERSION="3.41.0"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stubs
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { echo "=== $* ==="; }
render_prompt() { echo ""; }

RED="" CYAN="" YELLOW="" NC=""

# Source required libraries
# shellcheck source=../lib/notes_core.sh
source "${TEKHTON_HOME}/lib/notes_core.sh"
# shellcheck source=../lib/notes_single.sh
source "${TEKHTON_HOME}/lib/notes_single.sh"
# shellcheck source=../lib/notes_triage.sh
source "${TEKHTON_HOME}/lib/notes_triage.sh"
# shellcheck source=../lib/notes_triage_flow.sh
source "${TEKHTON_HOME}/lib/notes_triage_flow.sh"
# shellcheck source=../lib/notes_triage_report.sh
source "${TEKHTON_HOME}/lib/notes_triage_report.sh"

# --------------------------------------------------------------------------
echo "Suite 1: Heuristic scoring — scope keywords"
# --------------------------------------------------------------------------

score=$(_triage_heuristic_score "Rewrite the auth system to use OAuth2" "FEAT")
if [[ "$score" -ge 3 ]]; then
    pass "Scope keyword 'rewrite' detected (score=$score)"
else
    fail "Scope keyword 'rewrite' not scored high enough (score=$score, expected >=3)"
fi

score=$(_triage_heuristic_score "Fix button alignment" "POLISH")
if [[ "$score" -le 1 ]]; then
    pass "Simple polish note scored low (score=$score)"
else
    fail "Simple polish note scored too high (score=$score, expected <=1)"
fi

score=$(_triage_heuristic_score "Migrate all services to new API" "FEAT")
if [[ "$score" -ge 5 ]]; then
    pass "'Migrate' + 'all' scores oversized (score=$score)"
else
    fail "'Migrate' + 'all' should score >=5 (score=$score)"
fi

# --------------------------------------------------------------------------
echo "Suite 2: Tag weight adjustment"
# --------------------------------------------------------------------------

score_feat=$(_triage_heuristic_score "Add support for dark mode" "FEAT")
score_bug=$(_triage_heuristic_score "Add support for dark mode" "BUG")
score_polish=$(_triage_heuristic_score "Add support for dark mode" "POLISH")

if [[ "$score_bug" -lt "$score_feat" ]]; then
    pass "BUG tag reduces score (bug=$score_bug < feat=$score_feat)"
else
    fail "BUG tag should reduce score (bug=$score_bug vs feat=$score_feat)"
fi

if [[ "$score_polish" -lt "$score_feat" ]]; then
    pass "POLISH tag reduces score (polish=$score_polish < feat=$score_feat)"
else
    fail "POLISH tag should reduce score (polish=$score_polish vs feat=$score_feat)"
fi

# --------------------------------------------------------------------------
echo "Suite 3: Confidence levels"
# --------------------------------------------------------------------------

_triage_heuristic_score "Rewrite and replace entire system across the codebase" "FEAT" > /dev/null
if [[ "$_TRIAGE_CONFIDENCE" == "high" ]]; then
    pass "High-score note gets high confidence"
else
    fail "Expected high confidence for high score, got $_TRIAGE_CONFIDENCE"
fi

_triage_heuristic_score "Fix typo in readme" "POLISH" > /dev/null
if [[ "$_TRIAGE_CONFIDENCE" == "high" ]]; then
    pass "Low-score note gets high confidence"
else
    fail "Expected high confidence for low score, got $_TRIAGE_CONFIDENCE"
fi

_triage_heuristic_score "Add support for notifications" "FEAT" > /dev/null
if [[ "$_TRIAGE_CONFIDENCE" == "low" ]]; then
    pass "Medium-score note gets low confidence (score triggers escalation)"
else
    fail "Expected low confidence for medium score, got $_TRIAGE_CONFIDENCE"
fi

# --------------------------------------------------------------------------
echo "Suite 4: Length heuristic"
# --------------------------------------------------------------------------

long_text="Implement a comprehensive integration testing framework that covers all API endpoints and includes authentication validation and rate limiting checks with mock services"
score=$(_triage_heuristic_score "$long_text" "FEAT")
# Length > 120 adds +1
if [[ "${#long_text}" -gt 120 ]]; then
    pass "Long text detected (${#long_text} chars > 120)"
else
    fail "Test text should be > 120 chars (was ${#long_text})"
fi

# --------------------------------------------------------------------------
echo "Suite 5: triage_note with metadata caching"
# --------------------------------------------------------------------------

cd "$TEST_TMPDIR"
export _NOTES_FILE="${TEST_TMPDIR}/HUMAN_NOTES.md"

cat > "$_NOTES_FILE" << 'EOF'
# Human Notes

## Bugs
- [ ] [BUG] Fix login on Safari <!-- note:n01 created:2026-03-29 priority:high source:manual -->

## Features
- [ ] [FEAT] Rewrite the entire auth system to use OAuth2 with PKCE flow across all services <!-- note:n02 created:2026-03-29 priority:medium source:manual -->
- [ ] [FEAT] Add dark mode toggle <!-- note:n03 created:2026-03-29 priority:low source:manual -->

## Polish
- [ ] [POLISH] Fix button alignment <!-- note:n04 created:2026-03-29 priority:low source:manual -->
EOF

HUMAN_NOTES_TRIAGE_ENABLED=true

# Triage a clearly-fit BUG note
triage_note "n01"
if [[ "$_TRIAGE_DISPOSITION" == "fit" ]]; then
    pass "BUG note n01 triaged as fit"
else
    fail "BUG note n01 expected fit, got $_TRIAGE_DISPOSITION"
fi

# Triage a clearly-oversized FEAT note
triage_note "n02"
if [[ "$_TRIAGE_DISPOSITION" == "oversized" ]]; then
    pass "Oversized FEAT note n02 triaged as oversized"
else
    fail "Oversized FEAT note n02 expected oversized, got $_TRIAGE_DISPOSITION"
fi

# Verify metadata was persisted
line=$(_find_note_by_id "n02")
if [[ "$line" =~ triage:oversized ]]; then
    pass "Triage metadata persisted for n02"
else
    fail "Triage metadata not found in n02: $line"
fi

if [[ "$line" =~ text_hash: ]]; then
    pass "Text hash persisted for n02"
else
    fail "Text hash not found in n02: $line"
fi

if [[ "$line" =~ triaged: ]]; then
    pass "Triaged date persisted for n02"
else
    fail "Triaged date not found in n02: $line"
fi

# --------------------------------------------------------------------------
echo "Suite 6: Cached triage (re-triage skipped when text unchanged)"
# --------------------------------------------------------------------------

# Manually set triage to 'fit' and hash for n04, then verify re-triage uses cache
_set_note_metadata "n04" "triage" "fit"
_set_note_metadata "n04" "est_turns" "3"
line=$(_find_note_by_id "n04")
current_hash=$(_compute_text_hash "$(extract_note_text "$line")")
_set_note_metadata "n04" "text_hash" "$current_hash"

triage_note "n04"
if [[ "$_TRIAGE_DISPOSITION" == "fit" ]]; then
    pass "Cached triage result used for n04"
else
    fail "Expected cached fit for n04, got $_TRIAGE_DISPOSITION"
fi

# --------------------------------------------------------------------------
echo "Suite 7: Cache invalidation when text changes"
# --------------------------------------------------------------------------

# Modify n04's text (simulate user edit)
sed -i 's/Fix button alignment/Redesign entire button system across all pages/' "$_NOTES_FILE"
triage_note "n04"
# The text changed → hash mismatch → re-triage runs
line=$(_find_note_by_id "n04")
if [[ "$line" =~ triage: ]]; then
    pass "Triage re-ran after text change for n04"
else
    fail "Triage should have re-run for modified n04"
fi

# --------------------------------------------------------------------------
echo "Suite 8: HUMAN_NOTES_TRIAGE_ENABLED=false bypasses triage"
# --------------------------------------------------------------------------

HUMAN_NOTES_TRIAGE_ENABLED=false
_TRIAGE_DISPOSITION=""
triage_note "n01"
if [[ "$_TRIAGE_DISPOSITION" == "fit" ]]; then
    pass "Triage disabled returns fit by default"
else
    fail "Triage disabled should return fit, got $_TRIAGE_DISPOSITION"
fi
HUMAN_NOTES_TRIAGE_ENABLED=true

# --------------------------------------------------------------------------
echo "Suite 9: run_triage_report output"
# --------------------------------------------------------------------------

# Reset HUMAN_NOTES.md for clean report test
cat > "$_NOTES_FILE" << 'EOF'
# Human Notes

## Bugs
- [ ] [BUG] Fix login on Safari <!-- note:n01 created:2026-03-29 priority:high source:manual -->

## Features
- [ ] [FEAT] Rewrite entire auth system <!-- note:n02 created:2026-03-29 priority:medium source:manual -->
- [ ] [FEAT] Add dark mode toggle <!-- note:n03 created:2026-03-29 priority:low source:manual -->

## Polish
- [ ] [POLISH] Fix button alignment <!-- note:n04 created:2026-03-29 priority:low source:manual -->
EOF

report_output=$(run_triage_report 2>&1)
if echo "$report_output" | grep -q "4 notes:"; then
    pass "Triage report shows correct total count"
else
    fail "Triage report should show 4 notes: $report_output"
fi

if echo "$report_output" | grep -q "oversized"; then
    pass "Triage report shows oversized notes"
else
    fail "Triage report should show oversized: $report_output"
fi

# Filtered report
report_output=$(run_triage_report "BUG" 2>&1)
if echo "$report_output" | grep -q "1 notes:"; then
    pass "Filtered triage report shows correct count"
else
    fail "Filtered triage report should show 1 notes: $report_output"
fi

# --------------------------------------------------------------------------
echo "Suite 10: triage_before_claim with fit note"
# --------------------------------------------------------------------------

result=0
triage_before_claim "n01" || result=$?
if [[ "$result" -eq 0 ]]; then
    pass "triage_before_claim returns 0 for fit note"
else
    fail "triage_before_claim should return 0 for fit note (got $result)"
fi

# --------------------------------------------------------------------------
echo "Suite 11: triage_bulk_warn"
# --------------------------------------------------------------------------

warn_output=""
warn() { warn_output="${warn_output}$*"; }

triage_bulk_warn ""
if echo "$warn_output" | grep -q "oversized"; then
    pass "triage_bulk_warn warns about oversized notes"
else
    fail "triage_bulk_warn should warn about oversized notes: $warn_output"
fi
warn() { :; }  # restore stub

# --------------------------------------------------------------------------
echo "Suite 12: promote_note_to_milestone marks note [x]"
# --------------------------------------------------------------------------

# Set up minimal milestone infrastructure
export MILESTONE_DIR="${TEST_TMPDIR}/.claude/milestones"
export MILESTONE_MANIFEST="MANIFEST.cfg"
mkdir -p "$MILESTONE_DIR"
cat > "${MILESTONE_DIR}/MANIFEST.cfg" << 'MEOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Test milestone|done||m01.md|
MEOF

# Stub run_intake_create to simulate milestone creation
run_intake_create() {
    local next_id="m02"
    local ms_file="${MILESTONE_DIR}/${next_id}.md"
    echo "# Milestone $next_id" > "$ms_file"
    echo "${next_id}|Promoted note|pending||${next_id}.md|" >> "${MILESTONE_DIR}/MANIFEST.cfg"
}

promote_note_to_milestone "n03" "Add dark mode toggle"
line=$(_find_note_by_id "n03")
if [[ "$line" =~ \[x\] ]]; then
    pass "Promoted note n03 marked [x]"
else
    fail "Promoted note n03 should be [x]: $line"
fi
if [[ "$line" =~ promoted:m02 ]]; then
    pass "Promoted note has milestone badge"
else
    fail "Promoted note should have promoted:m02: $line"
fi

# --------------------------------------------------------------------------
echo "Suite 13: _compute_text_hash determinism"
# --------------------------------------------------------------------------

hash1=$(_compute_text_hash "hello world")
hash2=$(_compute_text_hash "hello world")
hash3=$(_compute_text_hash "hello world!")
if [[ "$hash1" == "$hash2" ]]; then
    pass "Hash is deterministic"
else
    fail "Same input should produce same hash ($hash1 != $hash2)"
fi
if [[ "$hash1" != "$hash3" ]]; then
    pass "Different input produces different hash"
else
    fail "Different input should produce different hash ($hash1 == $hash3)"
fi

# --------------------------------------------------------------------------
echo "Suite 14: Score floor at zero"
# --------------------------------------------------------------------------

score=$(_triage_heuristic_score "Fix typo" "BUG")
if [[ "$score" -ge 0 ]]; then
    pass "Score floors at 0 (score=$score)"
else
    fail "Score should not go negative (score=$score)"
fi

# --------------------------------------------------------------------------
echo "Suite 15: _prompt_promote_note stdout cleanliness (confirm-mode path)"
# --------------------------------------------------------------------------
# Regression: display lines must go to stderr; only the single-char choice
# reaches stdout so that choice=$(...) captures a clean value.
# In non-interactive mode (stdin is /dev/null) the function defaults to "k".

choice=$(_prompt_promote_note "n01" "Rewrite the entire system" "25" 2>/dev/null)
if [[ "$choice" == "k" ]]; then
    pass "_prompt_promote_note non-interactive returns clean 'k' via command substitution"
else
    fail "_prompt_promote_note output contaminated: '${choice}'"
fi

# Verify output is exactly one line (no embedded display text from stdout)
line_count=$(printf '%s' "$choice" | wc -l | tr -d ' ')
if [[ "$line_count" -eq 0 ]]; then
    pass "_prompt_promote_note output is single token (no newline-separated display lines)"
else
    fail "_prompt_promote_note output has $line_count trailing newlines (expected 0, got: '${choice}')"
fi

# --------------------------------------------------------------------------
echo "Suite 16: Cache short-circuit actually fires"
# --------------------------------------------------------------------------
# Suite 6 was insufficient: n04 ('Fix button alignment') scores 'fit' via
# heuristics anyway, so triage_note would return 'fit' even without the cache.
# This suite uses a note that heuristically scores OVERSIZED, pre-caches it as
# 'fit', and verifies the cache value wins.

cat > "$_NOTES_FILE" << 'EOF'
# Human Notes

## Features
- [ ] [FEAT] Rewrite and replace entire authentication system <!-- note:n10 created:2026-03-30 priority:high source:manual -->
EOF

# Confirm heuristic alone scores it oversized
line=$(_find_note_by_id "n10")
text=$(extract_note_text "$line")
score=$(_triage_heuristic_score "$text" "FEAT")
if [[ "$score" -ge 5 ]]; then
    pass "Baseline: n10 heuristic scores oversized (score=$score) — cache test is meaningful"
else
    fail "Test setup: n10 should score >=5 heuristically (got $score); test cannot prove cache"
fi

# Pre-cache as 'fit' with matching hash
current_hash=$(_compute_text_hash "$text")
_set_note_metadata "n10" "triage" "fit"
_set_note_metadata "n10" "text_hash" "$current_hash"

# triage_note must use cache and return 'fit', NOT the heuristic result
triage_note "n10"
if [[ "$_TRIAGE_DISPOSITION" == "fit" ]]; then
    pass "Cache short-circuit: cached 'fit' returned despite heuristic scoring oversized"
else
    fail "Cache short-circuit failed: expected 'fit' (cached), got '$_TRIAGE_DISPOSITION'"
fi

# --------------------------------------------------------------------------
echo "Suite 17: triage_bulk_warn with tag filter"
# --------------------------------------------------------------------------
# Coverage gap: the BUG filter branch at line 460 was uncovered.
# Part A: oversized FEAT note is silenced when filter=BUG.
# Part B: oversized BUG note IS warned when filter=BUG.

# Part A — oversized FEAT excluded by BUG filter
cat > "$_NOTES_FILE" << 'EOF'
# Human Notes

## Bugs
- [ ] [BUG] Fix login button color <!-- note:n11 created:2026-03-30 priority:low source:manual -->

## Features
- [ ] [FEAT] Rewrite entire auth system with OAuth2 across all services <!-- note:n12 created:2026-03-30 priority:high source:manual -->
EOF

warn_output_a=""
warn() { warn_output_a="${warn_output_a}$*"; }

triage_bulk_warn "BUG"

if echo "$warn_output_a" | grep -q "n12"; then
    fail "triage_bulk_warn BUG filter should not warn about FEAT note n12: $warn_output_a"
else
    pass "triage_bulk_warn BUG filter excludes oversized FEAT note"
fi
warn() { :; }

# Part B — oversized BUG note IS caught by BUG filter
cat > "$_NOTES_FILE" << 'EOF'
# Human Notes

## Bugs
- [ ] [BUG] Rewrite and replace entire authentication system across all services <!-- note:n13 created:2026-03-30 priority:high source:manual -->
EOF

warn_output_b=""
warn() { warn_output_b="${warn_output_b}$*"; }

triage_bulk_warn "BUG"

if echo "$warn_output_b" | grep -q "oversized"; then
    pass "triage_bulk_warn BUG filter warns about oversized BUG note"
else
    fail "triage_bulk_warn BUG filter should warn about oversized BUG note: $warn_output_b"
fi
warn() { :; }

# ==========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
