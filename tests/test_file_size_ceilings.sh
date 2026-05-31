#!/usr/bin/env bash
set -euo pipefail

# Test: File size ceilings (m17 update — error_patterns*.sh deleted, classifier
# logic ported to internal/errors). Verifies the surviving bash files are under
# their ceilings.

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CEILING=300
ERRORS_CEILING=100   # m17 acceptance: lib/errors.sh ≤ 100 lines.

# m31.1: build + completion gates ported to internal/gates/. The three
# bash files (gates.sh, gates_phases.sh, gates_completion.sh) must NOT
# exist anymore — their reintroduction would mean someone forked the
# canonical Go gate.
for f in "${TEKHTON_HOME}/lib/gates.sh" \
         "${TEKHTON_HOME}/lib/gates_phases.sh" \
         "${TEKHTON_HOME}/lib/gates_completion.sh"; do
    if [[ -f "$f" ]]; then
        echo "FAIL: $f must not exist after m31.1 (ported to internal/gates/)"
        exit 1
    fi
done

errors_lines=$(wc -l < "${TEKHTON_HOME}/lib/errors.sh")
if [[ "$errors_lines" -gt "$ERRORS_CEILING" ]]; then
    echo "FAIL: errors.sh is $errors_lines lines, exceeds m17 ceiling of $ERRORS_CEILING"
    exit 1
fi
echo "errors.sh: $errors_lines lines (under m17 $ERRORS_CEILING ceiling)"

# m17 invariant: lib/error_patterns*.sh and lib/errors_helpers.sh are deleted.
for f in "${TEKHTON_HOME}/lib/error_patterns.sh" \
         "${TEKHTON_HOME}/lib/error_patterns_classify.sh" \
         "${TEKHTON_HOME}/lib/error_patterns_registry.sh" \
         "${TEKHTON_HOME}/lib/error_patterns_remediation.sh" \
         "${TEKHTON_HOME}/lib/errors_helpers.sh"; do
    if [[ -f "$f" ]]; then
        echo "FAIL: $f must not exist after m17 (deleted in error-taxonomy wedge)"
        exit 1
    fi
done

if [[ ! -f "${TEKHTON_HOME}/lib/remediation.sh" ]]; then
    echo "FAIL: lib/remediation.sh should exist (renamed from error_patterns_remediation.sh in m17)"
    exit 1
fi
echo "lib/remediation.sh: $(wc -l < "${TEKHTON_HOME}/lib/remediation.sh") lines"

# Sanity check: lib/remediation.sh remains under the 300-line ceiling.
remediation_lines=$(wc -l < "${TEKHTON_HOME}/lib/remediation.sh")
if [[ "$remediation_lines" -gt "$CEILING" ]]; then
    echo "FAIL: lib/remediation.sh is $remediation_lines lines, exceeds ceiling of $CEILING"
    exit 1
fi

echo "PASS"
exit 0
