#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_m01_go_module_foundation.sh — Structural and content checks for M01
#
# Verifies the M01 Go module foundation deliverables without requiring a Go
# toolchain. Checks file existence, key content invariants, and shell-testable
# behavior (self-host-check.sh structure, gitignore entries, CI trigger config).
#
# Go unit tests for internal/version live in internal/version/version_test.go
# and require `go test ./...` (run via `make test` in CI).
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass
    else
        fail "${name}: expected '${expected}', got '${actual}'"
    fi
}

assert_file_exists() {
    local name="$1" path="$2"
    if [[ -f "$path" ]]; then
        pass
    else
        fail "${name}: file not found: ${path}"
    fi
}

assert_file_contains() {
    local name="$1" path="$2" pattern="$3"
    if grep -qF -- "$pattern" "$path" 2>/dev/null; then
        pass
    else
        fail "${name}: '${pattern}' not found in ${path}"
    fi
}

assert_file_contains_regex() {
    local name="$1" path="$2" pattern="$3"
    if grep -qE -- "$pattern" "$path" 2>/dev/null; then
        pass
    else
        fail "${name}: pattern '${pattern}' not matched in ${path}"
    fi
}

assert_file_contains_icase() {
    local name="$1" path="$2" pattern="$3"
    if grep -qiE -- "$pattern" "$path" 2>/dev/null; then
        pass
    else
        fail "${name}: pattern '${pattern}' (case-insensitive) not matched in ${path}"
    fi
}

assert_executable() {
    local name="$1" path="$2"
    if [[ -x "$path" ]]; then
        pass
    else
        fail "${name}: not executable: ${path}"
    fi
}

# =============================================================================
# T1: Required file existence
# =============================================================================
echo "=== T1: Required files exist ==="
assert_file_exists "T1a go.mod"                    "${TEKHTON_HOME}/go.mod"
assert_file_exists "T1b go.sum"                    "${TEKHTON_HOME}/go.sum"
assert_file_exists "T1c cmd/tekhton/main.go"       "${TEKHTON_HOME}/cmd/tekhton/main.go"
assert_file_exists "T1d internal/version/version.go" "${TEKHTON_HOME}/internal/version/version.go"
assert_file_exists "T1e Makefile"                  "${TEKHTON_HOME}/Makefile"
assert_file_exists "T1f .github/workflows/go-build.yml" "${TEKHTON_HOME}/.github/workflows/go-build.yml"
assert_file_exists "T1g scripts/self-host-check.sh" "${TEKHTON_HOME}/scripts/self-host-check.sh"
assert_file_exists "T1h docs/go-build.md"          "${TEKHTON_HOME}/docs/go-build.md"

# =============================================================================
# T2: go.mod content — module path, Go version, cobra dependency
# =============================================================================
echo "=== T2: go.mod content ==="
GOD="${TEKHTON_HOME}/go.mod"
assert_file_contains        "T2a module path"     "$GOD" "github.com/geoffgodwin/tekhton"
assert_file_contains_regex  "T2b Go version 1.23" "$GOD" "^go 1\.23"
assert_file_contains_regex  "T2c cobra require"   "$GOD" "github\.com/spf13/cobra"

# =============================================================================
# T3: internal/version/version.go — dev fallback, TrimSpace, String()
# =============================================================================
echo "=== T3: internal/version/version.go content ==="
VER="${TEKHTON_HOME}/internal/version/version.go"
assert_file_contains "T3a package version"   "$VER" "package version"
assert_file_contains "T3b dev sentinel"      "$VER" 'var Version = "dev"'
assert_file_contains "T3c strings.TrimSpace" "$VER" "strings.TrimSpace"
assert_file_contains "T3d String() func"     "$VER" "func String() string"
assert_file_contains "T3e import strings"    "$VER" '"strings"'

# =============================================================================
# T4: cmd/tekhton/main.go — Cobra, version import, RunE, version template
# =============================================================================
echo "=== T4: cmd/tekhton/main.go content ==="
MAIN="${TEKHTON_HOME}/cmd/tekhton/main.go"
assert_file_contains "T4a package main"         "$MAIN" "package main"
assert_file_contains "T4b cobra import"         "$MAIN" "github.com/spf13/cobra"
assert_file_contains "T4c version import"       "$MAIN" "github.com/geoffgodwin/tekhton/internal/version"
assert_file_contains "T4d version.String() use" "$MAIN" "version.String()"
assert_file_contains "T4e version template"     "$MAIN" "SetVersionTemplate"
assert_file_contains "T4f newRootCmd func"      "$MAIN" "func newRootCmd()"
assert_file_contains "T4g RunE defined"         "$MAIN" "RunE:"
assert_file_contains "T4h SilenceErrors"        "$MAIN" "SilenceErrors"
assert_file_contains "T4i SilenceUsage"         "$MAIN" "SilenceUsage"

# =============================================================================
# T5: Makefile — required targets and cross-compile matrix
# =============================================================================
echo "=== T5: Makefile targets and cross-compile matrix ==="
MF="${TEKHTON_HOME}/Makefile"
assert_file_contains_regex "T5a build target"    "$MF" "^build:"
assert_file_contains_regex "T5b test target"     "$MF" "^test:"
assert_file_contains_regex "T5c vet target"      "$MF" "^vet:"
assert_file_contains_regex "T5d lint target"     "$MF" "^lint:"
assert_file_contains_regex "T5e build-all target" "$MF" "^build-all:"
assert_file_contains_regex "T5f tidy target"     "$MF" "^tidy:"
assert_file_contains_regex "T5g clean target"    "$MF" "^clean:"
assert_file_contains       "T5h linux/amd64"     "$MF" "linux/amd64"
assert_file_contains       "T5i linux/arm64"     "$MF" "linux/arm64"
assert_file_contains       "T5j darwin/amd64"    "$MF" "darwin/amd64"
assert_file_contains       "T5k darwin/arm64"    "$MF" "darwin/arm64"
assert_file_contains       "T5l windows/amd64"   "$MF" "windows/amd64"
assert_file_contains       "T5m CGO disabled"    "$MF" "CGO_ENABLED=0"
assert_file_contains       "T5n ldflags version" "$MF" "internal/version.Version"

# =============================================================================
# T6: .github/workflows/go-build.yml — jobs and branch triggers
# =============================================================================
echo "=== T6: CI workflow content ==="
CI="${TEKHTON_HOME}/.github/workflows/go-build.yml"
assert_file_contains "T6a build job"       "$CI" "build:"
assert_file_contains "T6b lint job"        "$CI" "lint:"
assert_file_contains "T6c main branch"     "$CI" "main"
assert_file_contains "T6d setup-go"        "$CI" "setup-go"
assert_file_contains "T6e go-version-file" "$CI" "go-version-file"
assert_file_contains "T6f golangci-lint"   "$CI" "golangci-lint"
assert_file_contains "T6g upload-artifact" "$CI" "upload-artifact"
assert_file_contains "T6h theseus branch"  "$CI" "theseus"

# =============================================================================
# T7: scripts/self-host-check.sh — executable, safe modes, key checks
# =============================================================================
echo "=== T7: scripts/self-host-check.sh structure ==="
SH="${TEKHTON_HOME}/scripts/self-host-check.sh"
assert_executable    "T7a is executable"           "$SH"
assert_file_contains "T7b set -euo pipefail"       "$SH" "set -euo pipefail"
assert_file_contains "T7c make build"              "$SH" "make build"
assert_file_contains "T7d tekhton --version"       "$SH" "tekhton --version"
assert_file_contains "T7e VERSION comparison"      "$SH" "tr -d '[:space:]' < VERSION"
assert_file_contains "T7f TEKHTON_SELF_HOST_DRY_RUN guard" "$SH" "TEKHTON_SELF_HOST_DRY_RUN"
assert_file_contains "T7g dry-run gated"           "$SH" "dry-run"
assert_file_contains "T7h bash entry point check"  "$SH" "tekhton.sh --version"

# =============================================================================
# T8: .gitignore — Go build artifacts excluded
# =============================================================================
echo "=== T8: .gitignore Go artifact exclusions ==="
GI="${TEKHTON_HOME}/.gitignore"
assert_file_contains "T8a bin/ excluded"   "$GI" "bin/"
assert_file_contains "T8b *.test excluded" "$GI" "*.test"

# =============================================================================
# T9: docs/go-build.md — required sections present
# =============================================================================
echo "=== T9: docs/go-build.md coverage ==="
DOC="${TEKHTON_HOME}/docs/go-build.md"
assert_file_contains_icase "T9a prerequisites section" "$DOC" "prerequisite"
assert_file_contains_icase "T9b make targets section"  "$DOC" "make"
assert_file_contains_icase "T9c cross-compile section" "$DOC" "cross"
assert_file_contains_icase "T9d version stamping"      "$DOC" "version"
assert_file_contains_icase "T9e CI artifact"           "$DOC" "(CI|artifact)"

# =============================================================================
# T10: No production bash files modified by M01
# =============================================================================
echo "=== T10: No lib/, stages/, prompts/, tools/ modifications ==="
# These directories were not touched by m01. Verify key files are unmodified
# by checking they don't contain any Go-specific content that would signal
# unwanted cross-contamination.
assert_file_exists "T10a lib/common.sh exists"   "${TEKHTON_HOME}/lib/common.sh"
assert_file_exists "T10b stages/coder.sh exists" "${TEKHTON_HOME}/stages/coder.sh"
assert_file_exists "T10c prompts/coder.prompt.md exists" "${TEKHTON_HOME}/prompts/coder.prompt.md"

# =============================================================================
# T11: version.go — primary behavior: String() is the exported function
# =============================================================================
echo "=== T11: version.go primary behavior invariants ==="
VER="${TEKHTON_HOME}/internal/version/version.go"
# The return statement must call TrimSpace on Version, not return Version raw
assert_file_contains_regex "T11a TrimSpace wraps Version" "$VER" "TrimSpace\(Version\)"
# The dev sentinel distinguishes non-make builds from release builds
assert_file_contains "T11b dev sentinel is lowercase" "$VER" '"dev"'
# Package must be importable as internal/version (package name must match)
actual_pkg=$(grep '^package ' "$VER" | awk '{print $2}')
assert_eq "T11c package name is version" "version" "$actual_pkg"

# =============================================================================
# Summary
# =============================================================================
echo
echo "--------------------------------------"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "--------------------------------------"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "M01 go module foundation tests passed"
