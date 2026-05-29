#!/usr/bin/env bash
# =============================================================================
# Test: lib/mcp.sh — Serena template substitution + stale-config migration.
#
# Black-box coverage of _resolve_mcp_config across three states:
#   1. Fresh-generation     — no pre-existing config; substitutes template.
#   2. No-overwrite-correct — pre-existing correct config; unchanged.
#   3. Regenerate-when-stale — pre-existing stale config; backed up + replaced.
#
# Sourced fixtures: tests/fixtures/serena_configs/{stale,correct}.json
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="${TEKHTON_HOME}/tests/fixtures/serena_configs"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

# shellcheck source=lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=lib/mcp.sh
source "${TEKHTON_HOME}/lib/mcp.sh"

PASS=0
FAIL=0

assert_exit_code() {
    local desc="$1" expected="$2" result="$3"
    if [ "$expected" -eq "$result" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected exit code $expected, got $result)"
        FAIL=$((FAIL + 1))
    fi
}

assert_true() {
    local desc="$1" cond="$2"
    if [ "$cond" = "true" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# Stub Serena resolver state so _resolve_mcp_config has the values it needs
# to render the template. The actual binary is not invoked from this test.
mkdir -p "${TMPDIR}/.claude/serena/.venv/bin"
touch "${TMPDIR}/.claude/serena/.venv/bin/serena"
chmod +x "${TMPDIR}/.claude/serena/.venv/bin/serena"

setup_state() {
    _MCP_CONFIG_PATH=""
    _SERENA_DIR="${TMPDIR}/.claude/serena"
    _SERENA_PYTHON="${TMPDIR}/.claude/serena/.venv/bin/python"
    _SERENA_BIN="${TMPDIR}/.claude/serena/.venv/bin/serena"
    SERENA_CONFIG_PATH=""
    SERENA_LANGUAGE_SERVERS="auto"
    export SERENA_CONFIG_PATH SERENA_LANGUAGE_SERVERS
    # Remove any backup files left from a prior scenario in the same run.
    rm -f "${TMPDIR}/.claude/serena_mcp_config.json"
    rm -f "${TMPDIR}/.claude"/serena_mcp_config.json.bak.* 2>/dev/null || true
}

count_backups() {
    # shellcheck disable=SC2010  # ls + grep is fine here — we control the path
    find "${TMPDIR}/.claude" -maxdepth 1 -name 'serena_mcp_config.json.bak.*' -print 2>/dev/null | wc -l
}

# =============================================================================
echo "=== Test: Fresh-generation — no pre-existing config ==="

setup_state
_resolve_mcp_config
result=$?
assert_exit_code "_resolve_mcp_config returns 0 on fresh generation" 0 "$result"

target="${TMPDIR}/.claude/serena_mcp_config.json"
if [[ -f "$target" ]]; then
    cond=true
else
    cond=false
fi
assert_true "generated config file exists" "$cond"

# Validate JSON shape via python: command matches stub, args[0] == start-mcp-server,
# args contains --project pointing at PROJECT_DIR.
if python3 - "$target" "${_SERENA_BIN}" "${PROJECT_DIR}" <<'PY' >/dev/null 2>&1
import json, sys
path, expected_bin, expected_project = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    cfg = json.load(fh)
srv = cfg["mcpServers"]["serena"]
assert srv["command"] == expected_bin, srv["command"]
args = srv["args"]
assert args[0] == "start-mcp-server", args
assert "--project" in args, args
proj_idx = args.index("--project")
assert args[proj_idx + 1] == expected_project, args
PY
then
    cond=true
else
    cond=false
fi
assert_true "generated config has correct command/args shape" "$cond"

# =============================================================================
echo "=== Test: No-overwrite-when-correct — pre-existing correct config ==="

setup_state
# Copy the correct-shape fixture into place; substitute placeholder paths so
# downstream JSON parsing is still valid (the resolver does not inspect content).
cp "${FIXTURES}/correct.json" "$target"
before_md5=$(md5sum "$target" | awk '{print $1}')
before_backups=$(count_backups)

_resolve_mcp_config
result=$?
assert_exit_code "_resolve_mcp_config returns 0 for correct config" 0 "$result"

after_md5=$(md5sum "$target" | awk '{print $1}')
after_backups=$(count_backups)

if [[ "$before_md5" == "$after_md5" ]]; then
    cond=true
else
    cond=false
fi
assert_true "correct config left byte-identical" "$cond"

if [[ "$before_backups" -eq "$after_backups" ]]; then
    cond=true
else
    cond=false
fi
assert_true "no backup file created for correct config" "$cond"

# =============================================================================
echo "=== Test: Regenerate-when-stale — pre-existing stale config ==="

setup_state
cp "${FIXTURES}/stale.json" "$target"
stale_md5=$(md5sum "$target" | awk '{print $1}')

_resolve_mcp_config
result=$?
assert_exit_code "_resolve_mcp_config returns 0 for stale config" 0 "$result"

new_md5=$(md5sum "$target" | awk '{print $1}')
if [[ "$new_md5" != "$stale_md5" ]]; then
    cond=true
else
    cond=false
fi
assert_true "stale config replaced (md5 differs)" "$cond"

# Exactly one backup file should exist, containing the original stale bytes.
backups=$(find "${TMPDIR}/.claude" -maxdepth 1 -name 'serena_mcp_config.json.bak.*' -print)
backup_count=$(echo "$backups" | grep -c '\.bak\.' || true)
if [[ "$backup_count" -eq 1 ]]; then
    cond=true
else
    cond=false
fi
assert_true "exactly one .bak.* file present" "$cond"

if [[ -n "$backups" ]] && [[ "$(md5sum "$backups" | awk '{print $1}')" == "$stale_md5" ]]; then
    cond=true
else
    cond=false
fi
assert_true "backup file contains the original stale bytes" "$cond"

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
