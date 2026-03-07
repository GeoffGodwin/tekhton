#!/usr/bin/env bash
# =============================================================================
# check_imports_dart.sh — Dart/Flutter dependency constraint validator
#
# Sample validation script for use with Tekhton's dependency constraint system.
# Copy this to your project (e.g. .claude/scripts/check_imports.sh) and
# customize the RULES array for your layer architecture.
#
# Exit 0 = all constraints pass, nonzero = violations found.
#
# Usage:
#   bash .claude/scripts/check_imports.sh
#   # or make executable and call directly:
#   chmod +x .claude/scripts/check_imports.sh
#   .claude/scripts/check_imports.sh
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
# Each rule is: "source_glob|forbidden_import_pattern|description"
#
# source_glob:              files to check (relative to project root)
# forbidden_import_pattern: regex matched against Dart import paths
# description:              human-readable explanation of the rule
#
# Customize these for your project's layer architecture.
RULES=(
    "lib/engine/rules/**/*.dart|package:[^/]+/features/|engine/rules must not import features"
    "lib/engine/rules/**/*.dart|package:[^/]+/persistence/|engine/rules must not import persistence"
    "lib/engine/state/**/*.dart|package:[^/]+/features/|engine/state must not import features"
    "lib/engine/state/**/*.dart|package:[^/]+/persistence/|engine/state must not import persistence"
    "lib/engine/actions/**/*.dart|package:[^/]+/features/|engine/actions must not import features"
    "lib/models/**/*.dart|package:[^/]+/features/|models must not import features"
    "lib/models/**/*.dart|package:[^/]+/persistence/|models must not import persistence"
    "lib/core/**/*.dart|package:[^/]+/features/|core must not import features"
    "lib/core/**/*.dart|package:[^/]+/persistence/|core must not import persistence"
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
        # Extract import lines and check against forbidden pattern
        while IFS= read -r line; do
            if echo "$line" | grep -qE "$forbidden_pattern"; then
                VIOLATIONS=$((VIOLATIONS + 1))
                VIOLATION_DETAILS+="  ${file}: ${line}\n"
                VIOLATION_DETAILS+="    Rule: ${description}\n\n"
            fi
        done < <(grep -E "^import " "$file" 2>/dev/null || true)
    done < <(find "$base_dir" -name "*.dart" -print0 2>/dev/null || true)
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
