#!/usr/bin/env bash
# Test: set_focused_milestone_block — resolution path, full-content guarantee,
# and guard conditions.
# Reviewer gap: no test verified that the focused block carries the FULL
# milestone body (not the truncated multi-milestone window from
# build_milestone_window).
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
TEST_CMD=""
ANALYZE_CMD=""
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}"

MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_DAG_ENABLED=true
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
CONTEXT_BUDGET_ENABLED=true
CONTEXT_BUDGET_PCT=50
CHARS_PER_TOKEN=4
MILESTONE_WINDOW_PCT=30
MILESTONE_WINDOW_MAX_CHARS=20000

export MILESTONE_DAG_ENABLED MILESTONE_DIR MILESTONE_MANIFEST
export CONTEXT_BUDGET_ENABLED CONTEXT_BUDGET_PCT CHARS_PER_TOKEN
export MILESTONE_WINDOW_PCT MILESTONE_WINDOW_MAX_CHARS

source "${TEKHTON_HOME}/lib/state.sh"

run_build_gate() { return 0; }

source "${TEKHTON_HOME}/lib/context.sh"
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_query.sh"
source "${TEKHTON_HOME}/lib/milestone_ops.sh"
source "${TEKHTON_HOME}/lib/milestone_window.sh"

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

# =============================================================================
# Fixtures
# =============================================================================

MILESTONE_DIR_ABS="${TMPDIR}/.claude/milestones"
mkdir -p "$MILESTONE_DIR_ABS"

# Use a long milestone body that is guaranteed to be truncated by
# build_milestone_window under a tight budget, but must survive intact
# inside set_focused_milestone_block.  The "Seeds Forward" and "Watch For"
# sections will be the canary — build_milestone_window truncates them under a
# 500-char cap; set_focused_milestone_block must always include them.
cat > "${MILESTONE_DIR_ABS}/m02-sliding-window.md" << 'MILESTONE_EOF'
#### Milestone 2: Sliding Window
Wire the DAG into the prompt engine with a character-budgeted sliding window.

This milestone creates the bridge between the DAG and agent prompts.
It has multiple paragraphs of design detail, which the budget window
would truncate when the overall character cap is small.

Design:
- Implement _compute_milestone_budget to derive chars from model window
- Implement _milestone_priority_list for active/frontier/on-deck ordering
- Implement build_milestone_window to assemble the final block

Acceptance Criteria:
- build_milestone_window returns budgeted content
- Active milestone gets full content
- Frontier milestones get summary
- On-deck milestones get title only
- Budget exhaustion stops iteration cleanly

Watch For:
- Character budget must account for header overhead (_MILESTONE_WINDOW_HEADER_CHARS)
- The priority list must honour DAG dependency order

Seeds Forward:
- The sliding window pattern extends for repo map integration in Milestone 4
- The _extract_first_paragraph_and_acceptance helper is reused by the split agent
MILESTONE_EOF

cat > "${MILESTONE_DIR_ABS}/m03-indexer-setup.md" << 'MILESTONE_EOF'
#### Milestone 3: Indexer Setup
Add shell-side orchestration for the indexer.

Acceptance Criteria:
- Setup command works
- Config keys validated
MILESTONE_EOF

# Milestone with unpadded single-digit id — used by the m-prefix fallback test.
cat > "${MILESTONE_DIR_ABS}/m7-fallback-test.md" << 'MILESTONE_EOF'
#### Milestone 7: Fallback Test
Minimal milestone for testing the m-prefix fallback path.

Acceptance Criteria:
- set_focused_milestone_block resolves numeric 7 without dag_number_to_id
MILESTONE_EOF

cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|DAG Infrastructure|done||m01-dag-infra.md|foundation
m02|Sliding Window|in_progress|m01|m02-sliding-window.md|foundation
m03|Indexer Setup|pending|m01|m03-indexer-setup.md|indexer
m7|Fallback Test|pending||m7-fallback-test.md|test
EOF

# m01 file not needed — it is "done" and never read by the functions under test.
# Create a stub so load_manifest does not warn about a missing file.
touch "${MILESTONE_DIR_ABS}/m01-dag-infra.md"

load_manifest

# =============================================================================
echo "--- Test: stage subprocess case — manifest NOT preloaded ---"
# Regression for the M23 cascade (2026-05): the stagerunner's bash
# subprocess sources milestone_dag.sh (which only DECLARES empty _DAG_*
# arrays) but nothing in the stage start-up calls load_manifest. When
# set_focused_milestone_block was called from stages/coder.sh without
# the manifest being loaded, dag_get_file silently returned empty,
# _read_milestone_file fell through, and MILESTONE_BLOCK stayed unset
# — scout received an empty milestone prompt and reported "no task,"
# coder ran 1 turn doing nothing, synthesize-fallback faked COMPLETE.
# The function must call load_manifest itself when arrays are empty.
_DAG_LOADED=false
_DAG_IDS=()
_DAG_TITLES=()
_DAG_STATUSES=()
_DAG_DEPS=()
_DAG_FILES=()
_DAG_GROUPS=()
declare -A _DAG_IDX=()

MILESTONE_MODE=true
_CURRENT_MILESTONE=2
MILESTONE_BLOCK=""
result=0
set_focused_milestone_block && result=0 || result=1
assert "returns 0 even when manifest was NOT preloaded (auto-loads on demand)" "$result"

result=0
[[ -n "$MILESTONE_BLOCK" ]] && result=0 || result=1
assert "MILESTONE_BLOCK populated despite cold-start manifest state" "$result"

result=0
echo "$MILESTONE_BLOCK" | grep -q "Sliding Window" && result=0 || result=1
assert "auto-loaded path resolves m02 file content correctly" "$result"

# =============================================================================
echo "--- Test: MILESTONE_MODE disabled ---"

unset MILESTONE_BLOCK 2>/dev/null || true
MILESTONE_BLOCK=""
MILESTONE_MODE=false
_CURRENT_MILESTONE=2
result=0
set_focused_milestone_block && result=1 || result=0
assert "returns 1 when MILESTONE_MODE=false" "$result"

result=0
[[ -z "$MILESTONE_BLOCK" ]] && result=0 || result=1
assert "MILESTONE_BLOCK unchanged when disabled" "$result"

# =============================================================================
echo "--- Test: _CURRENT_MILESTONE empty ---"

MILESTONE_MODE=true
_CURRENT_MILESTONE=""
result=0
set_focused_milestone_block && result=1 || result=0
assert "returns 1 when _CURRENT_MILESTONE is empty" "$result"

# =============================================================================
echo "--- Test: happy path — numeric ID resolved via dag_number_to_id ---"

MILESTONE_MODE=true
_CURRENT_MILESTONE=2
MILESTONE_BLOCK=""
result=0
set_focused_milestone_block && result=0 || result=1
assert "returns 0 for valid numeric _CURRENT_MILESTONE (got rc=$?)" "$result"

result=0
[[ -n "$MILESTONE_BLOCK" ]] && result=0 || result=1
assert "MILESTONE_BLOCK is non-empty after success" "$result"

# =============================================================================
echo "--- Test: full content — not the truncated window ---"
# Set a tiny budget so build_milestone_window would truncate m02 to its title
# only (strips Seeds Forward / Watch For sections).  set_focused_milestone_block
# must still deliver the full body regardless.

MILESTONE_WINDOW_MAX_CHARS=200
MILESTONE_BLOCK=""
set_focused_milestone_block
result=0
echo "$MILESTONE_BLOCK" | grep -q "Seeds Forward" && result=0 || result=1
assert "MILESTONE_BLOCK includes Seeds Forward despite tight budget" "$result"

result=0
echo "$MILESTONE_BLOCK" | grep -q "Watch For" && result=0 || result=1
assert "MILESTONE_BLOCK includes Watch For section" "$result"

result=0
echo "$MILESTONE_BLOCK" | grep -q "Acceptance Criteria" && result=0 || result=1
assert "MILESTONE_BLOCK includes Acceptance Criteria section" "$result"

# Restore
MILESTONE_WINDOW_MAX_CHARS=20000

# =============================================================================
echo "--- Test: content structure — delimiters and header ---"

MILESTONE_BLOCK=""
set_focused_milestone_block

result=0
echo "$MILESTONE_BLOCK" | grep -q "BEGIN MILESTONE CONTENT" && result=0 || result=1
assert "MILESTONE_BLOCK has BEGIN MILESTONE CONTENT delimiter" "$result"

result=0
echo "$MILESTONE_BLOCK" | grep -q "END MILESTONE CONTENT" && result=0 || result=1
assert "MILESTONE_BLOCK has END MILESTONE CONTENT delimiter" "$result"

result=0
echo "$MILESTONE_BLOCK" | grep -q "Active Milestone" && result=0 || result=1
assert "MILESTONE_BLOCK has Active Milestone header" "$result"

result=0
echo "$MILESTONE_BLOCK" | grep -q "m02" && result=0 || result=1
assert "MILESTONE_BLOCK names the resolved milestone ID (m02)" "$result"

# =============================================================================
echo "--- Test: instruction text in header ---"

result=0
echo "$MILESTONE_BLOCK" | grep -q "COMPLETE milestone definition" && result=0 || result=1
assert "MILESTONE_BLOCK header contains 'COMPLETE milestone definition'" "$result"

result=0
echo "$MILESTONE_BLOCK" | grep -q "Acceptance Criteria are the predicates" && result=0 || result=1
assert "MILESTONE_BLOCK header references Acceptance Criteria predicates" "$result"

# =============================================================================
echo "--- Test: body is the raw file content (no truncation markers) ---"

# The actual milestone body text should appear verbatim between the delimiters,
# not trimmed or replaced by an extract.
result=0
echo "$MILESTONE_BLOCK" | grep -q "character-budgeted sliding window" && result=0 || result=1
assert "raw milestone prose appears in block" "$result"

# =============================================================================
echo "--- Test: milestone ID not in DAG (unknown milestone) ---"

MILESTONE_MODE=true
_CURRENT_MILESTONE=99
MILESTONE_BLOCK=""
result=0
set_focused_milestone_block && result=1 || result=0
assert "returns 1 when milestone ID 99 is not in the manifest" "$result"

result=0
[[ -z "$MILESTONE_BLOCK" ]] && result=0 || result=1
assert "MILESTONE_BLOCK unchanged for unknown milestone" "$result"

# =============================================================================
echo "--- Test: m-prefix fallback when dag_number_to_id is unavailable ---"
# Undefine dag_number_to_id so the function falls back to prepending "m".
# _CURRENT_MILESTONE=7 (numeric) → fallback produces id="m7" → m7 IS in the
# manifest (m7-fallback-test.md), so content is found and the function succeeds.

unset -f dag_number_to_id 2>/dev/null || true

MILESTONE_MODE=true
_CURRENT_MILESTONE=7
MILESTONE_BLOCK=""
result=0
set_focused_milestone_block && result=0 || result=1
assert "returns 0 via m-prefix fallback when dag_number_to_id is absent" "$result"

result=0
echo "$MILESTONE_BLOCK" | grep -q "Fallback Test" && result=0 || result=1
assert "MILESTONE_BLOCK contains fallback milestone title" "$result"

# Restore dag_number_to_id by re-sourcing the shim for subsequent tests.
# Re-sourcing resets the _DAG_* arrays (line 9 of milestone_dag.sh resets them),
# so load_manifest must follow to repopulate them.
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
load_manifest

# =============================================================================
echo "--- Test: already m-prefixed ID with dag_number_to_id unavailable ---"
# Edge case: _CURRENT_MILESTONE="m02" (has prefix), no dag_number_to_id.
# The m-prefix check does NOT prepend another "m" since id starts with "m".
# _read_milestone_file "m02" finds the file and returns content.

unset -f dag_number_to_id 2>/dev/null || true

MILESTONE_MODE=true
_CURRENT_MILESTONE=m02
MILESTONE_BLOCK=""
result=0
set_focused_milestone_block && result=0 || result=1
assert "returns 0 when _CURRENT_MILESTONE already has m-prefix (no dag_number_to_id)" "$result"

result=0
echo "$MILESTONE_BLOCK" | grep -q "Seeds Forward" && result=0 || result=1
assert "full content returned for already-prefixed ID" "$result"

# Restore
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
load_manifest

# =============================================================================
echo "--- m41 Test: dotted-id resolves via glob fallback (no manifest row) ---"
# Regression for the sdivi-rust dogfood run: a downstream project ships a
# milestone file `m49.2-*.md` whose dotted id ("49.2") has no row in
# MANIFEST.cfg. set_focused_milestone_block must still resolve the file
# via the MILESTONE_DIR glob fallback (m41 Goal 1) — otherwise the coder
# stage's old trip_commit_gate path would have hard-blocked the commit
# even though all downstream stages succeeded.

cat > "${MILESTONE_DIR_ABS}/m49.2-bold-label-fixture.md" << 'DOTTED_EOF'
# m49.2 — Downstream Bold-Label Fixture

This fixture mirrors the sdivi-rust milestone file shape: dotted id with
no manifest row, **Watch For:** bold-label sections (no H2 markers), and
a `**Seeds Forward:**` block at the end.

## Overview

A two-paragraph overview block. Authoring style varies across downstream
projects and `set_focused_milestone_block` must tolerate the shape.

## Acceptance Criteria

- Dotted-id resolves via glob when DAG has no matching row
- The block carries the full file body verbatim

**Watch For:**

- Do not weaken the genuine anti-rubber-stamp gates.
- The fix narrows ONE false-positive trip, not the hollow-run protections.

**Seeds Forward:**

- A `tekhton finalize --recover` subcommand for blocked-but-green runs.
DOTTED_EOF

MILESTONE_MODE=true
_CURRENT_MILESTONE=49.2
MILESTONE_BLOCK=""
result=0
set_focused_milestone_block && result=0 || result=1
assert "[m41] returns 0 for dotted id 49.2 (file on disk, no manifest row)" "$result"

result=0
[[ -n "$MILESTONE_BLOCK" ]] && result=0 || result=1
assert "[m41] MILESTONE_BLOCK is non-empty for dotted id" "$result"

result=0
echo "$MILESTONE_BLOCK" | grep -q "Downstream Bold-Label Fixture" && result=0 || result=1
assert "[m41] MILESTONE_BLOCK carries the file body" "$result"

# The bold-label sections are part of the FULL content dump from
# set_focused_milestone_block, so they must appear verbatim regardless of
# whether the file uses ## or **...:** markup.
result=0
echo "$MILESTONE_BLOCK" | grep -q "\*\*Watch For:\*\*" && result=0 || result=1
assert "[m41] MILESTONE_BLOCK includes **Watch For:** bold-label section" "$result"

result=0
echo "$MILESTONE_BLOCK" | grep -q "\*\*Seeds Forward:\*\*" && result=0 || result=1
assert "[m41] MILESTONE_BLOCK includes **Seeds Forward:** bold-label section" "$result"

# Header banner names the resolved id with the m-prefix.
result=0
echo "$MILESTONE_BLOCK" | grep -q "m49\\.2" && result=0 || result=1
assert "[m41] MILESTONE_BLOCK header names the resolved dotted id" "$result"

# =============================================================================
echo "--- m41 Test: _extract_first_paragraph_and_acceptance tolerates markup ---"
# The truncation-path extractor (used by build_milestone_window when the
# active milestone overflows the budget) must match both `## Acceptance
# Criteria` (H2) and `**Acceptance Criteria:**` (bold-label), AND keep
# Watch For / Seeds Forward H2 sections rolled into the result so they
# survive the truncation hop.

# H2 markup fixture
H2_FIXTURE="# Top-line title

Intro paragraph.

## Acceptance Criteria

- crit one
- crit two

## Watch For

- watch one

## Seeds Forward

- seed one"

result=0
output=$(_extract_first_paragraph_and_acceptance "$H2_FIXTURE")
echo "$output" | grep -q "crit one" && result=0 || result=1
assert "[m41] extractor matches ## Acceptance Criteria H2 marker" "$result"

result=0
echo "$output" | grep -q "watch one" && result=0 || result=1
assert "[m41] extractor keeps ## Watch For section through truncation" "$result"

result=0
echo "$output" | grep -q "seed one" && result=0 || result=1
assert "[m41] extractor keeps ## Seeds Forward section through truncation" "$result"

# Bold-label markup fixture
BOLD_FIXTURE="# Top-line title

Intro paragraph.

**Acceptance Criteria:**

- crit alpha
- crit beta

**Watch For:**

- watch alpha"

result=0
output=$(_extract_first_paragraph_and_acceptance "$BOLD_FIXTURE")
echo "$output" | grep -q "crit alpha" && result=0 || result=1
assert "[m41] extractor matches **Acceptance Criteria:** bold-label" "$result"

# Cleanup the dotted fixture so subsequent test runs are reproducible.
rm -f "${MILESTONE_DIR_ABS}/m49.2-bold-label-fixture.md"

# =============================================================================
echo "--- m41 Coverage Gap: stale DAG file entry falls through to glob ---"
# Reviewer gap: no test covered the path where the DAG manifest has a
# non-empty `file` entry for an ID but the file doesn't exist on disk —
# causing `_read_milestone_file` to skip the DAG-known path and fall through
# to the glob fallback.
#
# Setup: m10 is in the manifest with file=m10-stale.md (a name that does
# NOT exist on disk). A file named m10-current.md DOES exist. The function
# must fall through past the missing DAG-known path and find the file via
# the `${id}-*.md` glob.

STALE_DAG_ID="m10"
STALE_FILE="m10-stale.md"           # referenced by manifest, NOT on disk
CURRENT_FILE="m10-current.md"       # on disk, matches glob m10-*.md

# Create the on-disk file with unique content.
cat > "${MILESTONE_DIR_ABS}/${CURRENT_FILE}" << 'STALE_EOF'
# m10 — Stale DAG Path Test Fixture

This file exists on disk under a different name than the manifest records.
The manifest says `m10-stale.md`; that file is absent. The glob fallback
inside `_read_milestone_file` must find this file instead.

## Acceptance Criteria

- Stale DAG entry causes fallback to glob without error
- Glob-discovered content is returned verbatim
STALE_EOF

# Register m10 in the _DAG_* in-memory arrays with the stale file reference.
# We manipulate the arrays directly rather than rewriting the manifest to
# keep the test surgical (only the new ID is added; the rest is unchanged).
_stale_idx=${#_DAG_IDS[@]}
_DAG_IDS+=("$STALE_DAG_ID")
_DAG_TITLES+=("Stale File Path Test")
_DAG_STATUSES+=("pending")
_DAG_DEPS+=("")
_DAG_FILES+=("$STALE_FILE")
_DAG_GROUPS+=("test")
_DAG_IDX["$STALE_DAG_ID"]=$_stale_idx

# Verify setup: dag_get_file returns the stale (absent) filename.
result=0
got_file=$(dag_get_file "$STALE_DAG_ID" 2>/dev/null || true)
[[ "$got_file" == "$STALE_FILE" ]] && result=0 || result=1
assert "[m41-stale] setup: dag_get_file returns the stale filename" "$result"

# The stale file must NOT be on disk for the test to be meaningful.
result=0
[[ ! -f "${MILESTONE_DIR_ABS}/${STALE_FILE}" ]] && result=0 || result=1
assert "[m41-stale] setup: stale file is absent from disk" "$result"

# The glob-target file MUST be on disk.
result=0
[[ -f "${MILESTONE_DIR_ABS}/${CURRENT_FILE}" ]] && result=0 || result=1
assert "[m41-stale] setup: on-disk glob-target file exists" "$result"

# Primary test: _read_milestone_file must return non-empty content
# even though the DAG-known path is absent on disk.
result=0
content=$(_read_milestone_file "$STALE_DAG_ID" 2>/dev/null)
[[ -n "$content" ]] && result=0 || result=1
assert "[m41-stale] _read_milestone_file returns content when DAG path is stale" "$result"

# The content must come from the on-disk glob file, not the absent stale path.
result=0
echo "$content" | grep -q "Stale DAG Path Test Fixture" && result=0 || result=1
assert "[m41-stale] returned content is from the glob-discovered file" "$result"

result=0
echo "$content" | grep -q "Glob-discovered content is returned verbatim" && result=0 || result=1
assert "[m41-stale] full acceptance-criteria prose appears in returned content" "$result"

# set_focused_milestone_block must also succeed when the DAG path is stale.
MILESTONE_MODE=true
_CURRENT_MILESTONE=10    # numeric; dag_number_to_id resolves to m10
MILESTONE_BLOCK=""
result=0
set_focused_milestone_block && result=0 || result=1
assert "[m41-stale] set_focused_milestone_block succeeds with stale DAG file entry" "$result"

result=0
[[ -n "$MILESTONE_BLOCK" ]] && result=0 || result=1
assert "[m41-stale] MILESTONE_BLOCK is non-empty via stale-DAG → glob path" "$result"

result=0
echo "$MILESTONE_BLOCK" | grep -q "Stale DAG Path Test Fixture" && result=0 || result=1
assert "[m41-stale] MILESTONE_BLOCK carries the glob-found content" "$result"

# Cleanup fixture.
rm -f "${MILESTONE_DIR_ABS}/${CURRENT_FILE}"
unset _stale_idx STALE_DAG_ID STALE_FILE CURRENT_FILE got_file content

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
