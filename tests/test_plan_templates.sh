#!/usr/bin/env bash
# Test: Planning phase template existence and content
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_DIR="${TEKHTON_HOME}/templates/plans"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Expected types → minimum required section count (from CODER_SUMMARY.md)
declare -A EXPECTED_REQUIRED
EXPECTED_REQUIRED["web-app"]=6
EXPECTED_REQUIRED["web-game"]=6
EXPECTED_REQUIRED["cli-tool"]=6
EXPECTED_REQUIRED["api-service"]=6
EXPECTED_REQUIRED["mobile-app"]=6
EXPECTED_REQUIRED["library"]=5
EXPECTED_REQUIRED["custom"]=4

echo "=== Template Existence ==="

for type in "${!EXPECTED_REQUIRED[@]}"; do
    tmpl="${TEMPLATES_DIR}/${type}.md"
    if [ -f "$tmpl" ]; then
        pass "${type}.md exists"
    else
        fail "${type}.md missing at ${tmpl}"
    fi
done

echo
echo "=== REQUIRED Marker Count ==="

for type in "${!EXPECTED_REQUIRED[@]}"; do
    tmpl="${TEMPLATES_DIR}/${type}.md"
    [ -f "$tmpl" ] || continue

    expected="${EXPECTED_REQUIRED[$type]}"
    actual=$(grep -c '<!-- REQUIRED -->' "$tmpl" || true)

    if [ "$actual" -eq "$expected" ]; then
        pass "${type}.md: ${actual} REQUIRED markers"
    else
        fail "${type}.md: expected ${expected} REQUIRED markers, got ${actual}"
    fi
done

echo
echo "=== Section Heading Structure ==="

for type in "${!EXPECTED_REQUIRED[@]}"; do
    tmpl="${TEMPLATES_DIR}/${type}.md"
    [ -f "$tmpl" ] || continue

    # Every template must have an Overview or Project Overview section
    if grep -q '^## .*Overview' "$tmpl"; then
        pass "${type}.md: has Overview section"
    else
        fail "${type}.md: missing Overview section"
    fi

    # Every template must have a Tech Stack section
    if grep -q '^## Tech Stack' "$tmpl"; then
        pass "${type}.md: has Tech Stack section"
    else
        fail "${type}.md: missing Tech Stack section"
    fi

    # Sections that have REQUIRED markers must be ## headings directly above the marker
    # Check that no REQUIRED marker appears without a ## heading preceding it
    prev_line=""
    while IFS= read -r line; do
        if [[ "$line" == "<!-- REQUIRED -->" ]]; then
            if [[ "$prev_line" =~ ^## ]]; then
                pass "${type}.md: REQUIRED marker follows a ## heading ('${prev_line}')"
            else
                fail "${type}.md: REQUIRED marker not directly after ## heading (prev: '${prev_line}')"
            fi
        fi
        prev_line="$line"
    done < "$tmpl"
done

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
