#!/usr/bin/env bash
# Test: M96 CLI output hygiene — emit_event() must not leak event IDs to stdout.
#
# The contract: every emit_event call site in lib/ and stages/ either captures
# the result via command substitution OR redirects stdout. Bare calls leak the
# pipeline.NNN / tester.NNN identifier into the next log line on the terminal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1 — Runtime smoke: emit_event with stdout redirected emits no event ID
# ---------------------------------------------------------------------------
echo "Test 1: Runtime — redirected emit_event call leaves stdout clean..."
TMPDIR_RUN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_RUN"' EXIT

PROJECT_DIR="$TMPDIR_RUN" \
TEKHTON_SESSION_DIR="$TMPDIR_RUN" \
CAUSAL_LOG_FILE="$TMPDIR_RUN/causal.jsonl" \
TIMESTAMP="20260417_000000" \
bash -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "'"${REPO_ROOT}"'/lib/causality.sh"
    init_causal_log >/dev/null 2>&1
    # Bare call (no capture) with stdout redirect — the M96 fix pattern.
    emit_event "smoke_test" "pipeline" "hygiene check" "" "" "" >/dev/null
' > "$TMPDIR_RUN/stdout.txt" 2> "$TMPDIR_RUN/stderr.txt"

if grep -qE '(pipeline|tester|preflight|gate|build_gate|acceptance|preflight_fix)\.[0-9]+' "$TMPDIR_RUN/stdout.txt"; then
    fail "Stdout contains a leaked event ID after redirected emit_event call"
    sed -n '1,20p' "$TMPDIR_RUN/stdout.txt"
else
    pass "Redirected emit_event call produced no event ID on stdout"
fi

# ---------------------------------------------------------------------------
# Test 2 — Static analysis: every bare emit_event call site in lib/ and stages/
# either captures the result or redirects stdout.
# ---------------------------------------------------------------------------
echo "Test 2: Static — every emit_event call site captures or redirects stdout..."

# Collect call-site starting line numbers — only lines that begin a new
# emit_event invocation (allow optional leading whitespace + nothing else).
mapfile -t CALL_LINES < <(
    grep -nrE '^[[:space:]]*emit_event[[:space:]]+' \
        "${REPO_ROOT}/lib" "${REPO_ROOT}/stages" 2>/dev/null \
        | grep -v ':#' \
        | grep -vE '\.bak:|\.pre-tweak:'
)

if [[ ${#CALL_LINES[@]} -eq 0 ]]; then
    fail "No emit_event call sites found — grep pattern is wrong or files missing"
fi

bad_sites=()
for entry in "${CALL_LINES[@]}"; do
    file="${entry%%:*}"
    rest="${entry#*:}"
    line_no="${rest%%:*}"

    # Read up to 8 lines starting from the call to capture continuations.
    # Stop at the first line whose trailing characters are NOT a backslash —
    # i.e., the final line of the logical statement.
    block=""
    cur=$line_no
    end=$((line_no + 8))
    while [[ "$cur" -le "$end" ]]; do
        line=$(sed -n "${cur}p" "$file")
        block+="$line"$'\n'
        # If this line does NOT end with a backslash continuation, statement is done.
        if [[ ! "$line" =~ \\$ ]]; then
            break
        fi
        cur=$((cur + 1))
    done

    # Acceptable patterns (any one of these means stdout is safe):
    #   1. The starting line is a command substitution capture: var=$(emit_event ...
    #   2. The block redirects stdout: '>/dev/null', '1>/dev/null', or '&>/dev/null'.
    #      A bare '2>/dev/null' is stderr-only and does NOT save us.
    starting_line=$(sed -n "${line_no}p" "$file")
    if [[ "$starting_line" =~ =\$\(emit_event ]]; then
        continue
    fi
    # Match stdout redirects only — leading char must be whitespace, '&', or '1'
    # (not '2'). Use grep -E so the regex is the source of truth.
    if echo "$block" | grep -qE '(^|[[:space:]&]|[^0-9])(1?>|&>)[[:space:]]*/dev/null'; then
        continue
    fi

    bad_sites+=("${file}:${line_no}")
done

if [[ ${#bad_sites[@]} -eq 0 ]]; then
    pass "All emit_event call sites in lib/ and stages/ capture or redirect stdout"
else
    fail "${#bad_sites[@]} emit_event call site(s) leak event ID to stdout:"
    for site in "${bad_sites[@]}"; do
        echo "    $site"
    done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
