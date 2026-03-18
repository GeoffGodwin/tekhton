#!/usr/bin/env bash
# =============================================================================
# test_report_error.sh — Tests for report_error() in lib/common.sh
#
# Tests:
#   1. ASCII fallback: box uses +, -, | when LANG is not UTF-8
#   2. Unicode path: box uses ╔, ═, ║ when LANG contains UTF-8
#   3. No-recovery-string path: recovery section is omitted
#   4. TRANSIENT label appears when transient=true
#   5. PERMANENT label appears when transient=false
#   6. Category and subcategory appear in output
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

source "${TEKHTON_HOME}/lib/common.sh"

FAIL=0

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo "FAIL: $name — expected to find '$needle' in output"
        FAIL=1
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "FAIL: $name — expected NOT to find '$needle' in output"
        FAIL=1
    fi
}

# =============================================================================
# Phase 1: ASCII fallback (non-UTF-8 LANG)
# =============================================================================

output=$(LANG=C LC_ALL=C report_error "UPSTREAM" "api_500" "true" "HTTP 500 from API" "Retry in a moment." 2>&1)

assert_contains "1.1 ASCII top-left corner"       "+"  "$output"
assert_contains "1.2 ASCII horizontal rule"        "-"  "$output"
assert_contains "1.3 ASCII vertical bar"           "|"  "$output"
assert_not_contains "1.4 no Unicode top-left"      "╔"  "$output"
assert_not_contains "1.5 no Unicode horizontal"    "═"  "$output"
assert_not_contains "1.6 no Unicode vertical"      "║"  "$output"

# =============================================================================
# Phase 2: Unicode path (UTF-8 LANG)
# =============================================================================

output=$(LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 report_error "UPSTREAM" "api_rate_limit" "true" "Rate limit hit" "Wait and retry." 2>&1)

assert_contains "2.1 Unicode top-left corner"      "╔"  "$output"
assert_contains "2.2 Unicode horizontal rule"      "═"  "$output"
assert_contains "2.3 Unicode vertical bar"         "║"  "$output"
assert_not_contains "2.4 no ASCII top-left"        "+"  "$output"

# =============================================================================
# Phase 3: No recovery string — recovery section omitted
# =============================================================================

output=$(LANG=C LC_ALL=C report_error "PIPELINE" "config_error" "false" "Config parse failed" 2>&1)

assert_contains     "3.1 message is present"       "Config parse failed"  "$output"
assert_not_contains "3.2 recovery label absent"    "Recovery:"            "$output"

# =============================================================================
# Phase 4: Transient label
# =============================================================================

output=$(LANG=C LC_ALL=C report_error "UPSTREAM" "api_timeout" "true" "Connection timed out" "Try again." 2>&1)

assert_contains "4.1 TRANSIENT label present"      "TRANSIENT"  "$output"
assert_contains "4.2 safe to retry label"          "safe to retry"  "$output"
assert_not_contains "4.3 PERMANENT absent"         "PERMANENT"  "$output"

# =============================================================================
# Phase 5: Permanent label
# =============================================================================

output=$(LANG=C LC_ALL=C report_error "AGENT_SCOPE" "null_run" "false" "Agent did nothing" "Check prompt." 2>&1)

assert_contains "5.1 PERMANENT label present"      "PERMANENT"  "$output"
assert_not_contains "5.2 TRANSIENT absent"         "TRANSIENT"  "$output"

# =============================================================================
# Phase 6: Category / subcategory in output
# =============================================================================

output=$(LANG=C LC_ALL=C report_error "ENVIRONMENT" "disk_full" "false" "No disk space" "Free disk." 2>&1)

assert_contains "6.1 category in output"           "ENVIRONMENT"  "$output"
assert_contains "6.2 subcategory in output"        "disk_full"    "$output"
assert_contains "6.3 recovery text in output"      "Free disk."   "$output"
assert_contains "6.4 message in output"            "No disk space" "$output"

# =============================================================================
# Done
# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "report_error tests passed"
