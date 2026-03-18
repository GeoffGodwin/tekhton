#!/usr/bin/env bash
# =============================================================================
# test_lifecycle_drift.sh — P6 End-to-end drift lifecycle test
#
# Simulates the full drift prevention cycle:
#   1. Start with empty DRIFT_LOG.md
#   2. Simulate N pipeline runs appending observations
#   3. Verify threshold triggers at the right count
#   4. Simulate architect audit producing a plan
#   5. Simulate coder remediation (observations addressed)
#   6. Verify observations marked RESOLVED
#   7. Verify runs-since-audit counter resets
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
TEKHTON_SESSION_DIR="$TMPDIR"

# Config — use low thresholds to make the test cycle short
DRIFT_LOG_FILE="DRIFT_LOG.md"
ARCHITECTURE_LOG_FILE="ARCHITECTURE_LOG.md"
HUMAN_ACTION_FILE="HUMAN_ACTION_REQUIRED.md"
DRIFT_OBSERVATION_THRESHOLD=3
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=5
TASK="lifecycle test run"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/drift.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

assert_file_contains() {
    local name="$1" file="$2" pattern="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — pattern '$pattern' not found in $file"
        FAIL=1
    fi
}

assert_file_not_contains() {
    local name="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — unexpected pattern '$pattern' found in $file"
        FAIL=1
    fi
}

drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"

# =============================================================================
# Phase 1: Empty state — no log file, no audit trigger
# =============================================================================
assert_eq "1.1 initial observation count" "0" "$(count_drift_observations)"
assert_eq "1.2 initial runs-since-audit" "0" "$(get_runs_since_audit)"

if should_trigger_audit; then
    echo "FAIL: 1.3 audit should NOT trigger on empty state"
    FAIL=1
fi

# =============================================================================
# Phase 2: Simulate pipeline runs 1-2 — observations accumulate but below threshold
# =============================================================================

# --- Run 1: Reviewer finds 1 drift observation ---
TASK="Run 1: feature X"
cat > "${PROJECT_DIR}/REVIEWER_REPORT.md" << 'EOF'
## Verdict
APPROVED_WITH_NOTES

## Drift Observations
- game_state.dart:22 — unused field `spectralEnabled` should be removed
EOF

append_drift_observations
increment_runs_since_audit

assert_eq "2.1 count after run 1" "1" "$(count_drift_observations)"
assert_eq "2.2 runs after run 1" "1" "$(get_runs_since_audit)"

if should_trigger_audit; then
    echo "FAIL: 2.3 audit should NOT trigger (1 obs, threshold 3)"
    FAIL=1
fi

# --- Run 2: Reviewer finds 1 more observation ---
TASK="Run 2: bug fix Y"
cat > "${PROJECT_DIR}/REVIEWER_REPORT.md" << 'EOF'
## Verdict
APPROVED

## Drift Observations
- config_models.dart:88 — naming drift: `chaosPoolSize` vs config key `chaos_pool_size`
EOF

append_drift_observations
increment_runs_since_audit

assert_eq "2.4 count after run 2" "2" "$(count_drift_observations)"
assert_eq "2.5 runs after run 2" "2" "$(get_runs_since_audit)"

if should_trigger_audit; then
    echo "FAIL: 2.6 audit should NOT trigger (2 obs, threshold 3)"
    FAIL=1
fi

# =============================================================================
# Phase 3: Run 3 — observation threshold reached, audit trigger fires
# =============================================================================
TASK="Run 3: refactor Z"
cat > "${PROJECT_DIR}/REVIEWER_REPORT.md" << 'EOF'
## Verdict
APPROVED_WITH_NOTES

## Drift Observations
- warden_processor.dart:45 — duplicate rank lookup across 3 files
EOF

append_drift_observations
increment_runs_since_audit

assert_eq "3.1 count at threshold" "3" "$(count_drift_observations)"
assert_eq "3.2 runs after run 3" "3" "$(get_runs_since_audit)"

if ! should_trigger_audit; then
    echo "FAIL: 3.3 audit SHOULD trigger (3 obs = threshold)"
    FAIL=1
fi

# Verify all 3 observations are in the log
assert_file_contains "3.4 obs 1 in log" "$drift_file" "spectralEnabled"
assert_file_contains "3.5 obs 2 in log" "$drift_file" "chaosPoolSize"
assert_file_contains "3.6 obs 3 in log" "$drift_file" "duplicate rank lookup"

# Verify task tags are recorded
assert_file_contains "3.7 run 1 task tag" "$drift_file" "Run 1: feature X"
assert_file_contains "3.8 run 2 task tag" "$drift_file" "Run 2: bug fix Y"
assert_file_contains "3.9 run 3 task tag" "$drift_file" "Run 3: refactor Z"

# =============================================================================
# Phase 4: Simulate architect audit — resolve 2 of 3 observations
# =============================================================================

# Architect resolves observations about spectralEnabled and duplicate rank lookup
resolve_drift_observations "spectralEnabled" "duplicate rank lookup"

assert_eq "4.1 unresolved after partial resolve" "1" "$(count_drift_observations)"
assert_file_contains "4.2 resolved spectral" "$drift_file" "RESOLVED.*spectralEnabled"
assert_file_contains "4.3 resolved duplicate" "$drift_file" "RESOLVED.*duplicate rank lookup"

# The naming drift observation should still be unresolved
assert_file_contains "4.4 naming obs still unresolved" "$drift_file" "chaosPoolSize"

# =============================================================================
# Phase 5: Reset runs-since-audit counter (as architect stage does)
# =============================================================================
reset_runs_since_audit

assert_eq "5.1 runs reset to 0" "0" "$(get_runs_since_audit)"
assert_file_not_contains "5.2 last audit updated" "$drift_file" "Last audit: never"

# Audit should no longer trigger (1 obs < threshold 3, 0 runs < threshold 5)
if should_trigger_audit; then
    echo "FAIL: 5.3 audit should NOT trigger after reset (1 obs)"
    FAIL=1
fi

# =============================================================================
# Phase 6: Continue runs — verify counter resumes from 0
# =============================================================================
# Run the counter back up to the runs-since-audit threshold
for i in 1 2 3 4; do
    increment_runs_since_audit
done

assert_eq "6.1 runs at 4" "4" "$(get_runs_since_audit)"

if should_trigger_audit; then
    echo "FAIL: 6.2 audit should NOT trigger (1 obs, 4 runs — both below threshold)"
    FAIL=1
fi

increment_runs_since_audit
assert_eq "6.3 runs at 5" "5" "$(get_runs_since_audit)"

if ! should_trigger_audit; then
    echo "FAIL: 6.4 audit SHOULD trigger (5 runs = threshold, regardless of 1 obs)"
    FAIL=1
fi

# =============================================================================
# Phase 7: Second audit cycle — resolve remaining observation
# =============================================================================
resolve_drift_observations "chaosPoolSize"
reset_runs_since_audit

assert_eq "7.1 all resolved" "0" "$(count_drift_observations)"
assert_eq "7.2 runs reset again" "0" "$(get_runs_since_audit)"
assert_file_contains "7.3 naming resolved" "$drift_file" "RESOLVED.*chaosPoolSize"

if should_trigger_audit; then
    echo "FAIL: 7.4 audit should NOT trigger (0 obs, 0 runs)"
    FAIL=1
fi

# =============================================================================
# Report
# =============================================================================
if [ "$FAIL" -eq 0 ]; then
    echo "Drift lifecycle test passed (all phases)"
    exit 0
else
    echo "Drift lifecycle test FAILED"
    exit 1
fi
