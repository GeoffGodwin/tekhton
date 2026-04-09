#!/usr/bin/env bash
# Test: Milestone 18 — crawler function unit tests
# Covers: _crawl_config_inventory, _parse_cargo_deps, _read_sampled_file, _is_binary_file
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source detect.sh first (provides _DETECT_EXCLUDE_DIRS + _extract_json_keys)
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck source=../lib/crawler.sh
source "${TEKHTON_HOME}/lib/crawler.sh"

# Helper: create a fresh isolated project dir
make_proj() {
    local name="$1"
    local dir="${TEST_TMPDIR}/${name}"
    mkdir -p "$dir"
    echo "$dir"
}

# =============================================================================
# _crawl_config_inventory — .gitignore recognized with correct purpose
# =============================================================================
echo "=== _crawl_config_inventory: .gitignore → correct purpose ==="

PROJ=$(make_proj "gitignore_test")
touch "${PROJ}/.gitignore"

result=$(_crawl_config_inventory "$PROJ")
if echo "$result" | grep -q ".gitignore" && echo "$result" | grep -q "Git ignore"; then
    pass "_crawl_config_inventory recognizes .gitignore with 'Git ignore' purpose"
else
    fail "_crawl_config_inventory .gitignore output: ${result}"
fi

# =============================================================================
# _crawl_config_inventory — Dockerfile recognized
# =============================================================================
echo "=== _crawl_config_inventory: Dockerfile → correct purpose ==="

PROJ=$(make_proj "dockerfile_test")
touch "${PROJ}/Dockerfile"

result=$(_crawl_config_inventory "$PROJ")
if echo "$result" | grep -q "Dockerfile" && echo "$result" | grep -q "Docker container"; then
    pass "_crawl_config_inventory recognizes Dockerfile with 'Docker container' purpose"
else
    fail "_crawl_config_inventory Dockerfile output: ${result}"
fi

# =============================================================================
# _crawl_config_inventory — unknown files omitted (no false positives)
# =============================================================================
echo "=== _crawl_config_inventory: unknown files omitted ==="

PROJ=$(make_proj "unknown_files")
touch "${PROJ}/main.py"
touch "${PROJ}/utils.py"

result=$(_crawl_config_inventory "$PROJ")
if ! echo "$result" | grep -q "main.py" && ! echo "$result" | grep -q "utils.py"; then
    pass "_crawl_config_inventory correctly omits non-config files"
else
    fail "_crawl_config_inventory included non-config file: ${result}"
fi

# =============================================================================
# _parse_cargo_deps — correctly extracts simple dependencies from Cargo.toml
# =============================================================================
echo "=== _parse_cargo_deps: extracts simple Cargo.toml dependencies ==="

PROJ=$(make_proj "cargo_deps")
cat > "${PROJ}/Cargo.toml" << 'EOF'
[package]
name = "myapp"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = "1.0"
tokio = { version = "1.0", features = ["full"] }
reqwest = "0.11"

[dev-dependencies]
mockall = "0.11"
EOF

result=$(_parse_cargo_deps "$PROJ" "")
if echo "$result" | grep -q "serde" && echo "$result" | grep -q "tokio" && \
   echo "$result" | grep -q "reqwest"; then
    pass "_parse_cargo_deps extracts serde, tokio, reqwest from Cargo.toml"
else
    fail "_parse_cargo_deps output missing expected deps: ${result}"
fi

# Verify dev-dependencies also captured
if echo "$result" | grep -q "mockall"; then
    pass "_parse_cargo_deps includes dev-dependencies"
else
    fail "_parse_cargo_deps did not capture dev-dependencies"
fi

# Verify annotation for known packages
if echo "$result" | grep -q "Core Rust library"; then
    pass "_parse_cargo_deps annotates known crates (serde/tokio/reqwest → Core Rust library)"
else
    fail "_parse_cargo_deps did not annotate known Rust crates"
fi

# =============================================================================
# _parse_cargo_deps — returns empty for dir without Cargo.toml
# =============================================================================
echo "=== _parse_cargo_deps: no Cargo.toml → empty output ==="

PROJ=$(make_proj "no_cargo")
result=$(_parse_cargo_deps "$PROJ" "")
if [[ -z "$result" ]]; then
    pass "_parse_cargo_deps returns empty when no Cargo.toml present"
else
    fail "_parse_cargo_deps returned non-empty for missing Cargo.toml: ${result}"
fi

# =============================================================================
# _annotate_package — known packages return non-empty annotation
# =============================================================================
echo "=== _annotate_package: known packages annotated correctly ==="

annotation=$(_annotate_package "express")
if [[ "$annotation" == "Web framework" ]]; then
    pass "_annotate_package returns 'Web framework' for express"
else
    fail "_annotate_package express: expected 'Web framework', got '${annotation}'"
fi

annotation=$(_annotate_package "pytest")
if [[ "$annotation" == "Test framework" ]]; then
    pass "_annotate_package returns 'Test framework' for pytest"
else
    fail "_annotate_package pytest: expected 'Test framework', got '${annotation}'"
fi

annotation=$(_annotate_package "react")
if [[ "$annotation" == "Frontend framework" ]]; then
    pass "_annotate_package returns 'Frontend framework' for react"
else
    fail "_annotate_package react: expected 'Frontend framework', got '${annotation}'"
fi

# Unknown package returns empty string
annotation=$(_annotate_package "some-unknown-package-xyz")
if [[ -z "$annotation" ]]; then
    pass "_annotate_package returns empty string for unknown package"
else
    fail "_annotate_package returned non-empty for unknown package: '${annotation}'"
fi

# =============================================================================
# _read_sampled_file — normal file (≤1000 lines) returned in full
# =============================================================================
echo "=== _read_sampled_file: small file returned in full ==="

SMALL_FILE="${TEST_TMPDIR}/small.txt"
printf 'line %d\n' {1..10} > "$SMALL_FILE"

result=$(_read_sampled_file "$SMALL_FILE" 100000)
line_count=$(echo "$result" | grep -c 'line' || true)
if [[ "$line_count" -eq 10 ]]; then
    pass "_read_sampled_file returns all 10 lines for small file"
else
    fail "_read_sampled_file returned ${line_count} lines for 10-line file"
fi

# =============================================================================
# _read_sampled_file — large file (>1000 lines) gets head+tail with omission marker
# =============================================================================
echo "=== _read_sampled_file: large file (>1000 lines) truncated with omission marker ==="

LARGE_FILE="${TEST_TMPDIR}/large.txt"
printf 'line %d\n' {1..1100} > "$LARGE_FILE"

result=$(_read_sampled_file "$LARGE_FILE" 100000)
if echo "$result" | grep -q "lines omitted"; then
    pass "_read_sampled_file includes 'lines omitted' marker for >1000-line file"
else
    fail "_read_sampled_file missing omission marker for >1000-line file"
fi

# Should contain first and last lines
if echo "$result" | grep -q "line 1$"; then
    pass "_read_sampled_file includes first line of large file"
else
    fail "_read_sampled_file missing first line of large file"
fi

if echo "$result" | grep -q "line 1100$"; then
    pass "_read_sampled_file includes last line (1100) of large file"
else
    fail "_read_sampled_file missing last line of large file"
fi

# =============================================================================
# _read_sampled_file — truncated to char budget with truncation marker
# =============================================================================
echo "=== _read_sampled_file: truncated to char budget ==="

BUDGET_FILE="${TEST_TMPDIR}/budget.txt"
# Write enough text to exceed a small budget
printf 'abcdefghijklmnopqrstuvwxyz\n%.0s' {1..20} > "$BUDGET_FILE"

result=$(_read_sampled_file "$BUDGET_FILE" 50)
if echo "$result" | grep -q "truncated"; then
    pass "_read_sampled_file truncates to char budget with truncation marker"
else
    fail "_read_sampled_file did not truncate to char budget"
fi

# =============================================================================
# _is_binary_file — known binary extensions return 0 (true = binary)
# =============================================================================
echo "=== _is_binary_file: binary extensions detected ==="

for ext in png jpg gif zip exe dll so pyc; do
    BINARY_FILE="${TEST_TMPDIR}/testfile.${ext}"
    touch "$BINARY_FILE"
    if _is_binary_file "$BINARY_FILE"; then
        pass "_is_binary_file correctly identifies .${ext} as binary"
    else
        fail "_is_binary_file failed to identify .${ext} as binary"
    fi
done

# =============================================================================
# _is_binary_file — text file returns 1 (false = not binary)
# =============================================================================
echo "=== _is_binary_file: text file not classified as binary ==="

TEXT_FILE="${TEST_TMPDIR}/testfile.sh"
echo '#!/usr/bin/env bash' > "$TEXT_FILE"

if ! _is_binary_file "$TEXT_FILE"; then
    pass "_is_binary_file correctly identifies .sh as non-binary"
else
    fail "_is_binary_file incorrectly classified .sh as binary"
fi

TEXT_FILE2="${TEST_TMPDIR}/testfile.py"
echo 'print("hello")' > "$TEXT_FILE2"

if ! _is_binary_file "$TEXT_FILE2"; then
    pass "_is_binary_file correctly identifies .py as non-binary"
else
    fail "_is_binary_file incorrectly classified .py as binary"
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
