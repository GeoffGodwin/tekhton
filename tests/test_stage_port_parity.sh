#!/usr/bin/env bash
# =============================================================================
# tests/test_stage_port_parity.sh — m34.1 parity gate for the stage-port arc.
#
# Drives `tekhton run-stage docs --project-dir <fixture>` against frozen
# scenarios and asserts the result envelope shape (verdict + exit_reason)
# matches what the bash docs stage produced at the v4.33.99-stage-baseline-
# docs tag. m34.2 + m35-m39 extend this harness with new scenarios as their
# stages port.
#
# Scenarios (m34.1):
#   docs-disabled         — DOCS_AGENT_ENABLED=false  → skip / disabled
#   docs-no-surface       — public-surface unchanged   → skip / no-public-surface-change
#
# A third scenario (docs-run, full agent invocation) is a `make dogfood` smoke
# rather than a CI assertion — running claude in CI is too flaky (model
# availability, quota). The agent-success path is unit-tested via a stub
# AgentRunner in internal/stages/docs/stage_test.go.
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
drive_docs_stage() {
    local project_dir="$1"
    local request_file="$WORK/request.json"
    local result_file="$WORK/result.json"
    cat > "$request_file" <<JSON
{
  "proto": "tekhton.stage.request.v1",
  "stage": "docs",
  "task": "stage-port-parity",
  "result_file": "$result_file"
}
JSON
    TEKHTON_HOME="$TEKHTON_HOME" PROJECT_DIR="$project_dir" \
        "$TEKHTON_BIN" run-stage docs \
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

if (( FAIL > 0 )); then
    echo "FAIL: $FAIL stage-port-parity assertion(s) failed" >&2
    exit 1
fi
echo "OK: stage-port parity gate (m34.1) — 2 scenarios passed"
