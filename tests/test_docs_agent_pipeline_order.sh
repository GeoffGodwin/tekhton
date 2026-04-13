#!/usr/bin/env bash
# =============================================================================
# test_docs_agent_pipeline_order.sh — Coverage for DOCS_AGENT_ENABLED in both
# pipeline orders (M75 coverage gaps).
#
# Tests:
#   1.  get_pipeline_order: standard + DOCS_AGENT_ENABLED=true inserts docs
#   2.  get_pipeline_order: test_first + DOCS_AGENT_ENABLED=true inserts docs
#   3.  get_pipeline_order: DOCS_AGENT_ENABLED=false leaves test_first unchanged
#   4.  get_stage_count: standard + docs = 5 visible stages
#   5.  get_stage_count: test_first + docs = 6 visible stages
#   6.  get_stage_position: docs at position 3 in standard+docs order
#   7.  get_stage_position: docs at position 4 in test_first+docs order
#   8.  get_stage_position: security shifts right in standard+docs order
#   9.  get_stage_position: security shifts right in test_first+docs order
#  10.  should_run_stage: docs skipped when start_at=security (standard+docs)
#  11.  should_run_stage: docs runs when start_at=coder (standard+docs)
#  12.  should_run_stage: docs runs when start_at empty (standard+docs)
#  13.  should_run_stage: docs skipped when start_at=security (test_first+docs)
#  14.  should_run_stage: docs runs when start_at=coder (test_first+docs)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source minimal common.sh for warn() used by pipeline_order.sh
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/pipeline_order.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    else
        echo "PASS: $name"
    fi
}

assert_true() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — expected exit 0"
        FAIL=1
    fi
}

assert_false() {
    local name="$1"
    shift
    if ! "$@" > /dev/null 2>&1; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — expected non-zero exit"
        FAIL=1
    fi
}

# =============================================================================
# Phase 1: get_pipeline_order with DOCS_AGENT_ENABLED
# =============================================================================

PIPELINE_ORDER="standard"
DOCS_AGENT_ENABLED="true"
assert_eq "1.1 get_pipeline_order: standard+docs inserts docs between coder and security" \
    "scout coder docs security review test_verify" "$(get_pipeline_order)"

PIPELINE_ORDER="test_first"
DOCS_AGENT_ENABLED="true"
assert_eq "1.2 get_pipeline_order: test_first+docs inserts docs between coder and security" \
    "scout test_write coder docs security review test_verify" "$(get_pipeline_order)"

PIPELINE_ORDER="test_first"
DOCS_AGENT_ENABLED="false"
assert_eq "1.3 get_pipeline_order: test_first with docs disabled leaves order unchanged" \
    "scout test_write coder security review test_verify" "$(get_pipeline_order)"

# =============================================================================
# Phase 2: get_stage_count with DOCS_AGENT_ENABLED
# =============================================================================

PIPELINE_ORDER="standard"
DOCS_AGENT_ENABLED="true"
assert_eq "2.1 get_stage_count: standard+docs has 5 visible stages" "5" "$(get_stage_count)"

PIPELINE_ORDER="test_first"
DOCS_AGENT_ENABLED="true"
assert_eq "2.2 get_stage_count: test_first+docs has 6 visible stages" "6" "$(get_stage_count)"

# =============================================================================
# Phase 3: get_stage_position with DOCS_AGENT_ENABLED
# =============================================================================

# standard + docs: scout(1) coder(2) docs(3) security(4) review(5) test_verify(6)
PIPELINE_ORDER="standard"
DOCS_AGENT_ENABLED="true"
assert_eq "3.1 get_stage_position: docs at position 3 in standard+docs" \
    "3" "$(get_stage_position docs)"
assert_eq "3.2 get_stage_position: security shifts to position 4 in standard+docs" \
    "4" "$(get_stage_position security)"
assert_eq "3.3 get_stage_position: coder remains at position 2 in standard+docs" \
    "2" "$(get_stage_position coder)"

# test_first + docs: scout(1) test_write(2) coder(3) docs(4) security(5) review(6) test_verify(7)
PIPELINE_ORDER="test_first"
DOCS_AGENT_ENABLED="true"
assert_eq "3.4 get_stage_position: docs at position 4 in test_first+docs" \
    "4" "$(get_stage_position docs)"
assert_eq "3.5 get_stage_position: security shifts to position 5 in test_first+docs" \
    "5" "$(get_stage_position security)"
assert_eq "3.6 get_stage_position: coder at position 3 in test_first+docs" \
    "3" "$(get_stage_position coder)"

# =============================================================================
# Phase 4: should_run_stage for docs stage (standard order + docs)
# =============================================================================

PIPELINE_ORDER="standard"
DOCS_AGENT_ENABLED="true"

# docs(3) < security(4): start_at=security should skip docs
assert_false "4.1 should_run_stage: docs skipped when start_at=security (standard+docs)" \
    should_run_stage "docs" "security"

# docs(3) >= coder(2): start_at=coder should run docs
assert_true  "4.2 should_run_stage: docs runs when start_at=coder (standard+docs)" \
    should_run_stage "docs" "coder"

# docs(3) >= scout(1): default start_at should run docs
assert_true  "4.3 should_run_stage: docs runs with empty start_at (standard+docs)" \
    should_run_stage "docs" ""

# start_at=review skips docs (docs(3) < review(5))
assert_false "4.4 should_run_stage: docs skipped when start_at=review (standard+docs)" \
    should_run_stage "docs" "review"

# =============================================================================
# Phase 5: should_run_stage for docs stage (test_first order + docs)
# =============================================================================

PIPELINE_ORDER="test_first"
DOCS_AGENT_ENABLED="true"

# docs(4) < security(5): start_at=security should skip docs
assert_false "5.1 should_run_stage: docs skipped when start_at=security (test_first+docs)" \
    should_run_stage "docs" "security"

# docs(4) >= coder(3): start_at=coder should run docs
assert_true  "5.2 should_run_stage: docs runs when start_at=coder (test_first+docs)" \
    should_run_stage "docs" "coder"

# docs(4) >= scout(1): default start_at should run docs
assert_true  "5.3 should_run_stage: docs runs with empty start_at (test_first+docs)" \
    should_run_stage "docs" ""

# start_at=review skips docs (docs(4) < review(6))
assert_false "5.4 should_run_stage: docs skipped when start_at=review (test_first+docs)" \
    should_run_stage "docs" "review"

# =============================================================================
# Done
# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    echo "FAILED: one or more tests failed"
    exit 1
fi
echo "All tests passed!"
exit 0
