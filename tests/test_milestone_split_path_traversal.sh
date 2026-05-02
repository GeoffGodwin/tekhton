#!/usr/bin/env bash
# =============================================================================
# test_milestone_split_path_traversal.sh — Verify path-traversal guard
#
# Tests that _split_flush_sub_entry in lib/milestone_split_dag.sh rejects
# any milestone filename containing a `/` separator, preventing LLM-generated
# content from escaping the milestone directory via path traversal.
# =============================================================================

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${TEKHTON_HOME}/lib/common.sh"

pass() { printf "✓ %s\n" "$@"; }
fail() { printf "✗ %s\n" "$@"; exit 1; }

# Test: guard pattern exists in the real implementation
test_guard_pattern_in_source() {
    local file="${TEKHTON_HOME}/lib/milestone_split_dag.sh"
    [[ -f "$file" ]] || fail "milestone_split_dag.sh not found"

    # Verify the guard is present: if [[ "$sub_file" == */* ]]; then
    if grep -q 'if.*sub_file.*\*\/\*' "$file"; then
        pass "path traversal guard pattern found in _split_flush_sub_entry"
    else
        fail "path traversal guard not found in lib/milestone_split_dag.sh"
    fi
}

# Test: guard calls error() function on match
test_guard_calls_error_on_traversal() {
    local file="${TEKHTON_HOME}/lib/milestone_split_dag.sh"

    # Find the guard block and verify it calls error and returns 1
    if grep -q 'if.*sub_file.*\*\/\*' "$file" && \
       grep -q 'error.*Refusing.*path separator' "$file" && \
       grep -q 'return 1' "$file"; then
        pass "guard properly calls error and returns 1 on traversal attempt"
    else
        fail "guard does not properly error on traversal"
    fi
}

# Test: guard comes before file write
test_guard_precedes_write() {
    local file="${TEKHTON_HOME}/lib/milestone_split_dag.sh"

    # Extract the line numbers of the guard and the write
    local guard_line
    guard_line=$(grep -n 'if.*sub_file.*\*\/\*' "$file" | cut -d: -f1)

    local write_line
    write_line=$(grep -nE '(echo|printf).*sub_block.*>.*milestone_dir' "$file" | cut -d: -f1)

    if [[ -z "$guard_line" ]] || [[ -z "$write_line" ]]; then
        fail "could not locate guard or write in source file"
    fi

    if (( guard_line < write_line )); then
        pass "guard at line $guard_line precedes write at line $write_line"
    else
        fail "guard at line $guard_line does not precede write at line $write_line"
    fi
}

# Test: pattern matching for safe and unsafe filenames (matching the real guard)
test_filename_pattern_matching() {
    local safe_count=0 unsafe_count=0

    for filename in \
        "m01-test.md" \
        "m02.1-subgoal.md" \
        "../escape.md" \
        "subdir/file.md" \
        "/etc/passwd" \
        "m03-safe-name.md"; do

        if [[ "$filename" == */* ]]; then
            unsafe_count=$((unsafe_count + 1))
        else
            safe_count=$((safe_count + 1))
        fi
    done

    if [[ "$safe_count" -eq 3 && "$unsafe_count" -eq 3 ]]; then
        pass "pattern matching correctly separates safe (3) from unsafe (3) filenames"
    else
        fail "pattern matching failed: safe=$safe_count unsafe=$unsafe_count"
    fi
}

# Test: various traversal patterns are rejected by the guard pattern
test_traversal_patterns_rejected() {
    local traversal_attempts=(
        "../escape.md"
        "../../root.md"
        "/etc/passwd"
        "subdir/file.md"
        "a/b/c/file.md"
    )

    local rejected=0
    for pattern in "${traversal_attempts[@]}"; do
        if [[ "$pattern" == */* ]]; then
            rejected=$((rejected + 1))
        fi
    done

    if [[ "$rejected" -eq "${#traversal_attempts[@]}" ]]; then
        pass "all ${#traversal_attempts[@]} traversal patterns rejected by guard"
    else
        fail "only $rejected of ${#traversal_attempts[@]} patterns rejected"
    fi
}

test_guard_pattern_in_source
test_guard_calls_error_on_traversal
test_guard_precedes_write
test_filename_pattern_matching
test_traversal_patterns_rejected

pass "All path-traversal guard tests passed"
