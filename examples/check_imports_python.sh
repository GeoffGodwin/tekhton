#!/usr/bin/env bash
# =============================================================================
# check_imports_python.sh — Python dependency constraint validator
#
# Sample validation script for use with Tekhton's dependency constraint system.
# Copy this to your project (e.g. .claude/scripts/check_imports.sh) and
# customize the RULES array for your layer architecture.
#
# Exit 0 = all constraints pass, nonzero = violations found.
#
# Usage:
#   bash .claude/scripts/check_imports.sh
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
# Each rule is: "source_glob|forbidden_import_pattern|description"
#
# source_glob:              files to check (relative to project root)
# forbidden_import_pattern: regex matched against Python import statements
# description:              human-readable explanation of the rule
#
# Customize these for your project's layer architecture.
RULES=(
    "src/domain/**/*.py|from src\\.api|domain must not import api layer"
    "src/domain/**/*.py|import src\\.api|domain must not import api layer"
    "src/domain/**/*.py|from src\\.infrastructure|domain must not import infrastructure"
    "src/domain/**/*.py|import src\\.infrastructure|domain must not import infrastructure"
    "src/services/**/*.py|from src\\.api|services must not import api layer"
    "src/services/**/*.py|import src\\.api|services must not import api layer"
)

# --- Validator ---------------------------------------------------------------

VIOLATIONS=0
VIOLATION_DETAILS=""

for rule in "${RULES[@]}"; do
    IFS='|' read -r source_glob forbidden_pattern description <<< "$rule"

    # Convert glob to find-compatible search: extract base dir, search recursively
    base_dir=$(echo "$source_glob" | sed 's|\*\*/.*||; s|/\*$||; s|\*.*||')
    [ -d "$base_dir" ] || continue

    # Find matching source files
    while IFS= read -r -d '' file; do
        # Check both 'import x' and 'from x import y' lines
        while IFS= read -r line; do
            if echo "$line" | grep -qE "$forbidden_pattern"; then
                VIOLATIONS=$((VIOLATIONS + 1))
                VIOLATION_DETAILS+="  ${file}: ${line}\n"
                VIOLATION_DETAILS+="    Rule: ${description}\n\n"
            fi
        done < <(grep -nE "^(import |from )" "$file" 2>/dev/null || true)
    done < <(find "$base_dir" -name "*.py" -print0 2>/dev/null || true)
done

# --- Report ------------------------------------------------------------------

if [ "$VIOLATIONS" -gt 0 ]; then
    echo "Dependency constraint check FAILED — ${VIOLATIONS} violation(s) found:"
    echo ""
    echo -e "$VIOLATION_DETAILS"
    exit 1
fi

echo "Dependency constraint check passed — no violations."
exit 0
