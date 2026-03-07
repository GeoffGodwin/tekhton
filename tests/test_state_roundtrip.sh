#!/usr/bin/env bash
# Test: Pipeline state write and read round-trip
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Set up state prerequisites
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
mkdir -p "${TMPDIR}/.claude"

source "${TEKHTON_HOME}/lib/state.sh"

# Write state
write_pipeline_state "review" "blockers_remain" "--start-at review" "Fix login bug" "2 complex blockers"

# Verify file was created
[ -f "$PIPELINE_STATE_FILE" ] || { echo "State file not created"; exit 1; }

# Verify contents
grep -q "review" "$PIPELINE_STATE_FILE" || { echo "Stage not in state file"; exit 1; }
grep -q "blockers_remain" "$PIPELINE_STATE_FILE" || { echo "Reason not in state file"; exit 1; }
grep -q "Fix login bug" "$PIPELINE_STATE_FILE" || { echo "Task not in state file"; exit 1; }
grep -q "\-\-start-at review" "$PIPELINE_STATE_FILE" || { echo "Resume flag not in state file"; exit 1; }

# Clear state
clear_pipeline_state

# Verify file was removed
[ ! -f "$PIPELINE_STATE_FILE" ] || { echo "State file not cleared"; exit 1; }

echo "State round-trip test passed"
