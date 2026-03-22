#!/usr/bin/env bash
# Test: Milestone sliding window — budget calculation, priority ordering,
# budget exhaustion, and fallback behavior
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Provide stubs for config values
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
TEST_CMD=""
ANALYZE_CMD=""
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}"

MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_DAG_ENABLED=true
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
MILESTONE_ARCHIVE_FILE="${TMPDIR}/MILESTONE_ARCHIVE.md"
CONTEXT_BUDGET_ENABLED=true
CONTEXT_BUDGET_PCT=50
CHARS_PER_TOKEN=4
MILESTONE_WINDOW_PCT=30
MILESTONE_WINDOW_MAX_CHARS=20000

export MILESTONE_DAG_ENABLED MILESTONE_DIR MILESTONE_MANIFEST
export CONTEXT_BUDGET_ENABLED CONTEXT_BUDGET_PCT CHARS_PER_TOKEN
export MILESTONE_WINDOW_PCT MILESTONE_WINDOW_MAX_CHARS

source "${TEKHTON_HOME}/lib/state.sh"

# Stub run_build_gate
run_build_gate() { return 0; }

source "${TEKHTON_HOME}/lib/context.sh"
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_migrate.sh"
source "${TEKHTON_HOME}/lib/milestone_archival_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"
source "${TEKHTON_HOME}/lib/milestone_ops.sh"
source "${TEKHTON_HOME}/lib/milestone_window.sh"

cd "$TMPDIR"

PASS=0
FAIL=0

assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# =============================================================================
echo "--- Test: _compute_milestone_budget ---"

budget=$(_compute_milestone_budget "opus")
# 200000 tokens * 4 chars/token * 50% budget * 30% window = 120000
# But capped at 20000
result=0
[[ "$budget" -eq 20000 ]] && result=0 || result=1
assert "budget capped at MILESTONE_WINDOW_MAX_CHARS (got: $budget)" "$result"

# Test with a smaller cap to verify percentage calculation
MILESTONE_WINDOW_MAX_CHARS=999999
budget=$(_compute_milestone_budget "opus")
# 200000 * 4 * 50/100 * 30/100 = 120000
result=0
[[ "$budget" -eq 120000 ]] && result=0 || result=1
assert "budget is 30% of available context (got: $budget)" "$result"

# Restore
MILESTONE_WINDOW_MAX_CHARS=20000

# =============================================================================
echo "--- Test: build_milestone_window (no manifest) ---"

MILESTONE_BLOCK=""
result=0
build_milestone_window "opus" && result=1 || result=0
assert "returns 1 when no manifest loaded" "$result"

# =============================================================================
echo "--- Setup: Create test milestones ---"

MILESTONE_DIR_ABS="${TMPDIR}/.claude/milestones"
mkdir -p "$MILESTONE_DIR_ABS"

cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|DAG Infrastructure|done||m01-dag-infra.md|foundation
m02|Sliding Window|in_progress|m01|m02-sliding-window.md|foundation
m03|Indexer Setup|pending|m01|m03-indexer-setup.md|indexer
m04|Repo Map Generator|pending|m03|m04-repo-map.md|indexer
m05|Pipeline Integration|pending|m04|m05-pipeline-integration.md|indexer
EOF

# Create milestone files with varying content sizes
cat > "${MILESTONE_DIR_ABS}/m01-dag-infra.md" << 'EOF'
#### Milestone 1: DAG Infrastructure
Implement DAG-based milestone storage.

Acceptance criteria:
- Manifest parsing works
- DAG queries work
EOF

cat > "${MILESTONE_DIR_ABS}/m02-sliding-window.md" << 'EOF'
#### Milestone 2: Sliding Window
Wire the DAG into the prompt engine with a character-budgeted sliding window.

This milestone creates the bridge between the DAG and agent prompts.

Acceptance criteria:
- build_milestone_window returns budgeted content
- Active milestone gets full content
- Frontier milestones get summary

Watch For:
- Character budget must account for header overhead

Seeds Forward:
- The sliding window pattern extends for repo map integration
EOF

cat > "${MILESTONE_DIR_ABS}/m03-indexer-setup.md" << 'EOF'
#### Milestone 3: Indexer Setup
Add shell-side orchestration for the indexer.

Acceptance criteria:
- Setup command works
- Config keys validated
EOF

cat > "${MILESTONE_DIR_ABS}/m04-repo-map.md" << 'EOF'
#### Milestone 4: Repo Map Generator
Implement the Python tree-sitter repo map tool.

Acceptance criteria:
- Repo map generates ranked output
EOF

cat > "${MILESTONE_DIR_ABS}/m05-pipeline-integration.md" << 'EOF'
#### Milestone 5: Pipeline Integration
Wire repo map into pipeline stages.

Acceptance criteria:
- Stages receive correct slices
EOF

load_manifest

# =============================================================================
echo "--- Test: _milestone_priority_list ---"

priority=$(_milestone_priority_list)

# m01 is done — should NOT appear
result=0
echo "$priority" | grep -q "m01" && result=1 || result=0
assert "done milestone (m01) not in priority list" "$result"

# m02 (in_progress) should be first
result=0
first=$(echo "$priority" | head -1)
[[ "$first" == "m02" ]] && result=0 || result=1
assert "active milestone (m02) is first (got: $first)" "$result"

# m03 (frontier: dep m01 is done) should come after active
result=0
echo "$priority" | grep -q "m03" && result=0 || result=1
assert "frontier milestone (m03) in priority list" "$result"

# m04 (on-deck: dep m03 not done) should be last
result=0
last=$(echo "$priority" | tail -1 | tr -d '[:space:]')
[[ "$last" == "m05" ]] && result=0 || result=1
assert "on-deck milestone (m05) is last (got: '$last')" "$result"

# =============================================================================
echo "--- Test: build_milestone_window (normal budget) ---"

MILESTONE_BLOCK=""
result=0
build_milestone_window "opus" && result=0 || result=1
assert "build_milestone_window succeeds" "$result"

result=0
[[ -n "$MILESTONE_BLOCK" ]] && result=0 || result=1
assert "MILESTONE_BLOCK is non-empty" "$result"

# Active milestone (m02) should have full content including Seeds Forward
result=0
echo "$MILESTONE_BLOCK" | grep -q "Seeds Forward" && result=0 || result=1
assert "active milestone has full content (Seeds Forward present)" "$result"

# Frontier milestone (m03) should be included
result=0
echo "$MILESTONE_BLOCK" | grep -q "Indexer Setup" && result=0 || result=1
assert "frontier milestone (m03) included" "$result"

# Header instructions should be present
result=0
echo "$MILESTONE_BLOCK" | grep -q "Milestone Mode" && result=0 || result=1
assert "header instructions present" "$result"

# =============================================================================
echo "--- Test: build_milestone_window (tiny budget — budget exhaustion) ---"

MILESTONE_WINDOW_MAX_CHARS=500
MILESTONE_BLOCK=""
build_milestone_window "opus" || true

result=0
[[ -n "$MILESTONE_BLOCK" ]] && result=0 || result=1
assert "builds window even with tiny budget" "$result"

# With 500 chars budget minus 350 header = 150 usable chars
# Only the active milestone title line should fit
result=0
echo "$MILESTONE_BLOCK" | grep -q "Sliding Window" && result=0 || result=1
assert "active milestone title included in tiny budget" "$result"

# Restore
MILESTONE_WINDOW_MAX_CHARS=20000

# =============================================================================
echo "--- Test: build_milestone_window (active milestone last-resort title-only truncation) ---"
# Set budget so that remaining < first-para+acceptance but > title.
# m02 first-para+acceptance ≈ 258 chars; title ≈ 33 chars.
# remaining = 450 - 350 = 100: too small for truncated, fits title.
MILESTONE_WINDOW_MAX_CHARS=450
MILESTONE_BLOCK=""
build_milestone_window "opus" || true

# Window should still succeed (title fits)
result=0
[[ -n "$MILESTONE_BLOCK" ]] && result=0 || result=1
assert "last-resort: window builds with title-only budget" "$result"

# Title should be present
result=0
echo "$MILESTONE_BLOCK" | grep -q "Sliding Window" && result=0 || result=1
assert "last-resort: active milestone title present" "$result"

# Acceptance criteria must NOT be present (proves last-resort path taken, not truncated path)
result=0
echo "$MILESTONE_BLOCK" | grep -q "Acceptance criteria" && result=1 || result=0
assert "last-resort: acceptance criteria absent (title-only path confirmed)" "$result"

# Seeds Forward must NOT be present
result=0
echo "$MILESTONE_BLOCK" | grep -q "Seeds Forward" && result=1 || result=0
assert "last-resort: seeds forward absent" "$result"

# Restore
MILESTONE_WINDOW_MAX_CHARS=20000

# =============================================================================
echo "--- Test: build_milestone_window (DAG disabled fallback) ---"

MILESTONE_DAG_ENABLED=false
MILESTONE_BLOCK=""
result=0
build_milestone_window "opus" && result=1 || result=0
assert "returns 1 when DAG disabled" "$result"

# Restore
MILESTONE_DAG_ENABLED=true

# =============================================================================
echo "--- Test: _extract_first_paragraph_and_acceptance ---"

content="#### Milestone 2: Sliding Window
Wire the DAG into the prompt engine.

This is the second paragraph that should not appear.

Acceptance criteria:
- build_milestone_window returns budgeted content
- Active milestone gets full content

Watch For:
- Something important"

extracted=$(_extract_first_paragraph_and_acceptance "$content")

result=0
echo "$extracted" | grep -q "Wire the DAG" && result=0 || result=1
assert "first paragraph extracted" "$result"

result=0
echo "$extracted" | grep -q "Acceptance criteria" && result=0 || result=1
assert "acceptance criteria extracted" "$result"

result=0
echo "$extracted" | grep -q "build_milestone_window" && result=0 || result=1
assert "acceptance items extracted" "$result"

result=0
echo "$extracted" | grep -q "second paragraph" && result=1 || result=0
assert "second paragraph NOT extracted" "$result"

# =============================================================================
echo "--- Test: _extract_title_line (isolated) ---"

# Happy path: heading is the first line
title_content="#### Milestone 5: Pipeline Integration
Wire repo map into pipeline stages.

Acceptance criteria:
- Stages receive correct slices"

title=$(_extract_title_line "$title_content")
result=0
[[ "$title" == "#### Milestone 5: Pipeline Integration" ]] && result=0 || result=1
assert "_extract_title_line returns first heading line (got: '$title')" "$result"

# Leading blank lines are skipped
title_blank_content="
#### Milestone 5: Pipeline Integration
Wire repo map."
title2=$(_extract_title_line "$title_blank_content")
result=0
[[ "$title2" == "#### Milestone 5: Pipeline Integration" ]] && result=0 || result=1
assert "_extract_title_line skips leading blank lines (got: '$title2')" "$result"

# Single-line input
title3=$(_extract_title_line "#### Only Line")
result=0
[[ "$title3" == "#### Only Line" ]] && result=0 || result=1
assert "_extract_title_line handles single-line input (got: '$title3')" "$result"

# =============================================================================
echo "--- Test: build_milestone_window (frontier fits, on-deck excluded) ---"

# Re-load manifest to ensure consistent state
MILESTONE_WINDOW_MAX_CHARS=20000
load_manifest

# Compute a budget that fits active (full) + frontier (summary) but NOT on-deck (title)
m02_full=$(_read_milestone_file "m02")
m03_full=$(_read_milestone_file "m03")
m03_summary=$(_extract_first_paragraph_and_acceptance "$m03_full")

# Budget = header + active_full + frontier_summary → 0 chars left for on-deck
precise_budget=$(( _MILESTONE_WINDOW_HEADER_CHARS + ${#m02_full} + ${#m03_summary} ))
MILESTONE_WINDOW_MAX_CHARS=$precise_budget

MILESTONE_BLOCK=""
build_milestone_window "opus" || true

# Frontier milestone (m03) must be present
result=0
echo "$MILESTONE_BLOCK" | grep -q "Indexer Setup" && result=0 || result=1
assert "frontier milestone (m03) included when budget allows" "$result"

# On-deck milestone (m04) must NOT be present
result=0
echo "$MILESTONE_BLOCK" | grep -q "Repo Map Generator" && result=1 || result=0
assert "on-deck milestone (m04) excluded when budget exhausted by frontier" "$result"

# Active milestone (m02) must be present with full content
result=0
echo "$MILESTONE_BLOCK" | grep -q "Seeds Forward" && result=0 || result=1
assert "active milestone (m02) has full content in frontier-boundary test" "$result"

# Restore
MILESTONE_WINDOW_MAX_CHARS=20000

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
