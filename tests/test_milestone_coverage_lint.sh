#!/usr/bin/env bash
# =============================================================================
# test_milestone_coverage_lint.sh — S4 milestone authoring lints
# (lib/milestone_acceptance_lint.sh): lint_milestone_blocking (high-confidence,
# blocking) + lint_milestone_coverage (advisory per-file).
# =============================================================================
set -u
TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_has()   { if grep -qi -- "$2" <<<"$1"; then pass "$3"; else fail "$3 (got: $1)"; fi; }
assert_no()    { if grep -qi -- "$2" <<<"$1"; then fail "$3 (got: $1)"; else pass "$3"; fi; }
assert_empty() { if [[ -z "$1" ]]; then pass "$2"; else fail "$2 (got: $1)"; fi; }

# shellcheck source=../lib/milestone_acceptance_lint.sh disable=SC1091
source "${TEKHTON_HOME}/lib/milestone_acceptance_lint.sh"
set +e
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# --- Coverage (advisory): uncovered deliverable flagged, covered not --------
cat > "$WORK/uncovered.md" <<'EOF'
# m99 — Test

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/foo/bar.go` | Create | A thing. |
| `tests/run_tests.sh` | Modify | Register the test. |

## Acceptance Criteria

- [ ] `internal/foo/bar.go` defines Bar() returning 0.
- [ ] The build passes with `make build`.
EOF
cov=$(lint_milestone_coverage "$WORK/uncovered.md")
assert_has "$cov" "run_tests.sh' has no verifying" "coverage flags uncovered run_tests.sh"
assert_no  "$cov" "bar.go' has no verifying"       "coverage does not flag covered bar.go"
blk=$(lint_milestone_blocking "$WORK/uncovered.md")
assert_empty "$blk" "uncovered (but specified) milestone is NOT blocking"

# --- Blocking: vague wording ------------------------------------------------
cat > "$WORK/vague.md" <<'EOF'
# m99 — Test

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `x.go` | Create | thing |

## Acceptance Criteria

- [ ] `x.go` works correctly.
EOF
blk=$(lint_milestone_blocking "$WORK/vague.md")
assert_has "$blk" "vague criterion" "blocking flags vague criterion"

# --- Blocking: deliverables but no Acceptance Criteria section ---------------
cat > "$WORK/nosection.md" <<'EOF'
# m99 — Test

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `x.go` | Create | thing |
EOF
blk=$(lint_milestone_blocking "$WORK/nosection.md")
assert_has "$blk" "no '## Acceptance Criteria' section" "blocking flags missing criteria section"

# --- Clean milestone: no blocking findings ----------------------------------
cat > "$WORK/clean.md" <<'EOF'
# m99 — Test

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `x.go` | Create | thing |

## Acceptance Criteria

- [ ] `x.go` defines Thing() returning 0 (table test).
EOF
blk=$(lint_milestone_blocking "$WORK/clean.md")
assert_empty "$blk" "clean milestone has no blocking findings"

echo "────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
[[ "$FAIL" -eq 0 ]]
