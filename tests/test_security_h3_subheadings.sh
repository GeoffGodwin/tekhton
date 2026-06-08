#!/usr/bin/env bash
# =============================================================================
# test_security_h3_subheadings.sh — m49 shim-boundary integration test.
#
# Drives the bash → Go-binary boundary for the security gate's docs-only
# skip check. The boundary is `tekhton security is-docs-only --summary PATH`,
# which the operator-facing CLI exposes and which the in-process Go stage
# also calls via internal/security.IsDocsOnly. Exit codes:
#
#   0 → docs-only (skip security scan)
#   1 → has code OR extractor saw nothing (m49: fail-closed)
#
# Pre-m49 behavior (the m48 false-skip incident):
#   - H3 subheadings (`### Modified`) were not recognized, so the file list
#     came back empty → IsDocsOnly returned (true, nil) → security skipped.
#   - Coder summaries missing the Files section entirely also short-
#     circuited to (true, nil) → security skipped.
#
# Post-m49 behavior asserted here:
#   A. H3 with a .go file → scan runs (exit 1).
#   B. No Files section → scan runs (exit 1, fail-closed default).
#   C. Empty Files section → scan runs (exit 1, fail-closed default).
#   D. H2 with .go file → scan runs (exit 1, regression guard).
#   E. H2 with all-docs files → skip (exit 0, regression guard).
#   F. H3 with all-docs files → skip (exit 0, m49 H3-recognition + docs ext).
#
# Self-skips cleanly when the tekhton binary isn't built (fresh-clone CI
# before `make build`); operates only at the user-visible CLI surface.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAIL=0
_pass() { echo "PASS: $*"; }
_fail() { echo "FAIL: $*"; FAIL=1; }

_TEKHTON_BIN=""
if [[ -x "${TEKHTON_HOME}/bin/tekhton" ]]; then
    _TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"
fi

if [[ -z "$_TEKHTON_BIN" ]]; then
    echo "SKIP: tekhton binary not built (run 'make build' to enable)"
    exit 0
fi

# _write_summary PATH BODY — atomic writer for the fixture content.
_write_summary() {
    local p="$1"
    local body="$2"
    printf '%s\n' "$body" > "$p"
}

# _docs_only_exit PATH — runs `tekhton security is-docs-only --summary PATH`
# and prints its exit code. Suppresses stdout/stderr so the test only relies
# on the exit-code contract (the only observable the production stage uses).
_docs_only_exit() {
    local p="$1"
    local rc=0
    "$_TEKHTON_BIN" security is-docs-only --summary "$p" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# ---------------------------------------------------------------------------
# A. H3 subheading + .go file → scan runs (exit 1).
#    This is the m48 false-skip incident reproduced. Pre-m49 the extractor
#    missed `### Modified` and the empty list short-circuited to docs-only.
# ---------------------------------------------------------------------------
_H3_GO="${TEST_TMPDIR}/h3_with_go.md"
_write_summary "$_H3_GO" "# Coder Summary

## Status: COMPLETE

## Files

### Modified

- internal/example/foo.go
- internal/example/foo_test.go
"

_rc=$(_docs_only_exit "$_H3_GO")
if [[ "$_rc" == "1" ]]; then
    _pass "A: H3 with .go file → scan runs (exit 1)"
else
    _fail "A: H3 with .go file → expected exit 1 (scan), got $_rc"
fi

# ---------------------------------------------------------------------------
# B. No Files section → scan runs (exit 1, m49 fail-closed default).
# ---------------------------------------------------------------------------
_NO_SECTION="${TEST_TMPDIR}/no_section.md"
_write_summary "$_NO_SECTION" "# Coder Summary

## Status: COMPLETE

## Notes

Summary missing any Files section.
"

_rc=$(_docs_only_exit "$_NO_SECTION")
if [[ "$_rc" == "1" ]]; then
    _pass "B: missing Files section → scan runs (exit 1, fail-closed)"
else
    _fail "B: missing Files section → expected exit 1 (fail-closed scan), got $_rc"
fi

# ---------------------------------------------------------------------------
# C. Empty Files section → scan runs (exit 1, m49 fail-closed default).
# ---------------------------------------------------------------------------
_EMPTY_SECTION="${TEST_TMPDIR}/empty_section.md"
_write_summary "$_EMPTY_SECTION" "# Coder Summary

## Status: COMPLETE

## Files Modified

- None
- (fill in as you go)
"

_rc=$(_docs_only_exit "$_EMPTY_SECTION")
if [[ "$_rc" == "1" ]]; then
    _pass "C: empty Files section → scan runs (exit 1, fail-closed)"
else
    _fail "C: empty Files section → expected exit 1 (fail-closed scan), got $_rc"
fi

# ---------------------------------------------------------------------------
# D. H2 with .go file → scan runs (exit 1, regression guard).
# ---------------------------------------------------------------------------
_H2_GO="${TEST_TMPDIR}/h2_with_go.md"
_write_summary "$_H2_GO" "# Coder Summary

## Status: COMPLETE

## Files Modified

- internal/example/foo.go
"

_rc=$(_docs_only_exit "$_H2_GO")
if [[ "$_rc" == "1" ]]; then
    _pass "D: H2 with .go file → scan runs (exit 1, canonical regression guard)"
else
    _fail "D: H2 with .go file → expected exit 1 (scan), got $_rc"
fi

# ---------------------------------------------------------------------------
# E. H2 with all-docs files → skip (exit 0, regression guard for happy path).
# ---------------------------------------------------------------------------
_H2_DOCS="${TEST_TMPDIR}/h2_docs_only.md"
_write_summary "$_H2_DOCS" "# Coder Summary

## Status: COMPLETE

## Files Modified

- README.md
- docs/api.yaml
"

_rc=$(_docs_only_exit "$_H2_DOCS")
if [[ "$_rc" == "0" ]]; then
    _pass "E: H2 with all docs → skip (exit 0, canonical regression guard)"
else
    _fail "E: H2 with all docs → expected exit 0 (skip), got $_rc"
fi

# ---------------------------------------------------------------------------
# F. H3 with all-docs files → skip (exit 0, m49 H3-recognition preserves
#    docs-only fast-path when every file legitimately is docs).
# ---------------------------------------------------------------------------
_H3_DOCS="${TEST_TMPDIR}/h3_docs_only.md"
_write_summary "$_H3_DOCS" "# Coder Summary

## Status: COMPLETE

## Files

### Modified

- README.md
- docs/api.yaml
"

_rc=$(_docs_only_exit "$_H3_DOCS")
if [[ "$_rc" == "0" ]]; then
    _pass "F: H3 with all docs → skip (exit 0, m49 H3 recognition + docs ext)"
else
    _fail "F: H3 with all docs → expected exit 0 (skip), got $_rc"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "security H3 subheadings test passed"
