#!/usr/bin/env bash
# Test: Coverage gap - malicious sub-milestone title rejection
# Verifies _split_apply_dag rejects sub-milestone titles with path separators
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"

# Create a temp directory for testing
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT </dev/null

# Stub/minimal implementations of functions required by milestone_split_dag.sh
error() {
    echo "ERROR: $*" >&2
    return 1
}

_dag_milestone_dir() {
    echo "$test_dir"
}

dag_number_to_id() {
    printf "m%02d" "$1"
}

save_manifest() {
    # Stub: does nothing
    return 0
}

# Initialize global DAG arrays required by _split_apply_dag
declare -A _DAG_IDX
declare -a _DAG_IDS _DAG_TITLES _DAG_STATUSES _DAG_DEPS _DAG_FILES _DAG_GROUPS
_DAG_IDX[m01]=0
_DAG_IDS=("m01")
_DAG_TITLES=("Parent Milestone")
_DAG_STATUSES=("pending")
_DAG_DEPS=("")
_DAG_FILES=("m01-parent.md")
_DAG_GROUPS=("")

# Source the function under test
source "${TEKHTON_HOME}/lib/milestone_split_dag.sh" 2>/dev/null || true

# m14: split_dag now bundles _split_slugify. Override AFTER sourcing with an
# INTENTIONALLY UNSAFE stub that only lowercases — this exercises the path-
# traversal guard rather than the slug sanitizer.
_split_slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

test_path_separator_in_title() {
    # Create a split output with a malicious title containing path separators
    # (per audit report MEDIUM finding: fixture with ../../etc/passwd)
    local split_output="## Milestone 1.1: ../../etc/passwd

Content of the split milestone."

    # Call _split_apply_dag and expect failure (exit code 1)
    if _split_apply_dag 1 "$split_output" 2>/dev/null; then
        return 1  # Should have failed
    fi
    return 0  # Correctly rejected
}

test_slash_in_title() {
    # Create a split output with forward slash in the title
    local split_output="## Milestone 1.3: /etc/passwd

Content of the split milestone."

    # Call _split_apply_dag and expect failure
    if _split_apply_dag 1 "$split_output" 2>/dev/null; then
        return 1  # Should have failed
    fi
    return 0  # Correctly rejected
}

# Run tests
result=0

if test_path_separator_in_title; then
    echo "PASS: Path traversal attempt with ../../etc/passwd is rejected"
else
    echo "FAIL: Path traversal with ../../etc/passwd was not rejected"
    result=1
fi

if test_slash_in_title; then
    echo "PASS: Path traversal attempt with /etc/passwd is rejected"
else
    echo "FAIL: Path traversal with /etc/passwd was not rejected"
    result=1
fi

exit $result
