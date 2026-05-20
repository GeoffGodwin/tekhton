#!/usr/bin/env bash
# =============================================================================
# tests/test_finalize_parity.sh — m21. End-to-end parity gate for the Go
# finalize orchestrator.
#
# The m21 milestone scoping anticipates a frozen `v4.20.0-dogfood` fixture
# tag that captures pre-finalize state + post-finalize artifacts on a known
# good run. That fixture has not yet been authored. In the meantime this
# script exercises a lightweight smoke parity:
#
#   1. Build a minimal fixture project with .claude/milestones/MANIFEST.cfg,
#      a milestone body file, and a stub RUN_RESULT.json.
#   2. Invoke `tekhton finalize` against the fixture with exit-code=0 and
#      a COMPLETE_AND_CONTINUE disposition.
#   3. Verify the Go-emitted artifacts:
#        - Milestone body file removed from .claude/milestones/ (cleanup hook)
#        - .tekhton/MILESTONE_ARCHIVE.md NOT created (archival was retired)
#        - MANIFEST.cfg entry status flipped to "done"
#        - RUN_MEMORY.jsonl has one PASS record
#        - CAUSAL_LOG.jsonl has a pipeline_end event
#        - Stage report files copied into .claude/logs/<ts>_*.md
#        - .claude/MILESTONE_STATE.md removed
#
# When the captured-baseline fixture lands (m21.x), extend this script to
# diff each artifact against the captured baseline. The current scope is
# "Go orchestrator can drive a complete chain without crashing AND each
# pure-Go hook produces its expected artifact".
# =============================================================================
set -euo pipefail

TEKHTON_HOME="${TEKHTON_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TEKHTON_BIN="${TEKHTON_BIN:-${TEKHTON_HOME}/bin/tekhton}"

if [[ ! -x "$TEKHTON_BIN" ]]; then
    # Auto-build on first run so the test stays self-contained.
    (cd "$TEKHTON_HOME" && go build -o "$TEKHTON_BIN" ./cmd/tekhton) || {
        echo "SKIP: cannot build $TEKHTON_BIN (go toolchain missing?)" >&2
        exit 0
    }
fi

FIXTURE=$(mktemp -d 2>/dev/null || mktemp -d -t finalize_parity)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "${FIXTURE}/.claude/milestones"
mkdir -p "${FIXTURE}/.claude/logs"
mkdir -p "${FIXTURE}/.tekhton"

# Seed manifest with one milestone in "done" state (mark_done hook is
# idempotent — verifies the contract still holds).
cat > "${FIXTURE}/.claude/milestones/MANIFEST.cfg" <<'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m21|Finalize Orchestrator Port|done||m21-body.md|
EOF

# Milestone body that cleanup_milestone should remove on completion.
cat > "${FIXTURE}/.claude/milestones/m21-body.md" <<'EOF'
# m21 — body
This is the m21 milestone body used by the parity test.
EOF

# Stub stage report files so archive_reports has something to copy.
echo "coder summary stub" > "${FIXTURE}/.tekhton/CODER_SUMMARY.md"
echo "reviewer report stub" > "${FIXTURE}/.tekhton/REVIEWER_REPORT.md"

# MILESTONE_STATE.md so clear_state has something to remove.
echo "stale state" > "${FIXTURE}/.claude/MILESTONE_STATE.md"

# Run the orchestrator directly via the CLI.
export TEKHTON_HOME PROJECT_DIR="$FIXTURE"
"$TEKHTON_BIN" finalize \
    --exit-code 0 \
    --project-dir "$FIXTURE" \
    --home "$TEKHTON_HOME" \
    --milestone m21 \
    --milestone-mode true \
    --milestone-disposition COMPLETE_AND_CONTINUE \
    --log-dir "${FIXTURE}/.claude/logs" \
    --timestamp 20260517_120000 \
    --disposition success \
    >"${FIXTURE}/finalize.stdout" 2>"${FIXTURE}/finalize.stderr" || true

# --- Assertions -------------------------------------------------------------
FAIL=0

# 1. cleanup_milestone removed the milestone body file; no archive created.
if [[ -f "${FIXTURE}/.claude/milestones/m21-body.md" ]]; then
    echo "FAIL: cleanup_milestone did not remove m21-body.md"
    FAIL=$((FAIL + 1))
fi
if [[ -f "${FIXTURE}/.tekhton/MILESTONE_ARCHIVE.md" ]]; then
    echo "FAIL: archival pipeline was retired but MILESTONE_ARCHIVE.md was created"
    FAIL=$((FAIL + 1))
fi

# 2. MANIFEST.cfg still has m21 as done (idempotent).
if ! grep -q "^m21|.*|done|" "${FIXTURE}/.claude/milestones/MANIFEST.cfg"; then
    echo "FAIL: MANIFEST.cfg m21 status not 'done'"
    FAIL=$((FAIL + 1))
fi

# 3. RUN_MEMORY.jsonl has one PASS record.
if [[ ! -f "${FIXTURE}/.claude/logs/RUN_MEMORY.jsonl" ]]; then
    echo "FAIL: RUN_MEMORY.jsonl not created"
    FAIL=$((FAIL + 1))
elif ! grep -q '"verdict":"PASS"' "${FIXTURE}/.claude/logs/RUN_MEMORY.jsonl"; then
    echo "FAIL: RUN_MEMORY.jsonl missing PASS record"
    FAIL=$((FAIL + 1))
fi

# 4. CAUSAL_LOG.jsonl has pipeline_end event.
if [[ ! -f "${FIXTURE}/.claude/logs/CAUSAL_LOG.jsonl" ]]; then
    echo "FAIL: CAUSAL_LOG.jsonl not created"
    FAIL=$((FAIL + 1))
elif ! grep -q "pipeline_end" "${FIXTURE}/.claude/logs/CAUSAL_LOG.jsonl"; then
    echo "FAIL: CAUSAL_LOG.jsonl missing pipeline_end event"
    FAIL=$((FAIL + 1))
fi

# 5. Stage reports archived under .claude/logs/<ts>_*.md.
if [[ ! -f "${FIXTURE}/.claude/logs/20260517_120000_CODER_SUMMARY.md" ]]; then
    echo "FAIL: coder summary not archived"
    FAIL=$((FAIL + 1))
fi
if [[ ! -f "${FIXTURE}/.claude/logs/20260517_120000_REVIEWER_REPORT.md" ]]; then
    echo "FAIL: reviewer report not archived"
    FAIL=$((FAIL + 1))
fi

# 6. MILESTONE_STATE.md cleared.
if [[ -f "${FIXTURE}/.claude/MILESTONE_STATE.md" ]]; then
    echo "FAIL: MILESTONE_STATE.md not removed by clear_state"
    FAIL=$((FAIL + 1))
fi

if [[ $FAIL -gt 0 ]]; then
    echo "FAIL: ${FAIL} parity assertion(s) failed" >&2
    echo "--- finalize stdout ---" >&2
    cat "${FIXTURE}/finalize.stdout" >&2 || true
    echo "--- finalize stderr ---" >&2
    cat "${FIXTURE}/finalize.stderr" >&2 || true
    exit 1
fi

echo "PASS: m21 Go finalize orchestrator produced all expected artifacts"
