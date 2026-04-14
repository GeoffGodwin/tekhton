#!/usr/bin/env bash
# Test: Milestone 20/69 — rescan_project fallback and _detect_significant_changes
# Covers: rescan_project fallback when no PROJECT_INDEX.md,
#         _detect_significant_changes trivial/moderate/major classification,
#         _is_manifest_file, _is_config_file, _extract_scan_metadata,
#         _extract_sampled_files
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions (common.sh dependencies)
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# M84: Variable defaults (normally set by common.sh / config_defaults.sh)
: "${TEKHTON_DIR:=.tekhton}"
: "${SCOUT_REPORT_FILE:=${TEKHTON_DIR}/SCOUT_REPORT.md}"
: "${ARCHITECT_PLAN_FILE:=${TEKHTON_DIR}/ARCHITECT_PLAN.md}"
: "${CLEANUP_REPORT_FILE:=${TEKHTON_DIR}/CLEANUP_REPORT.md}"
: "${DRIFT_ARCHIVE_FILE:=${TEKHTON_DIR}/DRIFT_ARCHIVE.md}"
: "${PROJECT_INDEX_FILE:=${TEKHTON_DIR}/PROJECT_INDEX.md}"
: "${REPLAN_DELTA_FILE:=${TEKHTON_DIR}/REPLAN_DELTA.md}"
: "${MERGE_CONTEXT_FILE:=${TEKHTON_DIR}/MERGE_CONTEXT.md}"

# Stub crawler.sh dependencies needed by rescan_helpers.sh
_list_tracked_files() {
    local proj="$1"
    find "$proj" -maxdepth 3 -type f 2>/dev/null | sed "s|^${proj}/||" || true
}

# Source rescan_helpers.sh directly (rescan.sh sources it internally)
# shellcheck source=../lib/rescan_helpers.sh
source "${TEKHTON_HOME}/lib/rescan_helpers.sh"

# Source rescan.sh (will re-source rescan_helpers.sh, that's fine)
# shellcheck source=../lib/rescan.sh
source "${TEKHTON_HOME}/lib/rescan.sh"

# Override crawl_project AFTER sourcing so we can track whether it was called
CRAWL_PROJECT_CALLED=0
CRAWL_PROJECT_DIR=""
crawl_project() {
    CRAWL_PROJECT_CALLED=$(( CRAWL_PROJECT_CALLED + 1 ))
    CRAWL_PROJECT_DIR="${1:-}"
    # Write a minimal index so callers don't fail
    local proj="${1:-.}"
    local idx="${proj}/PROJECT_INDEX.md"
    printf '<!-- Last-Scan: 2026-01-01T00:00:00Z -->\n' > "$idx"
    printf '<!-- Scan-Commit: abc1234 -->\n' >> "$idx"
    printf '<!-- File-Count: 1 -->\n' >> "$idx"
    printf '<!-- Total-Lines: 10 -->\n' >> "$idx"
    printf '# Project Index\n' >> "$idx"
}

reset_crawl_tracker() {
    CRAWL_PROJECT_CALLED=0
    CRAWL_PROJECT_DIR=""
}

# =============================================================================
# rescan_project — fallback when PROJECT_INDEX.md is absent
# =============================================================================
echo "=== rescan_project: no PROJECT_INDEX.md → full crawl ==="

PROJ=$(mktemp -d "${TEST_TMPDIR}/proj_no_index.XXXXX")
reset_crawl_tracker

rescan_project "$PROJ" 120000

if [[ "$CRAWL_PROJECT_CALLED" -ge 1 ]]; then
    pass "rescan_project calls crawl_project when PROJECT_INDEX.md is absent"
else
    fail "rescan_project did NOT call crawl_project when PROJECT_INDEX.md is absent"
fi

# =============================================================================
# rescan_project — force full crawl with "full" arg even when index exists
# =============================================================================
echo "=== rescan_project: force_full=full → full crawl regardless ==="

PROJ=$(mktemp -d "${TEST_TMPDIR}/proj_force_full.XXXXX")
# Create a minimal index
printf '<!-- Scan-Commit: abc1234 -->\n# Index\n' > "${PROJ}/PROJECT_INDEX.md"
reset_crawl_tracker

rescan_project "$PROJ" 120000 "full"

if [[ "$CRAWL_PROJECT_CALLED" -ge 1 ]]; then
    pass "rescan_project calls crawl_project when force_full=full"
else
    fail "rescan_project did NOT call crawl_project for force_full=full"
fi

# =============================================================================
# rescan_project — fallback when not a git repo (no index commit to diff from)
# =============================================================================
echo "=== rescan_project: non-git dir → full crawl ==="

PROJ=$(mktemp -d "${TEST_TMPDIR}/proj_non_git.XXXXX")
# Create an index with a scan commit
printf '<!-- Last-Scan: 2026-01-01T00:00:00Z -->\n' > "${PROJ}/PROJECT_INDEX.md"
printf '<!-- Scan-Commit: abc1234 -->\n' >> "${PROJ}/PROJECT_INDEX.md"
printf '# Index\n' >> "${PROJ}/PROJECT_INDEX.md"
# M69: create structured index so migration check at rescan.sh:51 does not intercept
mkdir -p "${PROJ}/.claude/index"
printf '{"schema_version":1,"scan_commit":"abc1234","file_count":1,"total_lines":1}\n' \
    > "${PROJ}/.claude/index/meta.json"
reset_crawl_tracker

# This dir is not a git repo — rescan should fall back gracefully
rescan_project "$PROJ" 120000

if [[ "$CRAWL_PROJECT_CALLED" -ge 1 ]]; then
    pass "rescan_project falls back to crawl_project for non-git directory"
else
    fail "rescan_project did NOT fall back to crawl_project for non-git directory"
fi

# =============================================================================
# rescan_project — fallback when no scan commit recorded in index
# =============================================================================
echo "=== rescan_project: no Scan-Commit in index → full crawl ==="

PROJ=$(mktemp -d "${TEST_TMPDIR}/proj_no_commit.XXXXX")
# Index exists but has no Scan-Commit metadata
printf '# Project Index\n\nNo metadata here.\n' > "${PROJ}/PROJECT_INDEX.md"
# M69: create structured index so migration check at rescan.sh:51 does not intercept
mkdir -p "${PROJ}/.claude/index"
printf '{"schema_version":1,"scan_commit":"","file_count":0,"total_lines":0}\n' \
    > "${PROJ}/.claude/index/meta.json"
reset_crawl_tracker

# Need a git repo for this test path to reach the commit check
cd "$PROJ" && git init -q && git commit --allow-empty -m "init" -q && cd - >/dev/null

rescan_project "$PROJ" 120000

if [[ "$CRAWL_PROJECT_CALLED" -ge 1 ]]; then
    pass "rescan_project falls back to crawl_project when no Scan-Commit in index"
else
    fail "rescan_project did NOT fall back when Scan-Commit is absent from index"
fi

# Helper: build tab-separated change line
tab_line() {
    # tab_line STATUS FILEPATH [DEST]
    local status="$1" filepath="$2" dest="${3:-}"
    if [[ -n "$dest" ]]; then
        printf '%s\t%s\t%s' "$status" "$filepath" "$dest"
    else
        printf '%s\t%s' "$status" "$filepath"
    fi
}

# =============================================================================
# _detect_significant_changes — trivial: only content modifications
# =============================================================================
echo "=== _detect_significant_changes: content-only changes → trivial ==="

changed=$(printf '%s\n' \
    "$(tab_line M src/main.py)" \
    "$(tab_line M src/utils.py)" \
    "$(tab_line M README.md)")

result=$(_detect_significant_changes "$changed")
if [[ "$result" == "trivial" ]]; then
    pass "_detect_significant_changes returns 'trivial' for content-only modifications"
else
    fail "_detect_significant_changes expected 'trivial', got '${result}'"
fi

# =============================================================================
# _detect_significant_changes — moderate: single manifest change
# =============================================================================
echo "=== _detect_significant_changes: one manifest change → moderate ==="

changed=$(printf '%s\n' \
    "$(tab_line M package.json)" \
    "$(tab_line M src/index.js)")

result=$(_detect_significant_changes "$changed")
if [[ "$result" == "moderate" ]]; then
    pass "_detect_significant_changes returns 'moderate' for single manifest change"
else
    fail "_detect_significant_changes expected 'moderate' (manifest), got '${result}'"
fi

# =============================================================================
# _detect_significant_changes — moderate: new file in a subdirectory
# =============================================================================
echo "=== _detect_significant_changes: new file in subdir → moderate ==="

changed=$(tab_line A src/new_feature.py)

result=$(_detect_significant_changes "$changed")
if [[ "$result" == "moderate" ]]; then
    pass "_detect_significant_changes returns 'moderate' for new file in subdirectory"
else
    fail "_detect_significant_changes expected 'moderate' (new subdir), got '${result}'"
fi

# =============================================================================
# _detect_significant_changes — major: two manifest changes
# =============================================================================
echo "=== _detect_significant_changes: two manifest changes → major ==="

changed=$(printf '%s\n' \
    "$(tab_line M package.json)" \
    "$(tab_line M pyproject.toml)" \
    "$(tab_line M src/app.py)")

result=$(_detect_significant_changes "$changed")
if [[ "$result" == "major" ]]; then
    pass "_detect_significant_changes returns 'major' for two manifest changes"
else
    fail "_detect_significant_changes expected 'major' (2 manifests), got '${result}'"
fi

# =============================================================================
# _detect_significant_changes — major: 5+ new subdirectory files
# =============================================================================
echo "=== _detect_significant_changes: 5+ new subdir files → major ==="

changed=$(printf '%s\n' \
    "$(tab_line A module_a/init.py)" \
    "$(tab_line A module_b/init.py)" \
    "$(tab_line A module_c/init.py)" \
    "$(tab_line A module_d/init.py)" \
    "$(tab_line A module_e/init.py)")

result=$(_detect_significant_changes "$changed")
if [[ "$result" == "major" ]]; then
    pass "_detect_significant_changes returns 'major' for 5+ new subdirectory additions"
else
    fail "_detect_significant_changes expected 'major' (5 new dirs), got '${result}'"
fi

# =============================================================================
# _detect_significant_changes — major: 10+ deleted files
# =============================================================================
echo "=== _detect_significant_changes: 10+ deleted files → major ==="

changed=$(printf '%s\n' \
    "$(tab_line D a.py)" \
    "$(tab_line D b.py)" \
    "$(tab_line D c.py)" \
    "$(tab_line D d.py)" \
    "$(tab_line D e.py)" \
    "$(tab_line D f.py)" \
    "$(tab_line D g.py)" \
    "$(tab_line D h.py)" \
    "$(tab_line D i.py)" \
    "$(tab_line D j.py)")

result=$(_detect_significant_changes "$changed")
if [[ "$result" == "major" ]]; then
    pass "_detect_significant_changes returns 'major' for 10+ deletions"
else
    fail "_detect_significant_changes expected 'major' (10 deletions), got '${result}'"
fi

# =============================================================================
# _detect_significant_changes — trivial: new file at root level (dir = ".")
# =============================================================================
echo "=== _detect_significant_changes: new root-level file → trivial ==="

changed=$(tab_line A newfile.txt)

result=$(_detect_significant_changes "$changed")
# A file at root has dirname="." so it should NOT count as a new directory
if [[ "$result" == "trivial" ]]; then
    pass "_detect_significant_changes returns 'trivial' for new root-level file"
else
    fail "_detect_significant_changes expected 'trivial' for root file, got '${result}'"
fi

# =============================================================================
# _is_manifest_file — known manifests return 0
# =============================================================================
echo "=== _is_manifest_file: known manifests recognized ==="

for manifest in package.json Cargo.toml go.mod pyproject.toml requirements.txt \
                setup.py Pipfile Gemfile pom.xml Makefile pubspec.yaml; do
    if _is_manifest_file "$manifest"; then
        pass "_is_manifest_file recognizes ${manifest}"
    else
        fail "_is_manifest_file failed to recognize ${manifest}"
    fi
done

# =============================================================================
# _is_manifest_file — non-manifest returns 1
# =============================================================================
echo "=== _is_manifest_file: non-manifests rejected ==="

for non_manifest in main.py index.js README.md src/app.ts; do
    if ! _is_manifest_file "$non_manifest"; then
        pass "_is_manifest_file correctly rejects ${non_manifest}"
    else
        fail "_is_manifest_file incorrectly accepted ${non_manifest} as manifest"
    fi
done

# =============================================================================
# _is_config_file — known config files return 0
# =============================================================================
echo "=== _is_config_file: known config files recognized ==="

for cfg in .gitignore Dockerfile docker-compose.yml .editorconfig \
           app.conf settings.yaml pipeline.json; do
    if _is_config_file "$cfg"; then
        pass "_is_config_file recognizes ${cfg}"
    else
        fail "_is_config_file failed to recognize ${cfg}"
    fi
done

# =============================================================================
# _is_config_file — non-config source files rejected
# =============================================================================
echo "=== _is_config_file: source files rejected ==="

for src in main.py index.js lib/utils.sh tests/test_foo.sh; do
    if ! _is_config_file "$src"; then
        pass "_is_config_file correctly rejects ${src}"
    else
        fail "_is_config_file incorrectly accepted ${src} as config"
    fi
done

# =============================================================================
# _extract_scan_metadata — reads correct field from index header
# =============================================================================
echo "=== _extract_scan_metadata: correct field extraction ==="

INDEX="${TEST_TMPDIR}/meta_test_index.md"
cat > "$INDEX" << 'EOF'
<!-- Last-Scan: 2026-03-21T10:00:00Z -->
<!-- Scan-Commit: abc1234 -->
<!-- File-Count: 42 -->
<!-- Total-Lines: 3000 -->
# Project Index
EOF

commit=$(_extract_scan_metadata "$INDEX" "Scan-Commit")
if [[ "$commit" == "abc1234" ]]; then
    pass "_extract_scan_metadata reads Scan-Commit correctly"
else
    fail "_extract_scan_metadata Scan-Commit: expected 'abc1234', got '${commit}'"
fi

file_count=$(_extract_scan_metadata "$INDEX" "File-Count")
if [[ "$file_count" == "42" ]]; then
    pass "_extract_scan_metadata reads File-Count correctly"
else
    fail "_extract_scan_metadata File-Count: expected '42', got '${file_count}'"
fi

last_scan=$(_extract_scan_metadata "$INDEX" "Last-Scan")
if [[ "$last_scan" == "2026-03-21T10:00:00Z" ]]; then
    pass "_extract_scan_metadata reads Last-Scan correctly"
else
    fail "_extract_scan_metadata Last-Scan: expected '2026-03-21T10:00:00Z', got '${last_scan}'"
fi

# =============================================================================
# _extract_scan_metadata — missing field returns empty string
# =============================================================================
echo "=== _extract_scan_metadata: missing field → empty ==="

INDEX_NO_META="${TEST_TMPDIR}/no_meta_index.md"
printf '# Project Index\nNo metadata here.\n' > "$INDEX_NO_META"

missing=$(_extract_scan_metadata "$INDEX_NO_META" "Scan-Commit")
if [[ -z "$missing" ]]; then
    pass "_extract_scan_metadata returns empty for missing field"
else
    fail "_extract_scan_metadata returned non-empty for missing field: '${missing}'"
fi

# =============================================================================
# _extract_sampled_files — lists files from ### `filename` headings
# =============================================================================
echo "=== _extract_sampled_files: extracts sampled filenames ==="

INDEX_WITH_SAMPLES="${TEST_TMPDIR}/samples_index.md"
cat > "$INDEX_WITH_SAMPLES" << 'EOF'
# Project Index

## Sampled File Content

### `src/main.py`
```python
print("hello")
```

### `package.json`
```json
{"name": "myapp"}
```

### `README.md`
Content here
EOF

samples=$(_extract_sampled_files "$INDEX_WITH_SAMPLES")
if echo "$samples" | grep -q "src/main.py"; then
    pass "_extract_sampled_files finds src/main.py"
else
    fail "_extract_sampled_files did not find src/main.py"
fi

if echo "$samples" | grep -q "package.json"; then
    pass "_extract_sampled_files finds package.json"
else
    fail "_extract_sampled_files did not find package.json"
fi

sample_count=$(echo "$samples" | grep -c '.' || true)
if [[ "$sample_count" -eq 3 ]]; then
    pass "_extract_sampled_files returns exactly 3 sampled files"
else
    fail "_extract_sampled_files expected 3 files, got ${sample_count}"
fi

# =============================================================================
# _extract_sampled_files — empty index returns nothing
# =============================================================================
echo "=== _extract_sampled_files: empty index → empty output ==="

INDEX_EMPTY="${TEST_TMPDIR}/empty_index.md"
printf '# Project Index\n\n## File Inventory\n\nNo files.\n' > "$INDEX_EMPTY"

empty_samples=$(_extract_sampled_files "$INDEX_EMPTY")
if [[ -z "$empty_samples" ]]; then
    pass "_extract_sampled_files returns empty for index with no sampled files"
else
    fail "_extract_sampled_files returned non-empty for index without samples: '${empty_samples}'"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
