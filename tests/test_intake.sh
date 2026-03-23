#!/usr/bin/env bash
# test_intake.sh — Unit tests for lib/intake_helpers.sh pure-bash functions
# Tests: content hash skip-on-resume, verdict/confidence parsing from fixtures,
#        threshold normalization on out-of-range inputs, milestone ID derivation
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
export TEKHTON_HOME PROJECT_DIR

# --- Required globals ---
TEKHTON_SESSION_DIR="${TMPDIR_TEST}/session"
mkdir -p "$TEKHTON_SESSION_DIR"
export TEKHTON_SESSION_DIR

MILESTONE_DIR="${TMPDIR_TEST}/milestones"
mkdir -p "$MILESTONE_DIR"
export MILESTONE_DIR

MILESTONE_DAG_ENABLED="false"
MILESTONE_MODE=false
_CURRENT_MILESTONE=""
TASK="test task"
export MILESTONE_DAG_ENABLED MILESTONE_MODE _CURRENT_MILESTONE TASK

# Stub pipeline functions required by intake_helpers.sh
log()     { :; }
warn()    { :; }
error()   { :; }
header()  { :; }
success() { :; }

# Source the file under test
# shellcheck source=../lib/intake_helpers.sh
source "${TEKHTON_HOME}/lib/intake_helpers.sh"

# --- Test helpers ---
PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m $label — expected='$expected', got='$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_empty() {
    local label="$1" actual="$2"
    if [ -z "$actual" ]; then
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m $label — expected empty, got='$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_empty() {
    local label="$1" actual="$2"
    if [ -n "$actual" ]; then
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m $label — expected non-empty, got empty"
        FAIL=$((FAIL + 1))
    fi
}

assert_returns() {
    local label="$1" expected_rc="$2"
    shift 2
    local actual_rc=0
    "$@" || actual_rc=$?
    if [ "$actual_rc" -eq "$expected_rc" ]; then
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m $label — expected rc=$expected_rc, got rc=$actual_rc"
        FAIL=$((FAIL + 1))
    fi
}

# =============================================================================
# _intake_content_hash tests
# =============================================================================

# Test 1: Same content produces same hash
hash1=$(_intake_content_hash "hello world")
hash2=$(_intake_content_hash "hello world")
assert_eq "Same content → same hash" "$hash1" "$hash2"

# Test 2: Different content produces different hash
hash3=$(_intake_content_hash "different content")
if [ "$hash1" != "$hash3" ]; then
    echo -e "\033[0;32mPASS\033[0m Different content → different hash"
    PASS=$((PASS + 1))
else
    echo -e "\033[0;31mFAIL\033[0m Different content → different hash — hashes should differ"
    FAIL=$((FAIL + 1))
fi

# Test 3: Hash is non-empty
assert_not_empty "Hash of non-empty content is non-empty" "$hash1"

# Test 4: Hash of empty string is non-empty (sha256sum always produces output)
hash_empty=$(_intake_content_hash "")
assert_not_empty "Hash of empty string is non-empty" "$hash_empty"

# =============================================================================
# _intake_should_skip / _intake_save_hash tests
# =============================================================================

# Reset session dir
rm -f "${TEKHTON_SESSION_DIR}/intake_content_hash"

# Test 5: Returns 1 (do not skip) when no hash file exists
assert_returns "No hash file → do not skip" 1 _intake_should_skip "abc123"

# Test 6: Returns 1 (do not skip) when hash file contains different hash
echo "different_hash" > "${TEKHTON_SESSION_DIR}/intake_content_hash"
assert_returns "Different hash → do not skip" 1 _intake_should_skip "abc123"

# Test 7: Returns 0 (skip) after saving the same hash
_intake_save_hash "abc123"
assert_returns "Saved hash → skip on resume" 0 _intake_should_skip "abc123"

# Test 8: Returns 1 again after content changes
assert_returns "New content hash → do not skip" 1 _intake_should_skip "xyz789"

# Test 9: Save new hash, then skip
_intake_save_hash "xyz789"
assert_returns "New saved hash → skip" 0 _intake_should_skip "xyz789"

# =============================================================================
# _intake_parse_verdict tests
# =============================================================================

REPORT="${TMPDIR_TEST}/INTAKE_REPORT.md"

# Test 10: Missing report file → PASS
rm -f "$REPORT"
result=$(_intake_parse_verdict "$REPORT")
assert_eq "Missing report → PASS verdict" "PASS" "$result"

# Test 11: PASS verdict
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
PASS

## Confidence
95
EOF
result=$(_intake_parse_verdict "$REPORT")
assert_eq "PASS verdict parsed correctly" "PASS" "$result"

# Test 12: TWEAKED verdict
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
TWEAKED

## Confidence
80
EOF
result=$(_intake_parse_verdict "$REPORT")
assert_eq "TWEAKED verdict parsed correctly" "TWEAKED" "$result"

# Test 13: SPLIT_RECOMMENDED verdict
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
SPLIT_RECOMMENDED

## Confidence
60
EOF
result=$(_intake_parse_verdict "$REPORT")
assert_eq "SPLIT_RECOMMENDED verdict parsed correctly" "SPLIT_RECOMMENDED" "$result"

# Test 14: NEEDS_CLARITY verdict
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
NEEDS_CLARITY

## Confidence
30
EOF
result=$(_intake_parse_verdict "$REPORT")
assert_eq "NEEDS_CLARITY verdict parsed correctly" "NEEDS_CLARITY" "$result"

# Test 15: Lowercase verdict normalised to uppercase
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
tweaked

## Confidence
75
EOF
result=$(_intake_parse_verdict "$REPORT")
assert_eq "Lowercase verdict normalised" "TWEAKED" "$result"

# Test 16: Unknown/invalid verdict → PASS fallback
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
INVALID_VERDICT

## Confidence
50
EOF
result=$(_intake_parse_verdict "$REPORT")
assert_eq "Invalid verdict → PASS fallback" "PASS" "$result"

# Test 17: Empty verdict line → PASS fallback
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict

## Confidence
50
EOF
result=$(_intake_parse_verdict "$REPORT")
assert_eq "Empty verdict line → PASS fallback" "PASS" "$result"

# Test 18: Verdict with leading/trailing spaces normalised
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
  NEEDS_CLARITY

## Confidence
25
EOF
result=$(_intake_parse_verdict "$REPORT")
assert_eq "Verdict with spaces normalised" "NEEDS_CLARITY" "$result"

# =============================================================================
# _intake_parse_confidence tests
# =============================================================================

# Test 19: Missing report file → 100
rm -f "$REPORT"
result=$(_intake_parse_confidence "$REPORT")
assert_eq "Missing report → confidence 100" "100" "$result"

# Test 20: Valid score in range
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
PASS

## Confidence
85
EOF
result=$(_intake_parse_confidence "$REPORT")
assert_eq "Valid confidence score parsed" "85" "$result"

# Test 21: Score 0 is valid
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
NEEDS_CLARITY

## Confidence
0
EOF
result=$(_intake_parse_confidence "$REPORT")
assert_eq "Confidence 0 is valid" "0" "$result"

# Test 22: Score 100 is valid
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
PASS

## Confidence
100
EOF
result=$(_intake_parse_confidence "$REPORT")
assert_eq "Confidence 100 is valid" "100" "$result"

# Test 23: Score > 100 → fallback to 100 (out-of-range normalization)
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
PASS

## Confidence
150
EOF
result=$(_intake_parse_confidence "$REPORT")
assert_eq "Score > 100 → fallback 100" "100" "$result"

# Test 24: Non-numeric confidence → fallback to 100
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
PASS

## Confidence
very_high
EOF
result=$(_intake_parse_confidence "$REPORT")
assert_eq "Non-numeric confidence → fallback 100" "100" "$result"

# Test 25: Empty confidence line → fallback to 100
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
PASS

## Confidence

## Questions
EOF
result=$(_intake_parse_confidence "$REPORT")
assert_eq "Empty confidence line → fallback 100" "100" "$result"

# Test 26: Confidence with percent sign stripped
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
PASS

## Confidence
72%
EOF
result=$(_intake_parse_confidence "$REPORT")
assert_eq "Confidence with % sign parsed" "72" "$result"

# =============================================================================
# _intake_parse_tweaks tests
# =============================================================================

# Test 27: Missing report → empty output
rm -f "$REPORT"
result=$(_intake_parse_tweaks "$REPORT")
assert_empty "Missing report → empty tweaks" "$result"

# Test 28: Extract tweaked content block
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
TWEAKED

## Tweaked Content
Implement user authentication with JWT tokens.
- Add login endpoint
- Add token validation middleware

## Confidence
80
EOF
result=$(_intake_parse_tweaks "$REPORT")
if echo "$result" | grep -q "JWT tokens"; then
    echo -e "\033[0;32mPASS\033[0m Tweaked content block extracted"
    PASS=$((PASS + 1))
else
    echo -e "\033[0;31mFAIL\033[0m Tweaked content block extracted — expected 'JWT tokens' in output"
    FAIL=$((FAIL + 1))
fi

# Test 29: Tweaks stop at next ## section
cat > "$REPORT" << 'EOF'
# Intake Report

## Tweaked Content
Line inside tweaks

## Confidence
80
Line outside tweaks
EOF
result=$(_intake_parse_tweaks "$REPORT")
if echo "$result" | grep -q "Line inside tweaks" && ! echo "$result" | grep -q "Line outside tweaks"; then
    echo -e "\033[0;32mPASS\033[0m Tweaks section stops at next ## header"
    PASS=$((PASS + 1))
else
    echo -e "\033[0;31mFAIL\033[0m Tweaks section stops at next ## header"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
# _intake_parse_questions tests
# =============================================================================

# Test 30: Missing report → empty output
rm -f "$REPORT"
result=$(_intake_parse_questions "$REPORT")
assert_empty "Missing report → empty questions" "$result"

# Test 31: Extract questions block
cat > "$REPORT" << 'EOF'
# Intake Report

## Verdict
NEEDS_CLARITY

## Questions
- What authentication method should be used?
- Should the API support OAuth2?

## Confidence
20
EOF
result=$(_intake_parse_questions "$REPORT")
if echo "$result" | grep -q "authentication method"; then
    echo -e "\033[0;32mPASS\033[0m Questions block extracted"
    PASS=$((PASS + 1))
else
    echo -e "\033[0;31mFAIL\033[0m Questions block extracted — expected question text in output"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
# Milestone ID derivation (run_intake_create logic — isolated)
# =============================================================================
# Test the ID derivation loop directly by calling it in a subshell with a mock.
# This tests the next_id/next_num computation without running the full create flow.

_derive_next_milestone_id() {
    local manifest_file="$1"
    local next_id="m01"
    if [[ -f "$manifest_file" ]]; then
        local max_num=0
        while IFS='|' read -r mid _ _ _ _ _; do
            [[ "$mid" =~ ^# ]] && continue
            [[ -z "$mid" ]] && continue
            local num_part="${mid#m}"
            num_part="${num_part#0}"
            if [[ "$num_part" =~ ^[0-9]+$ ]] && [[ "$num_part" -gt "$max_num" ]]; then
                max_num="$num_part"
            fi
        done < "$manifest_file"
        local next_num=$((max_num + 1))
        next_id=$(printf "m%02d" "$next_num")
    fi
    echo "$next_id"
}

MANIFEST="${TMPDIR_TEST}/MANIFEST.cfg"

# Test 32: No manifest → first ID is m01
rm -f "$MANIFEST"
result=$(_derive_next_milestone_id "$MANIFEST")
assert_eq "No manifest → first ID is m01" "m01" "$result"

# Test 33: Empty manifest (header only) → first ID is m01
cat > "$MANIFEST" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
EOF
result=$(_derive_next_milestone_id "$MANIFEST")
assert_eq "Header-only manifest → first ID is m01" "m01" "$result"

# Test 34: Single entry m01 → next is m02
cat > "$MANIFEST" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First Milestone|pending||m01.md|
EOF
result=$(_derive_next_milestone_id "$MANIFEST")
assert_eq "After m01 → next is m02" "m02" "$result"

# Test 35: Multiple entries → next after max
cat > "$MANIFEST" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First|done||m01.md|
m02|Second|done||m02.md|
m03|Third|pending||m03.md|
EOF
result=$(_derive_next_milestone_id "$MANIFEST")
assert_eq "After m01/m02/m03 → next is m04" "m04" "$result"

# Test 36: Non-sequential entries → next after highest
cat > "$MANIFEST" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First|done||m01.md|
m05|Fifth|pending||m05.md|
m03|Third|done||m03.md|
EOF
result=$(_derive_next_milestone_id "$MANIFEST")
assert_eq "Non-sequential: after m05 (max) → next is m06" "m06" "$result"

# Test 37: IDs with leading zero padding (m09 → m10)
cat > "$MANIFEST" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m09|Ninth|pending||m09.md|
EOF
result=$(_derive_next_milestone_id "$MANIFEST")
assert_eq "After m09 → next is m10" "m10" "$result"

# Test 38: Large ID numbers format correctly (m99 → m100)
cat > "$MANIFEST" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m99|Ninety-ninth|done||m99.md|
EOF
result=$(_derive_next_milestone_id "$MANIFEST")
assert_eq "After m99 → next is m100" "m100" "$result"

# =============================================================================
# Results
# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: $PASS  Failed: $FAIL"
echo "────────────────────────────────────────"

[ "$FAIL" -eq 0 ] || exit 1
