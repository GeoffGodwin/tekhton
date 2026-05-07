#!/usr/bin/env bash
# Test: milestone_query.sh — four dual-path wrappers introduced in m14.
#   Tests both the DAG-backed path (manifest present) and the inline CLAUDE.md
#   fallback path (MILESTONE_DAG_ENABLED=false or no manifest).
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

LOG_DIR="${TMPDIR}/.claude/logs"
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_ARCHIVE_FILE="${TMPDIR}/MILESTONE_ARCHIVE.md"
MILESTONE_DAG_ENABLED=true
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
TEST_CMD=""
ANALYZE_CMD=""

export MILESTONE_DAG_ENABLED MILESTONE_DIR MILESTONE_MANIFEST

mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}"

source "${TEKHTON_HOME}/lib/state.sh"
run_build_gate() { return 0; }
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_query.sh"

cd "$TMPDIR"

PASS=0
FAIL=0

assert() {
    local desc="$1" result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

MILESTONE_DIR_ABS="${TMPDIR}/.claude/milestones"
mkdir -p "$MILESTONE_DIR_ABS"

# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------
# Inline CLAUDE.md: three milestones. Milestone 2 marked [DONE].
CLAUDE_MD="${TMPDIR}/CLAUDE.md"
cat > "$CLAUDE_MD" << 'EOF'
# Project

## Milestone Plan

#### Milestone 1: Alpha Feature
Do the alpha work.

Acceptance criteria:
- Alpha criterion one
- Alpha criterion two

#### [DONE] Milestone 2: Beta Feature
Do the beta work.

Acceptance criteria:
- Beta criterion one

#### Milestone 3: Gamma Feature
Depends on Milestone 1.

Acceptance criteria:
- Gamma criterion one
EOF

# Manifest + files matching the same milestones (used by DAG path tests).
cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Alpha Feature|pending||m01-alpha-feature.md|
m02|Beta Feature|done||m02-beta-feature.md|
m03|Gamma Feature|pending|m01|m03-gamma-feature.md|
EOF

cat > "${MILESTONE_DIR_ABS}/m01-alpha-feature.md" << 'EOF'
#### Milestone 1: Alpha Feature

Acceptance criteria:
- Alpha criterion one
- Alpha criterion two
EOF

cat > "${MILESTONE_DIR_ABS}/m02-beta-feature.md" << 'EOF'
#### [DONE] Milestone 2: Beta Feature

Acceptance criteria:
- Beta criterion one
EOF

cat > "${MILESTONE_DIR_ABS}/m03-gamma-feature.md" << 'EOF'
#### Milestone 3: Gamma Feature

Acceptance criteria:
- Gamma criterion one
EOF

# Load manifest into _DAG_* arrays (DAG path tests require this).
load_manifest

# ===========================================================================
echo "--- Test: get_milestone_count (DAG path) ---"

count=$(get_milestone_count "$CLAUDE_MD")
result=0
[[ "$count" -eq 3 ]] && result=0 || result=1
assert "get_milestone_count returns 3 via DAG (got: '$count')" "$result"

# ===========================================================================
echo "--- Test: get_milestone_count (inline fallback) ---"

MILESTONE_DAG_ENABLED=false
_DAG_LOADED=false

count_inline=$(get_milestone_count "$CLAUDE_MD")
result=0
[[ "$count_inline" -eq 3 ]] && result=0 || result=1
assert "get_milestone_count returns 3 via inline fallback (got: '$count_inline')" "$result"

MILESTONE_DAG_ENABLED=true
load_manifest

# ===========================================================================
echo "--- Test: get_milestone_title (DAG path) ---"

title1=$(get_milestone_title "1" "$CLAUDE_MD")
result=0
[[ "$title1" == "Alpha Feature" ]] && result=0 || result=1
assert "get_milestone_title 1 = 'Alpha Feature' via DAG (got: '$title1')" "$result"

title2=$(get_milestone_title "2" "$CLAUDE_MD")
result=0
[[ "$title2" == "Beta Feature" ]] && result=0 || result=1
assert "get_milestone_title 2 = 'Beta Feature' via DAG (got: '$title2')" "$result"

title3=$(get_milestone_title "3" "$CLAUDE_MD")
result=0
[[ "$title3" == "Gamma Feature" ]] && result=0 || result=1
assert "get_milestone_title 3 = 'Gamma Feature' via DAG (got: '$title3')" "$result"

# ===========================================================================
echo "--- Test: get_milestone_title (inline fallback) ---"

MILESTONE_DAG_ENABLED=false
_DAG_LOADED=false

title1_inline=$(get_milestone_title "1" "$CLAUDE_MD")
result=0
[[ "$title1_inline" == "Alpha Feature" ]] && result=0 || result=1
assert "get_milestone_title 1 via inline = 'Alpha Feature' (got: '$title1_inline')" "$result"

title3_inline=$(get_milestone_title "3" "$CLAUDE_MD")
result=0
[[ "$title3_inline" == "Gamma Feature" ]] && result=0 || result=1
assert "get_milestone_title 3 via inline = 'Gamma Feature' (got: '$title3_inline')" "$result"

MILESTONE_DAG_ENABLED=true
load_manifest

# ===========================================================================
echo "--- Test: is_milestone_done (DAG path) ---"

result=0
is_milestone_done "2" "$CLAUDE_MD" && result=0 || result=1
assert "is_milestone_done 2 returns true via DAG (m02 status=done)" "$result"

result=0
is_milestone_done "1" "$CLAUDE_MD" && result=1 || result=0
assert "is_milestone_done 1 returns false via DAG (m01 status=pending)" "$result"

result=0
is_milestone_done "99" "$CLAUDE_MD" && result=1 || result=0
assert "is_milestone_done 99 (unknown id) returns false" "$result"

# ===========================================================================
echo "--- Test: is_milestone_done (inline fallback) ---"

MILESTONE_DAG_ENABLED=false
_DAG_LOADED=false

result=0
is_milestone_done "2" "$CLAUDE_MD" && result=0 || result=1
assert "is_milestone_done 2 returns true via inline ([DONE] marker)" "$result"

result=0
is_milestone_done "1" "$CLAUDE_MD" && result=1 || result=0
assert "is_milestone_done 1 returns false via inline (no [DONE] marker)" "$result"

MILESTONE_DAG_ENABLED=true
load_manifest

# ===========================================================================
echo "--- Test: parse_milestones_auto (DAG path) ---"

auto_out=$(parse_milestones_auto "$CLAUDE_MD")

result=0
echo "$auto_out" | grep -q "1|Alpha Feature" && result=0 || result=1
assert "parse_milestones_auto includes milestone 1 via DAG (got: '$(echo "$auto_out" | head -3)')" "$result"

result=0
echo "$auto_out" | grep -q "2|Beta Feature" && result=0 || result=1
assert "parse_milestones_auto includes milestone 2 via DAG" "$result"

result=0
echo "$auto_out" | grep -q "3|Gamma Feature" && result=0 || result=1
assert "parse_milestones_auto includes milestone 3 via DAG" "$result"

# Acceptance criteria are extracted from milestone files and joined with ';'
result=0
echo "$auto_out" | grep -q "Alpha criterion one" && result=0 || result=1
assert "parse_milestones_auto includes acceptance criteria for m01" "$result"

# Three milestones should appear
line_count=$(echo "$auto_out" | grep -c '|' || true)
result=0
[[ "$line_count" -eq 3 ]] && result=0 || result=1
assert "parse_milestones_auto returns exactly 3 rows via DAG (got: $line_count)" "$result"

# ===========================================================================
echo "--- Test: parse_milestones_auto (inline fallback) ---"

MILESTONE_DAG_ENABLED=false
_DAG_LOADED=false

auto_inline=$(parse_milestones_auto "$CLAUDE_MD")

result=0
echo "$auto_inline" | grep -q "1|Alpha Feature" && result=0 || result=1
assert "parse_milestones_auto includes milestone 1 via inline (got: '$(echo "$auto_inline" | head -3)')" "$result"

result=0
echo "$auto_inline" | grep -q "2|Beta Feature" && result=0 || result=1
assert "parse_milestones_auto includes milestone 2 via inline" "$result"

result=0
echo "$auto_inline" | grep -q "Alpha criterion one" && result=0 || result=1
assert "parse_milestones_auto includes acceptance criteria via inline" "$result"

MILESTONE_DAG_ENABLED=true
load_manifest

# ===========================================================================
echo "--- Test: DAG path when manifest load is unavailable (fallback to inline) ---"

# Simulate a scenario where has_milestone_manifest returns false by
# temporarily removing the manifest file.
mv "${MILESTONE_DIR_ABS}/MANIFEST.cfg" "${MILESTONE_DIR_ABS}/MANIFEST.cfg.bak"
_DAG_LOADED=false

count_no_manifest=$(get_milestone_count "$CLAUDE_MD")
result=0
[[ "$count_no_manifest" -eq 3 ]] && result=0 || result=1
assert "get_milestone_count falls back to inline when manifest absent (got: '$count_no_manifest')" "$result"

# Restore manifest
mv "${MILESTONE_DIR_ABS}/MANIFEST.cfg.bak" "${MILESTONE_DIR_ABS}/MANIFEST.cfg"
load_manifest

# ===========================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
