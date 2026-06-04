#!/usr/bin/env bash
# =============================================================================
# tests/test_init_test_cmd_detection.sh — m42
#
# Acceptance Criterion #4: Init on a Cargo/Node/Go project emits a real
#   TEST_CMD, not "true".
#
# Exercises the m42 manifest-probe fallback in lib/init_config_test_cmd.sh
# directly so the test is fast and doesn't require Go-detect-engine wiring.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub common logging so the helper file sources cleanly.
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# shellcheck source=../lib/init_config_test_cmd.sh
source "${TEKHTON_HOME}/lib/init_config_test_cmd.sh"

mkproj() {
    local name="$1"
    local d="${TEST_TMPDIR}/${name}"
    mkdir -p "$d"
    echo "$d"
}

assert_eq() {
    local got="$1" want="$2" label="$3"
    if [[ "$got" == "$want" ]]; then
        pass "${label}: '${got}'"
    else
        fail "${label}: expected '${want}', got '${got}'"
    fi
}

echo "=== Rust → cargo test ==="
RUST="$(mkproj rust-proj)"
cat > "${RUST}/Cargo.toml" <<'EOF'
[package]
name = "demo"
version = "0.1.0"
EOF
assert_eq "$(_m42_test_cmd_fallback "$RUST")" "cargo test" "Cargo.toml inferred"
assert_eq "$(_m42_test_cmd_fallback_source "$RUST")" "Cargo.toml (m42 fallback)" "Cargo.toml source"

echo "=== Go → go test ./... ==="
GO="$(mkproj go-proj)"
cat > "${GO}/go.mod" <<'EOF'
module example.com/demo
go 1.22
EOF
assert_eq "$(_m42_test_cmd_fallback "$GO")" "go test ./..." "go.mod inferred"
assert_eq "$(_m42_test_cmd_fallback_source "$GO")" "go.mod (m42 fallback)" "go.mod source"

echo "=== Node with scripts.test → npm test ==="
NODE_GOOD="$(mkproj node-good)"
cat > "${NODE_GOOD}/package.json" <<'EOF'
{
  "name": "demo",
  "scripts": {
    "test": "jest"
  }
}
EOF
assert_eq "$(_m42_test_cmd_fallback "$NODE_GOOD")" "npm test" "package.json with real scripts.test"

echo "=== Node placeholder (npm-init default) → empty ==="
NODE_BAD="$(mkproj node-placeholder)"
cat > "${NODE_BAD}/package.json" <<'EOF'
{
  "name": "demo",
  "scripts": {
    "test": "echo \"Error: no test specified\" && exit 1"
  }
}
EOF
assert_eq "$(_m42_test_cmd_fallback "$NODE_BAD")" "" "package.json placeholder rejected"

echo "=== Node without scripts.test → empty ==="
NODE_NONE="$(mkproj node-none)"
cat > "${NODE_NONE}/package.json" <<'EOF'
{ "name": "demo" }
EOF
assert_eq "$(_m42_test_cmd_fallback "$NODE_NONE")" "" "package.json without scripts.test ignored"

echo "=== Python via pyproject.toml → pytest ==="
PY="$(mkproj py-pyproject)"
cat > "${PY}/pyproject.toml" <<'EOF'
[project]
name = "demo"
EOF
assert_eq "$(_m42_test_cmd_fallback "$PY")" "pytest" "pyproject.toml inferred"

PY2="$(mkproj py-setup)"
echo "from setuptools import setup; setup()" > "${PY2}/setup.py"
assert_eq "$(_m42_test_cmd_fallback "$PY2")" "pytest" "setup.py inferred"

echo "=== Ruby with rspec → bundle exec rspec ==="
RB="$(mkproj ruby-proj)"
cat > "${RB}/Gemfile" <<'EOF'
source 'https://rubygems.org'
gem 'rspec'
EOF
assert_eq "$(_m42_test_cmd_fallback "$RB")" "bundle exec rspec" "Gemfile with rspec inferred"

echo "=== Ruby without rspec → empty ==="
RB_NO="$(mkproj ruby-norspec)"
cat > "${RB_NO}/Gemfile" <<'EOF'
source 'https://rubygems.org'
gem 'rack'
EOF
assert_eq "$(_m42_test_cmd_fallback "$RB_NO")" "" "Gemfile without rspec ignored"

echo "=== Elixir → mix test ==="
EX="$(mkproj elixir-proj)"
touch "${EX}/mix.exs"
assert_eq "$(_m42_test_cmd_fallback "$EX")" "mix test" "mix.exs inferred"

echo "=== Flutter → flutter test ==="
FL="$(mkproj flutter-proj)"
cat > "${FL}/pubspec.yaml" <<'EOF'
name: demo
flutter:
  uses-material-design: true
EOF
assert_eq "$(_m42_test_cmd_fallback "$FL")" "flutter test" "pubspec.yaml flutter inferred"

echo "=== Dart non-flutter → dart test ==="
DR="$(mkproj dart-proj)"
cat > "${DR}/pubspec.yaml" <<'EOF'
name: demo
description: A pure Dart package.
EOF
assert_eq "$(_m42_test_cmd_fallback "$DR")" "dart test" "pubspec.yaml dart inferred"

echo "=== No manifest → empty ==="
EMPTY="$(mkproj empty-proj)"
assert_eq "$(_m42_test_cmd_fallback "$EMPTY")" "" "no manifest yields empty"

echo "=== Priority: Cargo.toml beats package.json ==="
MIX="$(mkproj cargo-and-node)"
cat > "${MIX}/Cargo.toml" <<'EOF'
[package]
name = "demo"
EOF
cat > "${MIX}/package.json" <<'EOF'
{ "scripts": { "test": "jest" } }
EOF
assert_eq "$(_m42_test_cmd_fallback "$MIX")" "cargo test" "Cargo.toml takes priority"

echo "=== Priority: go.mod beats pyproject.toml ==="
MIX2="$(mkproj go-and-py)"
cat > "${MIX2}/go.mod" <<'EOF'
module demo
go 1.22
EOF
cat > "${MIX2}/pyproject.toml" <<'EOF'
[project]
name = "demo"
EOF
assert_eq "$(_m42_test_cmd_fallback "$MIX2")" "go test ./..." "go.mod takes priority over pyproject.toml"

echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
