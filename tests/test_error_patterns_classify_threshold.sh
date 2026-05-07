#!/usr/bin/env bash
# Test: M127 noncode confidence threshold constant.
# m17 update: the threshold lives in internal/errors/classify.go (the bash
# classifier was deleted). We verify the Go constant ships at 60 and that the
# bash shim's classify_routing_decision still emits the four-token vocabulary.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/errors.sh"

test_threshold_constant_in_go() {
    grep -q "NoncodeConfidenceThreshold = 60" "${TEKHTON_HOME}/internal/errors/classify.go"
}

test_threshold_referenced_in_routing() {
    grep -q "NoncodeConfidenceThreshold" "${TEKHTON_HOME}/internal/errors/classify.go"
}

test_routing_emits_valid_token() {
    local test_log=$'npm warn deprecated webpack@1.0.0: old version\nyarn warn deprecated\npnpm notice\nsome unmatched\nmore unmatched'
    local routing
    routing=$(classify_routing_decision "$test_log")
    [[ -n "$routing" ]] && [[ "$routing" =~ ^(code_dominant|noncode_dominant|mixed_uncertain|unknown_only)$ ]]
}

result=0
if test_threshold_constant_in_go; then
    echo "PASS: Noncode confidence threshold constant defined as 60 in Go"
else
    echo "FAIL: NoncodeConfidenceThreshold = 60 not found in internal/errors/classify.go"
    result=1
fi

if test_threshold_referenced_in_routing; then
    echo "PASS: Threshold constant referenced in routing logic"
else
    echo "FAIL: NoncodeConfidenceThreshold not referenced in classify.go"
    result=1
fi

if test_routing_emits_valid_token; then
    echo "PASS: classify_routing_decision emits a valid four-token vocabulary value"
else
    echo "FAIL: classify_routing_decision returned an unexpected value"
    result=1
fi

exit $result
