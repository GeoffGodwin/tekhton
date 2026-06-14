#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# lint-milestones.sh — S4 authoring gate for milestone files.
#
# Runs the high-confidence deliverable↔criterion coverage lint
# (lib/milestone_acceptance_lint.sh::lint_milestone_coverage) over every
# milestone file. Exits non-zero on any finding. This is the gate hand-authored
# milestones get (they bypass the --draft authoring flow), suitable for CI and
# manual pre-commit checks.
#
# Usage: scripts/lint-milestones.sh [MILESTONE_DIR]   (default .claude/milestones)
# =============================================================================

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${1:-${ROOT}/.claude/milestones}"

# lint_milestone_coverage has no external deps (no log/warn), so sourcing is
# self-contained.
# shellcheck source=../lib/milestone_acceptance_lint.sh disable=SC1091
source "${ROOT}/lib/milestone_acceptance_lint.sh"

fail=0
shopt -s nullglob
for f in "${DIR}"/m*.md; do
    [[ -f "$f" ]] || continue
    blocking="$(lint_milestone_blocking "$f")"
    if [[ -n "$blocking" ]]; then
        echo "FAIL $(basename "$f")"
        printf '%s\n' "$blocking" | sed 's/^/  - /'
        fail=1
    fi
    coverage="$(lint_milestone_coverage "$f")"
    if [[ -n "$coverage" ]]; then
        echo "advisory $(basename "$f") (deliverables without a named criterion):"
        printf '%s\n' "$coverage" | sed 's/^/  ~ /'
    fi
done

if [[ "$fail" -eq 0 ]]; then
    echo "milestone lint: no blocking findings"
else
    echo "milestone lint: blocking findings above — fix the milestone(s)"
fi
exit "$fail"
