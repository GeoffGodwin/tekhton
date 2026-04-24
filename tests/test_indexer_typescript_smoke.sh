#!/usr/bin/env bash
# =============================================================================
# Test: TypeScript-only project indexer smoke test (M122)
#
# Verifies:
#   Positive path — a project of only .ts files produces a non-empty repo map.
#   Negative path — when repo_map.py fatally exits, the [indexer] warning
#     includes the stderr tail so users can self-diagnose.
#
# Skips cleanly if python / tree_sitter_typescript / the indexer venv is
# unavailable.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

log()  { :; }
log_verbose() { :; }
warn() { echo "[warn] $*" >&2; }
error() { echo "[error] $*" >&2; }

# --- Skip gate: venv + tree_sitter_typescript must be present ----------------
VENV_PY="${TEKHTON_HOME}/.claude/indexer-venv/bin/python"
if [[ ! -x "$VENV_PY" ]]; then
    echo "SKIP: indexer venv not found at $VENV_PY"
    exit 0
fi
if ! "$VENV_PY" -c "import tree_sitter_typescript" 2>/dev/null; then
    echo "SKIP: tree_sitter_typescript not installed in indexer venv"
    exit 0
fi

# --- Build the fake TS-only project ------------------------------------------
PROJECT_DIR="$TEST_TMPDIR/ts_project"
mkdir -p "$PROJECT_DIR/src"
cat > "$PROJECT_DIR/src/app.ts" <<'TS'
export function main(): void {
  console.log("hello");
}
TS
cat > "$PROJECT_DIR/src/util.ts" <<'TS'
export function format(value: string): string {
  return value.trim();
}
TS
cat > "$PROJECT_DIR/src/types.ts" <<'TS'
export interface User { id: string; name: string; }
export type UserId = string;
TS
cat > "$PROJECT_DIR/.gitignore" <<'EOF'
node_modules/
dist/
EOF

(
    cd "$PROJECT_DIR"
    git init -q 2>/dev/null
    git add -A
    git -c user.email=t@t -c user.name=t commit -q -m init
)

# --- Source the indexer under test -------------------------------------------
export PROJECT_DIR
export REPO_MAP_ENABLED=true
export REPO_MAP_VENV_DIR=".claude/indexer-venv"
export REPO_MAP_CACHE_DIR=".claude/index"
# Force auto-detection — parent env may set this to something that excludes TS.
export REPO_MAP_LANGUAGES="auto"

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_helpers.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_cache.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_history.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer.sh"

# Point the venv lookup at the real tekhton venv — our fake project does
# not ship one. Defined after sourcing so it overrides the real helper.
_indexer_find_venv_python() { echo "$VENV_PY"; }
# shellcheck disable=SC2034  # consumed by run_repo_map from the sourced indexer.sh
INDEXER_AVAILABLE=true

# =============================================================================
echo "=== Positive path: TS-only project produces a repo map ==="
REPO_MAP_CONTENT=""
run_repo_map "format user data" 2048 true
rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "run_repo_map exit 0"
else
    fail "run_repo_map exit $rc (expected 0)"
fi
if [[ -n "${REPO_MAP_CONTENT:-}" ]]; then
    pass "REPO_MAP_CONTENT is non-empty"
else
    fail "REPO_MAP_CONTENT is empty (expected non-empty)"
fi
if echo "$REPO_MAP_CONTENT" | grep -q "^## src/"; then
    pass "repo map contains src/ file heading"
else
    fail "repo map missing expected src/ file heading"
fi

# =============================================================================
echo "=== Negative path: fatal exit surfaces stderr tail in warning ==="

# Move to a fresh project dir so the cache from the positive run doesn't
# hide the grammar failure below.
PROJECT_DIR="$TEST_TMPDIR/ts_project_neg"
mkdir -p "$PROJECT_DIR/src"
cat > "$PROJECT_DIR/src/a.ts" <<'TS'
export function a(): void {}
TS
(
    cd "$PROJECT_DIR"
    git init -q 2>/dev/null
    git add -A
    git -c user.email=t@t -c user.name=t commit -q -m init
)
export PROJECT_DIR

# Replace repo_map.py with a stub that exits 2 and prints the same
# "no files could be parsed" warning the real tool emits when no grammar is
# available. This triggers the Goal 2 stderr-tail branch without depending on
# the installed grammars' behavior.
FAKE_HOME="$TEST_TMPDIR/fake_home"
mkdir -p "$FAKE_HOME/tools"
cat > "$FAKE_HOME/tools/repo_map.py" <<'PY'
import sys
print("Warning: no files could be parsed", file=sys.stderr)
sys.exit(2)
PY
export TEKHTON_HOME="$FAKE_HOME"

REPO_MAP_CONTENT=""
rc=0
warn_output=$(run_repo_map "diagnostic test" 2048 true 2>&1) || rc=$?
if [[ "$rc" -ne 0 ]]; then
    pass "run_repo_map returns non-zero on fatal exit"
else
    fail "run_repo_map should return non-zero on fatal exit"
fi
if echo "$warn_output" | grep -q "falling back to no repo map"; then
    pass "warning includes fallback line"
else
    fail "warning missing fallback line"
fi
if echo "$warn_output" | grep -q "Last lines of repo_map.py stderr"; then
    pass "warning includes stderr-tail header (Goal 2 diagnostic)"
else
    fail "warning missing stderr-tail header — users cannot self-diagnose"
fi
if echo "$warn_output" | grep -q "no files could be parsed"; then
    pass "stderr tail surfaces Python tool's actionable error"
else
    fail "stderr tail missing Python-side error"
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
