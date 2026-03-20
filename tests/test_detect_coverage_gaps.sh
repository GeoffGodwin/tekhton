#!/usr/bin/env bash
# Test: Milestone 17 — Coverage gaps: Cargo [lib] library type, Spring Boot, ASP.NET frameworks
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

# Source detection libraries
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck source=../lib/detect_commands.sh
source "${TEKHTON_HOME}/lib/detect_commands.sh"

# Helper: make a fresh project dir
make_proj() {
    local name="$1"
    local dir="${TEST_TMPDIR}/${name}"
    mkdir -p "$dir"
    echo "$dir"
}

# =============================================================================
# detect_project_type — Cargo.toml [lib] library detection (lines 246-249)
# =============================================================================
echo "=== detect_project_type: Rust library via [lib] in Cargo.toml (manifest only) ==="

LIB_DIR=$(make_proj "rust_lib")
cat > "$LIB_DIR/Cargo.toml" << 'EOF'
[package]
name = "my-lib"
version = "0.1.0"
edition = "2021"

[lib]
name = "mylib"
crate-type = ["cdylib"]

[dependencies]
serde = "1.0"
EOF

lib_type=$(detect_project_type "$LIB_DIR")
if [[ "$lib_type" == "library" ]]; then
    pass "Cargo.toml [lib] project without src/lib.rs classified as library"
else
    fail "Expected library for Cargo.toml [lib] project (manifest only), got: $lib_type"
fi

# Test that a typical Rust library WITH src/lib.rs is correctly classified as library
# (Bug fixed: src/lib.rs was previously listed as an entry point candidate, blocking
# the library detection path. It has been removed from detect_entry_points candidates.)
echo "=== detect_project_type: Rust library WITH src/lib.rs (fixed: returns library) ==="

LIB_WITH_SRC_DIR=$(make_proj "rust_lib_with_src")
cat > "$LIB_WITH_SRC_DIR/Cargo.toml" << 'EOF'
[package]
name = "my-lib"
version = "0.1.0"

[lib]
name = "mylib"
EOF
mkdir -p "$LIB_WITH_SRC_DIR/src"
touch "$LIB_WITH_SRC_DIR/src/lib.rs"

lib_with_src_type=$(detect_project_type "$LIB_WITH_SRC_DIR")
if [[ "$lib_with_src_type" == "library" ]]; then
    pass "Cargo.toml [lib] + src/lib.rs correctly classified as library (bug fix verified)"
else
    fail "Expected library for Cargo.toml [lib] + src/lib.rs, got: $lib_with_src_type"
fi

# =============================================================================
# detect_frameworks — Spring Boot via build.gradle
# =============================================================================
echo "=== detect_frameworks: Spring Boot (build.gradle) ==="

SB_DIR=$(make_proj "spring_boot")
cat > "$SB_DIR/build.gradle" << 'EOF'
plugins {
    id 'org.springframework.boot' version '3.1.0'
    id 'io.spring.dependency-management' version '1.1.0'
    id 'java'
}

group = 'com.example'
version = '0.0.1-SNAPSHOT'

dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-web'
    testImplementation 'org.springframework.boot:spring-boot-starter-test'
}
EOF

sb_frameworks=$(detect_frameworks "$SB_DIR")
if echo "$sb_frameworks" | grep -q 'spring-boot'; then
    pass "Spring Boot detected from build.gradle"
else
    fail "Spring Boot not detected from build.gradle: $sb_frameworks"
fi

# Verify output format FRAMEWORK|LANG|EVIDENCE
if echo "$sb_frameworks" | grep -q '^spring-boot|java|'; then
    pass "Spring Boot framework output has correct FRAMEWORK|LANG|EVIDENCE format"
else
    fail "Spring Boot framework output format incorrect: $sb_frameworks"
fi

# =============================================================================
# detect_frameworks — Spring Boot via build.gradle.kts (Kotlin DSL)
# =============================================================================
echo "=== detect_frameworks: Spring Boot (build.gradle.kts) ==="

SB_KTS_DIR=$(make_proj "spring_boot_kts")
cat > "$SB_KTS_DIR/build.gradle.kts" << 'EOF'
plugins {
    id("org.springframework.boot") version "3.1.0"
    id("io.spring.dependency-management") version "1.1.0"
    kotlin("jvm") version "1.8.22"
}

dependencies {
    implementation("org.springframework.boot:spring-boot-starter-web")
}
EOF

sb_kts_frameworks=$(detect_frameworks "$SB_KTS_DIR")
if echo "$sb_kts_frameworks" | grep -q 'spring-boot'; then
    pass "Spring Boot detected from build.gradle.kts"
else
    fail "Spring Boot not detected from build.gradle.kts: $sb_kts_frameworks"
fi

# =============================================================================
# detect_frameworks — ASP.NET via .csproj
# =============================================================================
echo "=== detect_frameworks: ASP.NET (.csproj) ==="

ASPNET_DIR=$(make_proj "aspnet_proj")
cat > "$ASPNET_DIR/MyApp.csproj" << 'EOF'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.AspNetCore.OpenApi" Version="8.0.0" />
  </ItemGroup>
</Project>
EOF

aspnet_frameworks=$(detect_frameworks "$ASPNET_DIR")
if echo "$aspnet_frameworks" | grep -q 'asp\.net'; then
    pass "ASP.NET detected from .csproj with Microsoft.AspNetCore reference"
else
    fail "ASP.NET not detected from .csproj: $aspnet_frameworks"
fi

# Verify output format
if echo "$aspnet_frameworks" | grep -q '^asp\.net|csharp|'; then
    pass "ASP.NET framework output has correct FRAMEWORK|LANG|EVIDENCE format"
else
    fail "ASP.NET framework output format incorrect: $aspnet_frameworks"
fi

# =============================================================================
# detect_frameworks — .csproj without AspNetCore does NOT produce asp.net
# =============================================================================
echo "=== detect_frameworks: .csproj without AspNetCore (no false positive) ==="

CONSOLE_DIR=$(make_proj "csharp_console")
cat > "$CONSOLE_DIR/MyConsole.csproj" << 'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <OutputType>Exe</OutputType>
  </PropertyGroup>
</Project>
EOF

console_frameworks=$(detect_frameworks "$CONSOLE_DIR")
if ! echo "$console_frameworks" | grep -q 'asp\.net'; then
    pass "Non-web .csproj does not produce asp.net false positive"
else
    fail "Non-web .csproj incorrectly detected as asp.net: $console_frameworks"
fi

# =============================================================================
# detect_project_type — Spring Boot project classified as api-service
# =============================================================================
echo "=== detect_project_type: Spring Boot → api-service ==="

sb_type=$(detect_project_type "$SB_DIR")
if [[ "$sb_type" == "api-service" ]]; then
    pass "Spring Boot project classified as api-service"
else
    fail "Expected api-service for Spring Boot project, got: $sb_type"
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
