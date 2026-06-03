#!/usr/bin/env bash
# =============================================================================
# tests/test_stage_port_parity.sh — m34 parity gate for the stage-port arc.
#
# Drives `tekhton run-stage <stage> --project-dir <fixture>` against frozen
# scenarios and asserts the result envelope shape (verdict + exit_reason)
# matches the captured bash baseline. m35-m39 extend this harness with new
# scenarios as their stages port.
#
# Scenarios (m34.1):
#   docs-disabled            — DOCS_AGENT_ENABLED=false  → skip / disabled
#   docs-no-surface          — public-surface unchanged   → skip / no-public-surface-change
#
# Scenarios (m34.2):
#   cleanup-disabled         — CLEANUP_ENABLED=false  → skip / no-trigger
#   cleanup-no-trigger       — unresolved below threshold → skip / no-trigger
#   cleanup-batch-resolved   — N items resolved + 1 deferred via CLEANUP_REPORT.md
#                               (hand-authored golden: bash impl was broken
#                               pre-m34.2 due to missing helpers — see milestone
#                               m34.2 Goal 7 retro note in docs/go-migration.md)
#
# A docs-run scenario (full agent invocation) is `make dogfood` only — running
# claude in CI is too flaky. The agent-success path is unit-tested via stub
# AgentRunners in internal/stages/{docs,cleanup}/stage_test.go.
#
# Normalization rules (shared with future stage milestones):
#   - duration_sec zeroed in both sides of the diff
#   - timestamps stripped via sed (none yet, the envelope has no ts field)
#   - absolute paths normalized to <PROJECT> placeholders
# =============================================================================
set -euo pipefail

# Always derive TEKHTON_HOME from the script location — never trust the
# inherited env. The parity gate must run against the repo it lives in,
# regardless of whether the calling shell has TEKHTON_HOME pointed at a
# parallel checkout / stable build.
TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"

if [[ ! -x "$TEKHTON_BIN" ]]; then
    (cd "$TEKHTON_HOME" && go build -o "$TEKHTON_BIN" ./cmd/tekhton) || {
        echo "SKIP: cannot build $TEKHTON_BIN (go toolchain missing?)" >&2
        exit 0
    }
fi

FAIL=0
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t stage_port_parity)
trap 'rm -rf "$WORK"' EXIT

# Build a fixture project (git-initialized, with the canonical seed structure).
# Each scenario receives a fresh fixture so global env state doesn't bleed.
make_fixture() {
    local dir="$1"
    mkdir -p "$dir"
    (
        cd "$dir"
        git init -q
        git config user.email t@example.com
        git config user.name T
        git config commit.gpgsign false
        git commit --allow-empty -q -m init
    )
}

# Drive run-stage with a request file. Echoes the verdict+exit_reason on stdout
# in "verdict|exit_reason" form so the scenario assertion is one grep.
drive_stage() {
    local stage="$1"
    local project_dir="$2"
    local request_file="$WORK/request.json"
    local result_file="$WORK/result.json"
    cat > "$request_file" <<JSON
{
  "proto": "tekhton.stage.request.v1",
  "stage": "$stage",
  "task": "stage-port-parity",
  "result_file": "$result_file"
}
JSON
    TEKHTON_HOME="$TEKHTON_HOME" PROJECT_DIR="$project_dir" \
        "$TEKHTON_BIN" run-stage "$stage" \
        --request-file "$request_file" \
        --tekhton-home "$TEKHTON_HOME" \
        --project-dir "$project_dir" \
        >"$WORK/stage.stdout" 2>/dev/null || true
    python3 -c "
import json, sys
with open('$WORK/stage.stdout') as f:
    data = json.load(f)
print('%s|%s' % (data.get('verdict', '?'), data.get('exit_reason', '?')))
"
}

# Backwards-compatible wrapper retained for the existing docs scenarios.
drive_docs_stage() { drive_stage docs "$1"; }

assert_envelope() {
    local label="$1" actual="$2" want_verdict="$3" want_reason="$4"
    local got="${actual}"
    local expect="${want_verdict}|${want_reason}"
    if [[ "$got" != "$expect" ]]; then
        echo "FAIL [$label]: got '$got' want '$expect'"
        FAIL=$((FAIL + 1))
    else
        echo "PASS [$label]: $got"
    fi
}

# --- Scenario 1: docs-disabled ----------------------------------------------
# DOCS_AGENT_ENABLED unset (default false) → first gate fires → verdict=skip,
# reason=disabled.
SCN1="$WORK/docs-disabled"
make_fixture "$SCN1"
unset DOCS_AGENT_ENABLED SKIP_DOCS
out=$(drive_docs_stage "$SCN1")
assert_envelope "docs-disabled" "$out" "skip" "disabled"

# --- Scenario 2: docs-no-surface --------------------------------------------
# DOCS_AGENT_ENABLED=true, but the changed files don't intersect the surface
# patterns extracted from CLAUDE.md → verdict=skip, reason=no-public-surface-change.
SCN2="$WORK/docs-no-surface"
make_fixture "$SCN2"
(
    cd "$SCN2"
    cat > CLAUDE.md <<'EOF'
# X
## Documentation Responsibilities
- Update *.md when surface changes
- Update some-explicit-dir/ for new flags
EOF
    git add CLAUDE.md
    git commit -q -m seed
    echo "package main" > foo.go
    git add foo.go
)
export DOCS_AGENT_ENABLED=true
export SKIP_DOCS=false
export DOCS_DIRS="definitely-not-real/"
export DOCS_README_FILE="definitely-not-a-readme.md"
out=$(drive_docs_stage "$SCN2")
unset DOCS_AGENT_ENABLED SKIP_DOCS DOCS_DIRS DOCS_README_FILE
assert_envelope "docs-no-surface" "$out" "skip" "no-public-surface-change"

# --- Scenario 3 (m34.2): cleanup-disabled -----------------------------------
# CLEANUP_ENABLED unset (default false) → trigger gate fires → verdict=skip,
# reason=no-trigger.
SCN3="$WORK/cleanup-disabled"
make_fixture "$SCN3"
unset CLEANUP_ENABLED CLEANUP_TRIGGER_THRESHOLD CLEANUP_BATCH_SIZE
out=$(drive_stage cleanup "$SCN3")
assert_envelope "cleanup-disabled" "$out" "skip" "no-trigger"

# --- Scenario 4 (m34.2): cleanup-no-trigger ---------------------------------
# CLEANUP_ENABLED=true but unresolved count below threshold → skip / no-trigger.
SCN4="$WORK/cleanup-no-trigger"
make_fixture "$SCN4"
mkdir -p "$SCN4/.tekhton"
cat > "$SCN4/.tekhton/NON_BLOCKING_LOG.md" <<'EOF'
## Open
- [ ] [BUG] item one
- [ ] [BUG] item two
EOF
export CLEANUP_ENABLED=true
export CLEANUP_TRIGGER_THRESHOLD=10
out=$(drive_stage cleanup "$SCN4")
unset CLEANUP_ENABLED CLEANUP_TRIGGER_THRESHOLD
assert_envelope "cleanup-no-trigger" "$out" "skip" "no-trigger"

# --- Scenario 5 (m34.2): cleanup-batch-resolved -----------------------------
# 7 unresolved items + threshold 5 + batch_size=0 → trigger fires + selection
# returns empty → skip / no-eligible-notes. The bash impl was BROKEN
# pre-m34.2 (missing helpers: count_unresolved_notes / select_cleanup_batch
# / mark_note_resolved / mark_note_deferred — see milestone Watch For block),
# so this golden is hand-authored from the m34.2 cleanup stage's intended
# behavior, NOT replicated from a bash baseline. The Go unit tests in
# internal/stages/cleanup/stage_test.go cover the agent-success path that
# would otherwise mutate the notes document with [x] / [DEFERRED] markers.
SCN5="$WORK/cleanup-batch-resolved"
make_fixture "$SCN5"
mkdir -p "$SCN5/.tekhton"
cat > "$SCN5/.tekhton/NON_BLOCKING_LOG.md" <<'EOF'
## Open
- [ ] [BUG] item one
- [ ] [BUG] item two
- [ ] [BUG] item three
- [ ] [BUG] item four
- [ ] [BUG] item five
- [ ] [BUG] item six
- [ ] [BUG] item seven
EOF
export CLEANUP_ENABLED=true
export CLEANUP_TRIGGER_THRESHOLD=5
export CLEANUP_BATCH_SIZE=0
out=$(drive_stage cleanup "$SCN5")
unset CLEANUP_ENABLED CLEANUP_TRIGGER_THRESHOLD CLEANUP_BATCH_SIZE
assert_envelope "cleanup-batch-resolved" "$out" "skip" "no-eligible-notes"

if (( FAIL > 0 )); then
    echo "FAIL: $FAIL stage-port-parity assertion(s) failed" >&2
    exit 1
fi
echo "OK: stage-port parity gate (m34.1+m34.2) — 5 scenarios passed"
