#!/usr/bin/env bash
# Test: tools/ui_smoke_test.js — pixelDiffRatio function and argument parsing
# Uses node -e to test pure functions without a browser.
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0
SMOKE_SCRIPT="${TEKHTON_HOME}/tools/ui_smoke_test.js"

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

if ! command -v node &>/dev/null; then
    echo "SKIP: node not available — skipping ui_smoke_test.js tests"
    exit 0
fi

if [[ ! -f "$SMOKE_SCRIPT" ]]; then
    echo "FAIL: $SMOKE_SCRIPT not found"
    exit 1
fi

# ---------------------------------------------------------------------------
# Inline pixelDiffRatio for testing (extracted verbatim from ui_smoke_test.js)
# ---------------------------------------------------------------------------

PIXEL_DIFF_FN='
function pixelDiffRatio(hash1, hash2) {
    if (hash1 === hash2) return 0;
    let diff = 0;
    const len = Math.min(hash1.length, hash2.length);
    for (let i = 0; i < len; i++) {
        if (hash1[i] !== hash2[i]) diff++;
    }
    return diff / len;
}
'

# Inline parseArgs for testing (extracted verbatim from ui_smoke_test.js)
PARSE_ARGS_FN='
function parseArgs(argv) {
    const args = argv || [];
    const opts = {
        url: "",
        viewports: "1280x800,375x812",
        timeout: 30,
        severity: "error",
        flickerThreshold: 0.05,
        screenshotDir: "",
        screenshots: true,
        browser: "",
        label: "unknown",
    };
    for (let i = 0; i < args.length; i++) {
        switch (args[i]) {
            case "--url": opts.url = args[++i] || ""; break;
            case "--viewports": opts.viewports = args[++i] || opts.viewports; break;
            case "--timeout": opts.timeout = parseInt(args[++i], 10) || 30; break;
            case "--severity": opts.severity = args[++i] || "error"; break;
            case "--flicker-threshold": opts.flickerThreshold = parseFloat(args[++i]) || 0.05; break;
            case "--screenshot-dir": opts.screenshotDir = args[++i] || ""; break;
            case "--screenshots": opts.screenshots = args[++i] !== "false"; break;
            case "--browser": opts.browser = args[++i] || ""; break;
            case "--label": opts.label = args[++i] || "unknown"; break;
        }
    }
    return opts;
}
'

# ---------------------------------------------------------------------------
# Tests: pixelDiffRatio
# ---------------------------------------------------------------------------

# Identical hashes → ratio is exactly 0
result=$(node -e "
${PIXEL_DIFF_FN}
const h = 'abc123def456abc123def456abc123def456abc123def456abc123def456abc1';
process.stdout.write(String(pixelDiffRatio(h, h)));
" 2>/dev/null)
if [[ "$result" = "0" ]]; then
    pass "pixelDiffRatio: identical hashes return 0"
else
    fail "pixelDiffRatio: expected 0 for identical hashes, got '${result}'"
fi

# Completely different same-length hashes → ratio > 0
result=$(node -e "
${PIXEL_DIFF_FN}
const h1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const h2 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
process.stdout.write(String(pixelDiffRatio(h1, h2) > 0 ? 'yes' : 'no'));
" 2>/dev/null)
if [[ "$result" = "yes" ]]; then
    pass "pixelDiffRatio: completely different hashes return ratio > 0"
else
    fail "pixelDiffRatio: expected ratio > 0 for different hashes, got '${result}'"
fi

# All characters differ → ratio = 1.0
result=$(node -e "
${PIXEL_DIFF_FN}
const h1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const h2 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
process.stdout.write(pixelDiffRatio(h1, h2) === 1 ? 'yes' : 'no');
" 2>/dev/null)
if [[ "$result" = "yes" ]]; then
    pass "pixelDiffRatio: all-different same-length hashes return ratio 1"
else
    fail "pixelDiffRatio: all-different same-length hashes: expected 1, got '${result}'"
fi

# One char differs in a 4-char hash → ratio = 0.25
result=$(node -e "
${PIXEL_DIFF_FN}
process.stdout.write(pixelDiffRatio('aaab', 'aaac').toFixed(2));
" 2>/dev/null)
if [[ "$result" = "0.25" ]]; then
    pass "pixelDiffRatio: one char difference in 4-char hash → 0.25"
else
    fail "pixelDiffRatio: expected 0.25 for 1/4 char diff, got '${result}'"
fi

# Empty strings → 0 (no chars to compare, diff=0/0 but loop never runs)
result=$(node -e "
${PIXEL_DIFF_FN}
const r = pixelDiffRatio('', '');
process.stdout.write(isNaN(r) ? 'NaN' : String(r));
" 2>/dev/null)
if [[ "$result" = "0" ]]; then
    pass "pixelDiffRatio: empty strings return 0"
else
    fail "pixelDiffRatio: empty strings, expected 0, got '${result}'"
fi

# Extra chars in longer hash are ignored (uses min length)
result=$(node -e "
${PIXEL_DIFF_FN}
// 'aaa' vs 'aab' (3 chars, 1 diff) = 1/3
// 'aaa' vs 'aabXXXX' (min=3, 1 diff) = same 1/3
const r1 = pixelDiffRatio('aaa', 'aab');
const r2 = pixelDiffRatio('aaa', 'aabXXXX');
process.stdout.write(r1 === r2 ? 'yes' : 'no');
" 2>/dev/null)
if [[ "$result" = "yes" ]]; then
    pass "pixelDiffRatio: extra chars in longer hash ignored (uses min length)"
else
    fail "pixelDiffRatio: min-length test, got '${result}'"
fi

# Half differing → ratio = 0.5
result=$(node -e "
${PIXEL_DIFF_FN}
const r = pixelDiffRatio('aabb', 'aacc');
process.stdout.write(r.toFixed(2));
" 2>/dev/null)
if [[ "$result" = "0.50" ]]; then
    pass "pixelDiffRatio: two-of-four chars differ → ratio 0.50"
else
    fail "pixelDiffRatio: expected 0.50 for 2/4 diff, got '${result}'"
fi

# ---------------------------------------------------------------------------
# Tests: parseArgs (logic extracted and called with explicit argv arrays)
# ---------------------------------------------------------------------------

# Default opts when argv is empty (except url would cause exit — test other defaults)
result=$(node -e "
${PARSE_ARGS_FN}
const o = parseArgs([]);
process.stdout.write([o.viewports, o.timeout, o.severity, o.label, o.screenshots].join('|'));
" 2>/dev/null)
EXPECTED="1280x800,375x812|30|error|unknown|true"
if [[ "$result" = "$EXPECTED" ]]; then
    pass "parseArgs: default values are correct"
else
    fail "parseArgs: expected '$EXPECTED', got '${result}'"
fi

# --url sets opts.url
result=$(node -e "
${PARSE_ARGS_FN}
const o = parseArgs(['--url', 'http://localhost:3000']);
process.stdout.write(o.url);
" 2>/dev/null)
if [[ "$result" = "http://localhost:3000" ]]; then
    pass "parseArgs: --url value parsed correctly"
else
    fail "parseArgs: expected 'http://localhost:3000', got '${result}'"
fi

# --timeout parsed as integer
result=$(node -e "
${PARSE_ARGS_FN}
const o = parseArgs(['--url', 'http://x', '--timeout', '60']);
process.stdout.write(String(o.timeout));
" 2>/dev/null)
if [[ "$result" = "60" ]]; then
    pass "parseArgs: --timeout parsed as integer"
else
    fail "parseArgs: expected timeout 60, got '${result}'"
fi

# --screenshots false → boolean false
result=$(node -e "
${PARSE_ARGS_FN}
const o = parseArgs(['--url', 'http://x', '--screenshots', 'false']);
process.stdout.write(String(o.screenshots));
" 2>/dev/null)
if [[ "$result" = "false" ]]; then
    pass "parseArgs: --screenshots false sets boolean false"
else
    fail "parseArgs: expected false, got '${result}'"
fi

# --screenshots true → boolean true
result=$(node -e "
${PARSE_ARGS_FN}
const o = parseArgs(['--url', 'http://x', '--screenshots', 'true']);
process.stdout.write(String(o.screenshots));
" 2>/dev/null)
if [[ "$result" = "true" ]]; then
    pass "parseArgs: --screenshots true sets boolean true"
else
    fail "parseArgs: expected true, got '${result}'"
fi

# --flicker-threshold parsed as float
result=$(node -e "
${PARSE_ARGS_FN}
const o = parseArgs(['--url', 'http://x', '--flicker-threshold', '0.1']);
process.stdout.write(String(o.flickerThreshold));
" 2>/dev/null)
if [[ "$result" = "0.1" ]]; then
    pass "parseArgs: --flicker-threshold parsed as float"
else
    fail "parseArgs: expected 0.1, got '${result}'"
fi

# --label sets label
result=$(node -e "
${PARSE_ARGS_FN}
const o = parseArgs(['--url', 'http://x', '--label', 'dashboard']);
process.stdout.write(o.label);
" 2>/dev/null)
if [[ "$result" = "dashboard" ]]; then
    pass "parseArgs: --label value parsed correctly"
else
    fail "parseArgs: expected 'dashboard', got '${result}'"
fi

# --severity warn
result=$(node -e "
${PARSE_ARGS_FN}
const o = parseArgs(['--url', 'http://x', '--severity', 'warn']);
process.stdout.write(o.severity);
" 2>/dev/null)
if [[ "$result" = "warn" ]]; then
    pass "parseArgs: --severity warn parsed correctly"
else
    fail "parseArgs: expected 'warn', got '${result}'"
fi

# --viewports custom viewport string
result=$(node -e "
${PARSE_ARGS_FN}
const o = parseArgs(['--url', 'http://x', '--viewports', '1920x1080']);
process.stdout.write(o.viewports);
" 2>/dev/null)
if [[ "$result" = "1920x1080" ]]; then
    pass "parseArgs: --viewports custom value parsed correctly"
else
    fail "parseArgs: expected '1920x1080', got '${result}'"
fi

# Missing --url in real script exits with code 2
node "$SMOKE_SCRIPT" 2>/dev/null
missing_url_exit=$?
if [[ "$missing_url_exit" -eq 2 ]]; then
    pass "parseArgs: script exits with code 2 when --url missing"
else
    fail "parseArgs: expected exit code 2 for missing --url, got ${missing_url_exit}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    exit 0
else
    exit 1
fi
