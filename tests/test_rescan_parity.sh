#!/usr/bin/env bash
# tests/test_rescan_parity.sh — m30.2 parity gate.
#
# Drives `tekhton crawler rescan --json` against four scenarios and
# asserts the returned (mode, significance, regenerated_sections) against
# the expected verdict captured in each scenario's expected.json file.
#
# Scenarios live under internal/crawler/testdata/rescan_scenarios/.
# Each scenario is a fixture directory containing only its source files;
# the test harness initialises git, seeds .claude/index/, applies the
# scenario mutation, and verifies the rescan response.
#
# This is intentionally stronger than a "byte-identical bash baseline"
# diff — the legacy bash had skip-unchanged regressions historically
# (sites that re-wrote tree.txt on every rescan). The write-set
# assertion catches both directions: missing writes AND spurious writes.
#
# Self-skips cleanly when the Go binary is unavailable.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEKHTON_DIR="$(cd "${TESTS_DIR}/.." && pwd)"

# Resolve tekhton binary: explicit override, then PATH, then ./tekhton.
TEKHTON_BIN="${TEKHTON_BIN:-}"
if [[ -z "$TEKHTON_BIN" ]]; then
    if command -v tekhton >/dev/null 2>&1; then
        TEKHTON_BIN="$(command -v tekhton)"
    elif [[ -x "${TEKHTON_DIR}/tekhton" ]]; then
        TEKHTON_BIN="${TEKHTON_DIR}/tekhton"
    fi
fi
if [[ -z "$TEKHTON_BIN" ]] || [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "SKIP $(basename "${BASH_SOURCE[0]}"): tekhton Go binary not built (set TEKHTON_BIN or run 'make build')"
    exit 0
fi

# shellcheck source=tests/lib/parity.sh
source "${TESTS_DIR}/lib/parity.sh"

SCENARIOS_DIR="${TEKHTON_DIR}/internal/crawler/testdata/rescan_scenarios"
WORK="$(mktemp -d -t rescan-parity.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

# git_setup PROJECT_DIR — initialise a git repo with deterministic
# author/committer identity. Adds + commits everything currently in the
# tree so subsequent diffs are clean.
git_setup() {
    local dir="$1"
    (
        cd "$dir"
        git init -q -b main
        git config user.email "test@example.com"
        git config user.name "test"
        printf '.claude/\n.tekhton/\n' > .gitignore
        git add -A
        git commit -q -m "init"
    )
}

# seed_index PROJECT_DIR — run the full crawler to populate
# .claude/index/ and .tekhton/PROJECT_INDEX.md placeholder.
seed_index() {
    local dir="$1"
    "${TEKHTON_BIN}" crawler crawl \
        --project-dir "$dir" \
        --budget 30000 >/dev/null
    mkdir -p "${dir}/.tekhton"
    echo "# index" > "${dir}/.tekhton/PROJECT_INDEX.md"
}

# run_rescan_json PROJECT_DIR — run `tekhton crawler rescan --json` and
# echo the JSON output. The caller pipes through `jq` (or grep) to
# extract fields.
run_rescan_json() {
    local dir="$1"
    "${TEKHTON_BIN}" crawler rescan \
        --project-dir "$dir" \
        --budget 30000 \
        --json 2>&1
}

# assert_field NAME JSON_BLOB FIELD EXPECTED — substring-assert that a
# JSON field has the expected value. Uses a lenient regex match so the
# test stays portable without requiring jq.
assert_field() {
    local name="$1" blob="$2" field="$3" expected="$4"
    if echo "$blob" | grep -qE "\"${field}\":\s*\"${expected}\""; then
        parity_pass "${name}: ${field}=${expected}"
    elif echo "$blob" | grep -qE "\"${field}\":\s*${expected}"; then
        parity_pass "${name}: ${field}=${expected}"
    else
        parity_fail "${name}: expected ${field}=${expected}, JSON was:"
        printf '%s\n' "$blob" >&2
    fi
}

# assert_regenerated_contains NAME JSON_BLOB SECTION — assert the
# regenerated_sections array contains a given entry.
assert_regenerated_contains() {
    local name="$1" blob="$2" section="$3"
    if echo "$blob" | tr ',' '\n' | grep -qE "\"$(printf '%s' "$section" | sed 's:/:\\/:g')\""; then
        parity_pass "${name}: regenerated includes ${section}"
    else
        parity_fail "${name}: expected regenerated to include ${section}"
        printf '%s\n' "$blob" >&2
    fi
}

# assert_regenerated_excludes NAME JSON_BLOB SECTION — assert the
# regenerated_sections array does NOT contain a given entry.
assert_regenerated_excludes() {
    local name="$1" blob="$2" section="$3"
    if echo "$blob" | tr ',' '\n' | grep -qE "\"$(printf '%s' "$section" | sed 's:/:\\/:g')\""; then
        parity_fail "${name}: regenerated should NOT include ${section}"
        printf '%s\n' "$blob" >&2
    else
        parity_pass "${name}: regenerated excludes ${section}"
    fi
}

# -----------------------------------------------------------------------------
# Scenario 1: no_changes — rescan should be a no-op.
# -----------------------------------------------------------------------------
no_changes_scenario() {
    local proj="${WORK}/no_changes"
    cp -r "${SCENARIOS_DIR}/no_changes" "$proj"
    git_setup "$proj"
    seed_index "$proj"

    local out
    out="$(run_rescan_json "$proj")"
    assert_field "no_changes" "$out" "mode" "noop"
}

# -----------------------------------------------------------------------------
# Scenario 2: trivial — single edit to tracked file, no new dirs.
# Expected: incremental, trivial sig; inventory + meta regen only.
# -----------------------------------------------------------------------------
trivial_scenario() {
    local proj="${WORK}/trivial"
    cp -r "${SCENARIOS_DIR}/trivial" "$proj"
    git_setup "$proj"
    seed_index "$proj"

    # Edit a tracked source file.
    echo "// edited" >> "${proj}/src/main.go"

    local out
    out="$(run_rescan_json "$proj")"
    assert_field "trivial" "$out" "mode" "incremental"
    assert_field "trivial" "$out" "significance" "trivial"
    assert_regenerated_contains "trivial" "$out" "inventory.jsonl"
    assert_regenerated_contains "trivial" "$out" "meta.json"
    assert_regenerated_excludes "trivial" "$out" "tree.txt"
    assert_regenerated_excludes "trivial" "$out" "dependencies.json"
    assert_regenerated_excludes "trivial" "$out" "configs.json"
}

# -----------------------------------------------------------------------------
# Scenario 3: moderate_manifest — single manifest edit.
# Expected: incremental, moderate sig; inventory + deps + meta regen.
# tree.txt and configs.json should NOT regen.
# -----------------------------------------------------------------------------
moderate_manifest_scenario() {
    local proj="${WORK}/moderate_manifest"
    cp -r "${SCENARIOS_DIR}/moderate_manifest" "$proj"
    git_setup "$proj"
    seed_index "$proj"

    # Edit package.json — adds a dep.
    cat > "${proj}/package.json" <<'EOF'
{
  "name": "demo",
  "dependencies": {
    "express": "^4.18.0"
  }
}
EOF

    local out
    out="$(run_rescan_json "$proj")"
    assert_field "moderate_manifest" "$out" "mode" "incremental"
    assert_field "moderate_manifest" "$out" "significance" "moderate"
    assert_regenerated_contains "moderate_manifest" "$out" "dependencies.json"
    assert_regenerated_contains "moderate_manifest" "$out" "inventory.jsonl"
    assert_regenerated_contains "moderate_manifest" "$out" "meta.json"
    assert_regenerated_excludes "moderate_manifest" "$out" "tree.txt"
    # NB: package.json IS a config file by bash's IsConfigFile rules
    # (*.json arm), so configs.json regens too — matches bash semantics.
    assert_regenerated_contains "moderate_manifest" "$out" "configs.json"
}

# -----------------------------------------------------------------------------
# Scenario 4: major_manifest — 2+ manifest edits trigger major → full crawl.
# -----------------------------------------------------------------------------
major_manifest_scenario() {
    local proj="${WORK}/major_manifest"
    cp -r "${SCENARIOS_DIR}/major_manifest" "$proj"
    git_setup "$proj"
    seed_index "$proj"

    # Edit both manifests.
    echo '{"name":"a","version":"2.0.0"}' > "${proj}/package.json"
    cat > "${proj}/Cargo.toml" <<'EOF'
[package]
name = "demo"
version = "0.2.0"
EOF

    local out
    out="$(run_rescan_json "$proj")"
    assert_field "major_manifest" "$out" "mode" "full"
    assert_field "major_manifest" "$out" "significance" "major"
}

no_changes_scenario
trivial_scenario
moderate_manifest_scenario
major_manifest_scenario

parity_summary "rescan-parity"
