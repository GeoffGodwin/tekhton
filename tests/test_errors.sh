#!/usr/bin/env bash
# =============================================================================
# test_errors.sh — Unit tests for lib/errors.sh and lib/errors_helpers.sh
#
# Tests:
#   classify_error: all acceptance-criteria cases plus edge cases
#   is_transient:   all category/subcategory combinations
#   suggest_recovery: all known subcategories return non-empty actionable text
#   redact_sensitive: key stripping, request-ID preservation, stdin/arg modes
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Source dependencies
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/errors.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

check_field() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass
    else
        fail "${label}: expected '${expected}', got '${actual}'"
    fi
}

# Helper: write content to a temp file and return the path
tmpfile() {
    local content="$1"
    local f
    f=$(mktemp "${TMPDIR_TEST}/input.XXXXXX")
    printf '%s' "$content" > "$f"
    echo "$f"
}

# Helper: split CATEGORY|SUBCATEGORY|TRANSIENT|MESSAGE record into parts
get_field() {
    local record="$1" idx="$2"
    echo "$record" | cut -d'|' -f"$idx"
}

# =============================================================================
# classify_error — acceptance criteria cases
# =============================================================================

echo "=== classify_error: acceptance criteria ==="

# AC1: exit 1 + server_error in output → UPSTREAM|api_500|true
output_file=$(tmpfile '{"type":"error","error":{"type":"server_error","message":"internal server error"}}')
record=$(classify_error 1 "" "$output_file" 0 0)
check_field "AC1 category"    "UPSTREAM"  "$(get_field "$record" 1)"
check_field "AC1 subcategory" "api_500"   "$(get_field "$record" 2)"
check_field "AC1 transient"   "true"      "$(get_field "$record" 3)"

# AC2: exit 137 + no API errors → ENVIRONMENT|oom|true
record=$(classify_error 137 "" "" 0 0)
check_field "AC2 category"    "ENVIRONMENT" "$(get_field "$record" 1)"
check_field "AC2 subcategory" "oom"         "$(get_field "$record" 2)"
check_field "AC2 transient"   "true"        "$(get_field "$record" 3)"

# AC3: exit 0 + turns=0 + file_changes=0 → AGENT_SCOPE|null_run|false
record=$(classify_error 0 "" "" 0 0)
check_field "AC3 category"    "AGENT_SCOPE" "$(get_field "$record" 1)"
check_field "AC3 subcategory" "null_run"    "$(get_field "$record" 2)"
check_field "AC3 transient"   "false"       "$(get_field "$record" 3)"

# =============================================================================
# classify_error — UPSTREAM subcategories
# =============================================================================

echo "=== classify_error: UPSTREAM variants ==="

# Rate limit via rate_limit pattern
output_file=$(tmpfile '{"type":"error","error":{"type":"rate_limit_error","message":"too many requests"}}')
record=$(classify_error 1 "" "$output_file" 0 0)
check_field "rate_limit category"    "UPSTREAM"        "$(get_field "$record" 1)"
check_field "rate_limit subcategory" "api_rate_limit"  "$(get_field "$record" 2)"
check_field "rate_limit transient"   "true"            "$(get_field "$record" 3)"

# Rate limit via HTTP status 429
output_file=$(tmpfile '{"status":429,"error":"rate limited"}')
record=$(classify_error 1 "" "$output_file" 0 0)
check_field "429 category"    "UPSTREAM"       "$(get_field "$record" 1)"
check_field "429 subcategory" "api_rate_limit" "$(get_field "$record" 2)"

# Overloaded via overloaded pattern
output_file=$(tmpfile '{"type":"error","error":{"type":"overloaded_error","message":"API overloaded"}}')
record=$(classify_error 1 "" "$output_file" 0 0)
check_field "overloaded category"    "UPSTREAM"       "$(get_field "$record" 1)"
check_field "overloaded subcategory" "api_overloaded" "$(get_field "$record" 2)"
check_field "overloaded transient"   "true"           "$(get_field "$record" 3)"

# Overloaded via HTTP status 529
output_file=$(tmpfile '{"status":529}')
record=$(classify_error 1 "" "$output_file" 0 0)
check_field "529 subcategory" "api_overloaded" "$(get_field "$record" 2)"

# Authentication error via authentication_error pattern
output_file=$(tmpfile '{"type":"error","error":{"type":"authentication_error","message":"invalid api key"}}')
record=$(classify_error 1 "" "$output_file" 0 0)
check_field "auth category"    "UPSTREAM"  "$(get_field "$record" 1)"
check_field "auth subcategory" "api_auth"  "$(get_field "$record" 2)"
check_field "auth transient"   "false"     "$(get_field "$record" 3)"

# Authentication error via invalid.api.key pattern
output_file=$(tmpfile 'Error: invalid api key provided')
record=$(classify_error 1 "" "$output_file" 0 0)
check_field "invalid api key subcategory" "api_auth" "$(get_field "$record" 2)"

# Connection timeout
output_file=$(tmpfile 'connection timed out after 30 seconds')
record=$(classify_error 1 "" "$output_file" 0 0)
check_field "timeout category"    "UPSTREAM"    "$(get_field "$record" 1)"
check_field "timeout subcategory" "api_timeout" "$(get_field "$record" 2)"
check_field "timeout transient"   "true"        "$(get_field "$record" 3)"

# ETIMEDOUT pattern
stderr_file=$(tmpfile 'ETIMEDOUT: connection failed')
record=$(classify_error 1 "$stderr_file" "" 0 0)
check_field "ETIMEDOUT subcategory" "api_timeout" "$(get_field "$record" 2)"

# HTTP 502 server error
output_file=$(tmpfile '{"status":502}')
record=$(classify_error 1 "" "$output_file" 0 0)
check_field "502 category"    "UPSTREAM" "$(get_field "$record" 1)"
check_field "502 subcategory" "api_500"  "$(get_field "$record" 2)"

# Generic API error (type:error + error:{) → api_unknown
output_file=$(tmpfile '{"type":"error","error":{"message":"something weird"}}')
record=$(classify_error 1 "" "$output_file" 0 0)
check_field "api_unknown category"    "UPSTREAM"    "$(get_field "$record" 1)"
check_field "api_unknown subcategory" "api_unknown" "$(get_field "$record" 2)"
check_field "api_unknown transient"   "true"        "$(get_field "$record" 3)"

# =============================================================================
# classify_error — ENVIRONMENT subcategories
# =============================================================================

echo "=== classify_error: ENVIRONMENT variants ==="

# OOM via exit 9
record=$(classify_error 9 "" "" 0 0)
check_field "exit9 category"    "ENVIRONMENT" "$(get_field "$record" 1)"
check_field "exit9 subcategory" "oom"         "$(get_field "$record" 2)"
check_field "exit9 transient"   "true"        "$(get_field "$record" 3)"

# Disk full
output_file=$(tmpfile 'write: No space left on device')
record=$(classify_error 1 "" "$output_file" 0 0)
check_field "disk_full category"    "ENVIRONMENT" "$(get_field "$record" 1)"
check_field "disk_full subcategory" "disk_full"   "$(get_field "$record" 2)"
check_field "disk_full transient"   "false"       "$(get_field "$record" 3)"

# Disk full via ENOSPC
stderr_file=$(tmpfile 'ENOSPC: no space')
record=$(classify_error 1 "$stderr_file" "" 0 0)
check_field "ENOSPC subcategory" "disk_full" "$(get_field "$record" 2)"

# Network — ENOTFOUND
stderr_file=$(tmpfile 'ENOTFOUND: host not found')
record=$(classify_error 1 "$stderr_file" "" 0 0)
check_field "ENOTFOUND category"    "ENVIRONMENT" "$(get_field "$record" 1)"
check_field "ENOTFOUND subcategory" "network"     "$(get_field "$record" 2)"
check_field "ENOTFOUND transient"   "true"        "$(get_field "$record" 3)"

# Network — DNS resolution failed
stderr_file=$(tmpfile 'getaddrinfo: DNS resolution failed')
record=$(classify_error 1 "$stderr_file" "" 0 0)
check_field "DNS resolution subcategory" "network" "$(get_field "$record" 2)"

# Missing dependency
stderr_file=$(tmpfile 'bash: claude: command not found')
record=$(classify_error 127 "$stderr_file" "" 0 0)
check_field "missing_dep category"    "ENVIRONMENT" "$(get_field "$record" 1)"
check_field "missing_dep subcategory" "missing_dep" "$(get_field "$record" 2)"
check_field "missing_dep transient"   "false"       "$(get_field "$record" 3)"

# Permission denied
stderr_file=$(tmpfile 'open /etc/shadow: Permission denied')
record=$(classify_error 1 "$stderr_file" "" 0 0)
check_field "permissions category"    "ENVIRONMENT"  "$(get_field "$record" 1)"
check_field "permissions subcategory" "permissions"  "$(get_field "$record" 2)"
check_field "permissions transient"   "false"        "$(get_field "$record" 3)"

# =============================================================================
# classify_error — AGENT_SCOPE subcategories
# =============================================================================

echo "=== classify_error: AGENT_SCOPE variants ==="

# Activity timeout with output — exit 124, turns > 0 → activity_timeout
record=$(classify_error 124 "" "" 3 7)
check_field "activity_timeout category"    "AGENT_SCOPE"      "$(get_field "$record" 1)"
check_field "activity_timeout subcategory" "activity_timeout" "$(get_field "$record" 2)"
check_field "activity_timeout transient"   "false"            "$(get_field "$record" 3)"

# Null activity timeout — exit 124, turns == 0 → null_activity_timeout
# (agent never produced any output before activity timer fired — likely
# upstream quota/auth, not a stuck agent)
record=$(classify_error 124 "" "" 0 0)
check_field "null_activity_timeout category"    "AGENT_SCOPE"            "$(get_field "$record" 1)"
check_field "null_activity_timeout subcategory" "null_activity_timeout"  "$(get_field "$record" 2)"
check_field "null_activity_timeout transient"   "false"                  "$(get_field "$record" 3)"

# Null activity timeout — stray file_changes don't suppress the classification
# because they may be sidecar/TUI artifacts, not agent output
record=$(classify_error 124 "" "" 14 0)
check_field "null_activity_timeout (with stray files) subcategory" "null_activity_timeout" "$(get_field "$record" 2)"

# Null run — exit 1 + turns=1 (<=2) + no file changes
record=$(classify_error 1 "" "" 0 1)
check_field "null_run exit1 category"    "AGENT_SCOPE" "$(get_field "$record" 1)"
check_field "null_run exit1 subcategory" "null_run"    "$(get_field "$record" 2)"
check_field "null_run exit1 transient"   "false"       "$(get_field "$record" 3)"

# Max turns — exit 1 + turns > 2 (non-zero exit means interrupted)
record=$(classify_error 1 "" "" 5 25)
check_field "max_turns category"    "AGENT_SCOPE" "$(get_field "$record" 1)"
check_field "max_turns subcategory" "max_turns"   "$(get_field "$record" 2)"
check_field "max_turns transient"   "false"       "$(get_field "$record" 3)"

# no_summary — exit 0 + turns > 0 + has_summary = 0
record=$(classify_error 0 "" "" 0 10 0)
check_field "no_summary category"    "AGENT_SCOPE" "$(get_field "$record" 1)"
check_field "no_summary subcategory" "no_summary"  "$(get_field "$record" 2)"
check_field "no_summary transient"   "false"       "$(get_field "$record" 3)"

# no_summary — exit 0 + turns > 0 + file_changes > 0 but no summary file
record=$(classify_error 0 "" "" 5 10 0)
check_field "no_summary with files category"    "AGENT_SCOPE" "$(get_field "$record" 1)"
check_field "no_summary with files subcategory" "no_summary"  "$(get_field "$record" 2)"

# has_summary = 1 bypasses no_summary — exit 0 + turns > 0 + has_summary = 1
record=$(classify_error 0 "" "" 0 10 1)
check_field "has_summary bypass category"    "AGENT_SCOPE"    "$(get_field "$record" 1)"
check_field "has_summary bypass subcategory" "scope_unknown"  "$(get_field "$record" 2)"

# =============================================================================
# classify_error — PIPELINE fallback
# =============================================================================

echo "=== classify_error: PIPELINE variants ==="

# Generic unrecognized non-zero exit → PIPELINE|internal
# file_changes=1 bypasses the null_run check (turns<=2 && files==0 condition)
record=$(classify_error 42 "" "" 1 0)
check_field "internal category"    "PIPELINE"  "$(get_field "$record" 1)"
check_field "internal subcategory" "internal"  "$(get_field "$record" 2)"
check_field "internal transient"   "false"     "$(get_field "$record" 3)"

# SIGSEGV (exit 139) → ENVIRONMENT|env_unknown
# file_changes=1 bypasses null_run check so we reach the SIGSEGV fallback
record=$(classify_error 139 "" "" 1 0)
check_field "sigsegv category"    "ENVIRONMENT" "$(get_field "$record" 1)"
check_field "sigsegv subcategory" "env_unknown" "$(get_field "$record" 2)"

# Template error
stderr_file=$(tmpfile 'render_prompt: template not found')
record=$(classify_error 1 "$stderr_file" "" 0 0)
check_field "template_error category"    "PIPELINE"       "$(get_field "$record" 1)"
check_field "template_error subcategory" "template_error" "$(get_field "$record" 2)"

# State corrupt
stderr_file=$(tmpfile 'PIPELINE_STATE file is corrupt or invalid')
record=$(classify_error 1 "$stderr_file" "" 0 0)
check_field "state_corrupt category"    "PIPELINE"       "$(get_field "$record" 1)"
check_field "state_corrupt subcategory" "state_corrupt"  "$(get_field "$record" 2)"

# Config error
stderr_file=$(tmpfile 'pipeline.conf: missing required field PROJECT_NAME')
record=$(classify_error 1 "$stderr_file" "" 0 0)
check_field "config_error category"    "PIPELINE"      "$(get_field "$record" 1)"
check_field "config_error subcategory" "config_error"  "$(get_field "$record" 2)"

# =============================================================================
# classify_error — optional parameter defaults
# =============================================================================

echo "=== classify_error: optional parameter defaults ==="

# Called with only exit_code (4 optional params default to 0/"")
# Should not error, and exit 0 with no params → scope_unknown
record=$(classify_error 0)
cat_val=$(get_field "$record" 1)
sub_val=$(get_field "$record" 2)
if [[ -n "$cat_val" ]] && [[ -n "$sub_val" ]]; then
    pass
else
    fail "classify_error with only exit_code produced empty category or subcategory: '$record'"
fi

# Non-numeric file_changes/turns should default to 0
record=$(classify_error 0 "" "" "abc" "xyz")
check_field "non-numeric params category" "AGENT_SCOPE" "$(get_field "$record" 1)"

# =============================================================================
# is_transient — transient cases (return 0)
# =============================================================================

echo "=== is_transient: transient cases ==="

transient_cases=(
    "UPSTREAM api_500"
    "UPSTREAM api_rate_limit"
    "UPSTREAM api_overloaded"
    "UPSTREAM api_timeout"
    "UPSTREAM api_unknown"
    "ENVIRONMENT network"
    "ENVIRONMENT oom"
)

for case_str in "${transient_cases[@]}"; do
    cat_val="${case_str%% *}"
    sub_val="${case_str##* }"
    if is_transient "$cat_val" "$sub_val"; then
        pass
    else
        fail "is_transient ${cat_val}/${sub_val} should return 0 (transient) but returned 1"
    fi
done

# =============================================================================
# is_transient — permanent cases (return 1)
# =============================================================================

echo "=== is_transient: permanent cases ==="

permanent_cases=(
    "UPSTREAM api_auth"
    "ENVIRONMENT disk_full"
    "ENVIRONMENT missing_dep"
    "ENVIRONMENT permissions"
    "ENVIRONMENT env_unknown"
    "AGENT_SCOPE null_run"
    "AGENT_SCOPE max_turns"
    "AGENT_SCOPE activity_timeout"
    "AGENT_SCOPE null_activity_timeout"
    "AGENT_SCOPE no_summary"
    "AGENT_SCOPE scope_unknown"
    "PIPELINE state_corrupt"
    "PIPELINE config_error"
    "PIPELINE missing_file"
    "PIPELINE template_error"
    "PIPELINE internal"
)

for case_str in "${permanent_cases[@]}"; do
    cat_val="${case_str%% *}"
    sub_val="${case_str##* }"
    if ! is_transient "$cat_val" "$sub_val"; then
        pass
    else
        fail "is_transient ${cat_val}/${sub_val} should return 1 (permanent) but returned 0"
    fi
done

# Unknown category defaults to permanent
if ! is_transient "UNKNOWN" "whatever"; then
    pass
else
    fail "is_transient UNKNOWN/whatever should return 1 (permanent)"
fi

# =============================================================================
# suggest_recovery — all known subcategories return non-empty text
# =============================================================================

echo "=== suggest_recovery: all known subcategories ==="

all_cases=(
    "UPSTREAM api_500"
    "UPSTREAM api_rate_limit"
    "UPSTREAM api_overloaded"
    "UPSTREAM api_auth"
    "UPSTREAM api_timeout"
    "UPSTREAM api_unknown"
    "ENVIRONMENT disk_full"
    "ENVIRONMENT network"
    "ENVIRONMENT missing_dep"
    "ENVIRONMENT permissions"
    "ENVIRONMENT oom"
    "ENVIRONMENT env_unknown"
    "AGENT_SCOPE null_run"
    "AGENT_SCOPE max_turns"
    "AGENT_SCOPE activity_timeout"
    "AGENT_SCOPE null_activity_timeout"
    "AGENT_SCOPE no_summary"
    "AGENT_SCOPE scope_unknown"
    "PIPELINE state_corrupt"
    "PIPELINE config_error"
    "PIPELINE missing_file"
    "PIPELINE template_error"
    "PIPELINE internal"
)

for case_str in "${all_cases[@]}"; do
    cat_val="${case_str%% *}"
    sub_val="${case_str##* }"
    recovery=$(suggest_recovery "$cat_val" "$sub_val")
    if [[ -n "$recovery" ]]; then
        pass
    else
        fail "suggest_recovery ${cat_val}/${sub_val} returned empty string"
    fi
done

# Unknown subcategory returns fallback text
recovery=$(suggest_recovery "UPSTREAM" "totally_unknown_subcategory")
if [[ -n "$recovery" ]]; then
    pass
else
    fail "suggest_recovery unknown subcategory returned empty string"
fi

# Context parameter used in PIPELINE/state_corrupt
recovery=$(suggest_recovery "PIPELINE" "state_corrupt" "/tmp/mystate.md")
if echo "$recovery" | grep -q "mystate"; then
    pass
else
    fail "suggest_recovery PIPELINE/state_corrupt did not include context path: '$recovery'"
fi

# =============================================================================
# redact_sensitive — key stripping
# =============================================================================

echo "=== redact_sensitive: key stripping ==="

# sk-ant-* key stripped
input='Calling API with sk-ant-api03-SuperSecretKey123 as credential'
result=$(redact_sensitive "$input")
if echo "$result" | grep -q "sk-ant-api03-SuperSecretKey123"; then
    fail "redact_sensitive did not strip sk-ant-* key"
else
    pass
fi
if echo "$result" | grep -q "REDACTED"; then
    pass
else
    fail "redact_sensitive sk-ant-* strip: REDACTED marker missing"
fi

# x-api-key header stripped
input='x-api-key: sk-ant-mysecretkey'
result=$(redact_sensitive "$input")
if echo "$result" | grep -qi "x-api-key: \[REDACTED\]"; then
    pass
else
    fail "redact_sensitive x-api-key not redacted: '$result'"
fi
if echo "$result" | grep -q "mysecretkey"; then
    fail "redact_sensitive x-api-key: raw key still present"
else
    pass
fi

# Authorization header stripped
input='Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.secret'
result=$(redact_sensitive "$input")
if echo "$result" | grep -qi "Authorization: \[REDACTED\]"; then
    pass
else
    fail "redact_sensitive Authorization not redacted: '$result'"
fi
if echo "$result" | grep -q "eyJhbGciOiJSUzI1NiJ9"; then
    fail "redact_sensitive Authorization: raw token still present"
else
    pass
fi

# ANTHROPIC_API_KEY= stripped
input='export ANTHROPIC_API_KEY=sk-ant-toplevel-secret'
result=$(redact_sensitive "$input")
if echo "$result" | grep -q "sk-ant-toplevel-secret"; then
    fail "redact_sensitive ANTHROPIC_API_KEY: raw key still present"
else
    pass
fi
if echo "$result" | grep -q "ANTHROPIC_API_KEY=\[REDACTED\]"; then
    pass
else
    fail "redact_sensitive ANTHROPIC_API_KEY not redacted: '$result'"
fi

# Bearer token stripped (case insensitive)
input='bearer AbCdEf123456.tokenvalue'
result=$(redact_sensitive "$input")
if echo "$result" | grep -qi "AbCdEf123456"; then
    fail "redact_sensitive bearer token: raw token still present"
else
    pass
fi
if echo "$result" | grep -qi "REDACTED"; then
    pass
else
    fail "redact_sensitive bearer token: REDACTED marker missing"
fi

# =============================================================================
# redact_sensitive — request ID preservation
# =============================================================================

echo "=== redact_sensitive: request ID preservation ==="

# req_* preserved alongside sk-ant-* key
input='Anthropic-Request-Id: req_011CZ9DVbXYZsensitive
x-api-key: sk-ant-secret-key-here
Error: rate limit'
result=$(redact_sensitive "$input")

if echo "$result" | grep -q "req_011CZ9DVbXYZsensitive"; then
    pass
else
    fail "redact_sensitive: Anthropic request ID was stripped (should be preserved): '$result'"
fi

if echo "$result" | grep -q "sk-ant-secret-key-here"; then
    fail "redact_sensitive: sk-ant-* key preserved (should be stripped)"
else
    pass
fi

# Multiple request IDs preserved
input='req_AAA111bbbCCC and req_BBB222dddDDD are both request IDs'
result=$(redact_sensitive "$input")
if echo "$result" | grep -q "req_AAA111bbbCCC" && echo "$result" | grep -q "req_BBB222dddDDD"; then
    pass
else
    fail "redact_sensitive: multiple request IDs not preserved: '$result'"
fi

# =============================================================================
# redact_sensitive — stdin mode
# =============================================================================

echo "=== redact_sensitive: stdin mode ==="

result=$(echo 'x-api-key: mySecretKey123' | redact_sensitive)
if echo "$result" | grep -q "mySecretKey123"; then
    fail "redact_sensitive stdin mode: raw key still present"
else
    pass
fi
if echo "$result" | grep -qi "REDACTED"; then
    pass
else
    fail "redact_sensitive stdin mode: REDACTED marker missing"
fi

# =============================================================================
# redact_sensitive — argument mode
# =============================================================================

echo "=== redact_sensitive: argument mode ==="

result=$(redact_sensitive 'ANTHROPIC_API_KEY=my-very-secret-key')
if echo "$result" | grep -q "my-very-secret-key"; then
    fail "redact_sensitive argument mode: raw key still present"
else
    pass
fi
if echo "$result" | grep -q "ANTHROPIC_API_KEY=\[REDACTED\]"; then
    pass
else
    fail "redact_sensitive argument mode: REDACTED marker missing: '$result'"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "errors.sh unit tests passed"
