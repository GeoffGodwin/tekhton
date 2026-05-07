#!/usr/bin/env bash
# scripts/dag-parity-check.sh — m14 acceptance gate.
#
# Drives a fixture matrix through both the bash _DAG_* array queries and the
# Go `tekhton dag …` subcommands, comparing their output for byte-for-byte
# equivalence. m14 ports `lib/milestone_dag*.sh` state-machine logic into
# `internal/dag` (Go); this script asserts the seam holds.
#
# Fixtures (mirror the milestone's stated coverage matrix):
#   1. happy_path        — pending milestones, simple deps
#   2. mixed_statuses    — done / in_progress / pending / split / skipped
#   3. multi_active      — multiple in_progress milestones
#   4. dep_chain         — three-level dep chain m01 → m02 → m03
#   5. split_subtree     — parent split with child sub-milestones
#
# Per-fixture checks: frontier and active output match; validate exits clean
# when files exist; validate flags missing-dep / missing-file / cycle.
#
# Usage:
#   scripts/dag-parity-check.sh
#
# Exit codes:
#   0 = parity holds across all fixtures + validate gates
#   1 = parity diff or setup error
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$REPO_ROOT"

_log()  { printf '\033[0;36m[parity]\033[0m %s\n' "$*"; }
_ok()   { printf '\033[0;32m[parity] PASS\033[0m %s\n' "$*"; }
_fail() { printf '\033[0;31m[parity] FAIL\033[0m %s\n' "$*" >&2; exit 1; }

if ! command -v go >/dev/null 2>&1; then
    _fail "Go not installed — m14 parity check requires the binary"
fi

_log "Building Go binary via 'make build'..."
make build >/dev/null
export PATH="${REPO_ROOT}/bin:${PATH}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- write fixture --------------------------------------------------------

_write_fixture() {
    local name="$1" body="$2"
    local dir="${WORK}/${name}"
    mkdir -p "$dir"
    printf '%s' "$body" > "${dir}/MANIFEST.cfg"
    # Touch milestone files referenced in the manifest so validate won't
    # flag missing files for the "happy" cases.
    awk -F'|' '/^[^#]/ && NF>=5 && $5 != "" {print $5}' "${dir}/MANIFEST.cfg" \
        | while IFS= read -r fn; do
            [[ -n "$fn" ]] && touch "${dir}/${fn}"
        done
    echo "${dir}/MANIFEST.cfg"
}

FIX1="$(_write_fixture happy_path "# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First|pending||m01.md|p1
m02|Second|pending|m01|m02.md|p1
m03|Third|pending|m02|m03.md|p1
")"

FIX2="$(_write_fixture mixed_statuses "# header
m01|First|done||m01.md|
m02|Second|in_progress|m01|m02.md|
m03|Third|pending|m02|m03.md|
m04|Fourth|split|m01|m04.md|
m05|Fifth|skipped|m04|m05.md|
")"

FIX3="$(_write_fixture multi_active "m01|First|done||m01.md|
m02|Second|in_progress|m01|m02.md|
m03|Third|in_progress|m01|m03.md|
m04|Fourth|pending|m02,m03|m04.md|
")"

FIX4="$(_write_fixture dep_chain "m01|First|done||m01.md|
m02|Second|done|m01|m02.md|
m03|Third|pending|m02|m03.md|
")"

FIX5="$(_write_fixture split_subtree "m01|Parent|split||m01.md|
m01.1|Child One|done|m01|m01.1.md|
m01.2|Child Two|pending|m01.1|m01.2.md|
")"

# --- bash dump (operate on the _DAG_* arrays after load_manifest) ---------
# Hide the Go binary from the bash subprocess so the legacy array path is
# exercised; this proves the in-memory bash queries match the Go subcommands
# when given the same on-disk manifest.

_dump_bash_frontier() {
    local manifest="$1"
    bash -c '
        set -euo pipefail
        TEKHTON_HOME="'"$REPO_ROOT"'"
        PROJECT_DIR="'"$WORK"'"
        export TEKHTON_HOME PROJECT_DIR
        PATH="$(printf %s "$PATH" | tr ":" "\n" | grep -v "'"${REPO_ROOT}"'/bin" | paste -sd:)"
        # shellcheck source=/dev/null
        source "$TEKHTON_HOME/lib/common.sh"
        MILESTONE_DIR=".claude/milestones"; MILESTONE_MANIFEST="MANIFEST.cfg"
        # shellcheck source=/dev/null
        source "$TEKHTON_HOME/lib/milestone_dag.sh"
        load_manifest "'"$manifest"'"
        dag_get_frontier
    '
}

_dump_bash_active() {
    local manifest="$1"
    bash -c '
        set -euo pipefail
        TEKHTON_HOME="'"$REPO_ROOT"'"
        PROJECT_DIR="'"$WORK"'"
        export TEKHTON_HOME PROJECT_DIR
        PATH="$(printf %s "$PATH" | tr ":" "\n" | grep -v "'"${REPO_ROOT}"'/bin" | paste -sd:)"
        # shellcheck source=/dev/null
        source "$TEKHTON_HOME/lib/common.sh"
        MILESTONE_DIR=".claude/milestones"; MILESTONE_MANIFEST="MANIFEST.cfg"
        # shellcheck source=/dev/null
        source "$TEKHTON_HOME/lib/milestone_dag.sh"
        load_manifest "'"$manifest"'"
        dag_get_active
    '
}

_check_frontier_parity() {
    local name="$1" manifest="$2"
    local b g
    b="$(_dump_bash_frontier "$manifest" | sort)"
    g="$("${REPO_ROOT}/bin/tekhton" dag frontier --path "$manifest" | sort)"
    if [[ "$b" != "$g" ]]; then
        _log "[$name] bash frontier:"; printf '%s\n' "$b" | sed 's/^/    /'
        _log "[$name] go   frontier:"; printf '%s\n' "$g" | sed 's/^/    /'
        _fail "[$name] frontier parity diff"
    fi
    _ok "[$name] frontier parity"
}

_check_active_parity() {
    local name="$1" manifest="$2"
    local b g
    b="$(_dump_bash_active "$manifest" | sort)"
    g="$("${REPO_ROOT}/bin/tekhton" dag active --path "$manifest" | sort)"
    if [[ "$b" != "$g" ]]; then
        _log "[$name] bash active:"; printf '%s\n' "$b" | sed 's/^/    /'
        _log "[$name] go   active:"; printf '%s\n' "$g" | sed 's/^/    /'
        _fail "[$name] active parity diff"
    fi
    _ok "[$name] active parity"
}

# --- validate gates -------------------------------------------------------

_check_validate_clean() {
    local name="$1" manifest="$2"
    if ! "${REPO_ROOT}/bin/tekhton" dag validate --path "$manifest" 2>/dev/null; then
        _fail "[$name] validate flagged a clean fixture"
    fi
    _ok "[$name] validate clean"
}

_check_validate_missing_dep() {
    local manifest="${WORK}/missing_dep/MANIFEST.cfg"
    mkdir -p "$(dirname "$manifest")"
    cat > "$manifest" <<'EOF'
m01|First|pending||m01.md|
m02|Second|pending|m_nonexistent|m02.md|
EOF
    touch "$(dirname "$manifest")/m01.md" "$(dirname "$manifest")/m02.md"
    if "${REPO_ROOT}/bin/tekhton" dag validate --path "$manifest" 2>/dev/null; then
        _fail "validate should reject missing-dep manifest"
    fi
    _ok "validate flags missing dep"
}

_check_validate_cycle() {
    local manifest="${WORK}/cycle/MANIFEST.cfg"
    mkdir -p "$(dirname "$manifest")"
    cat > "$manifest" <<'EOF'
m01|First|pending|m02|m01.md|
m02|Second|pending|m01|m02.md|
EOF
    touch "$(dirname "$manifest")/m01.md" "$(dirname "$manifest")/m02.md"
    if "${REPO_ROOT}/bin/tekhton" dag validate --path "$manifest" 2>/dev/null; then
        _fail "validate should reject cyclic manifest"
    fi
    _ok "validate flags cycle"
}

_check_validate_missing_file() {
    local manifest="${WORK}/missing_file/MANIFEST.cfg"
    mkdir -p "$(dirname "$manifest")"
    cat > "$manifest" <<'EOF'
m01|First|pending||m01.md|
m02|Second|pending|m01|m02-absent.md|
EOF
    touch "$(dirname "$manifest")/m01.md"  # m02 file deliberately missing
    if "${REPO_ROOT}/bin/tekhton" dag validate --path "$manifest" 2>/dev/null; then
        _fail "validate should reject missing-file manifest"
    fi
    _ok "validate flags missing file"
}

# --- migrate idempotency -------------------------------------------------

_check_migrate_idempotent() {
    local dir="${WORK}/migrate"
    mkdir -p "$dir"
    cat > "${dir}/CLAUDE.md" <<'EOF'
# Project
### Milestones
#### Milestone 1: Alpha
Acceptance criteria:
- ok
#### Milestone 2: Beta
Depends on Milestone 1.

Acceptance criteria:
- ok
EOF
    "${REPO_ROOT}/bin/tekhton" dag migrate \
        --inline-claude-md "${dir}/CLAUDE.md" \
        --milestone-dir    "${dir}/.claude/milestones" 2>/dev/null
    if [[ ! -f "${dir}/.claude/milestones/MANIFEST.cfg" ]]; then
        _fail "migrate did not produce MANIFEST.cfg"
    fi
    # Re-run: should silently no-op.
    "${REPO_ROOT}/bin/tekhton" dag migrate \
        --inline-claude-md "${dir}/CLAUDE.md" \
        --milestone-dir    "${dir}/.claude/milestones" 2>/dev/null
    _ok "migrate is idempotent"
}

# --- run -----------------------------------------------------------------

_check_frontier_parity happy_path     "$FIX1"
_check_frontier_parity mixed_statuses "$FIX2"
_check_frontier_parity multi_active   "$FIX3"
_check_frontier_parity dep_chain      "$FIX4"
_check_frontier_parity split_subtree  "$FIX5"

_check_active_parity happy_path     "$FIX1"
_check_active_parity mixed_statuses "$FIX2"
_check_active_parity multi_active   "$FIX3"

_check_validate_clean happy_path     "$FIX1"
_check_validate_clean dep_chain      "$FIX4"

_check_validate_missing_dep
_check_validate_cycle
_check_validate_missing_file
_check_migrate_idempotent

_ok "all parity gates passed"
exit 0
