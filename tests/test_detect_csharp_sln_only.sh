#!/usr/bin/env bash
# Test: detect.sh — C# detection with .sln-only project and error suppression
# Verifies the 2>/dev/null fix on basename in the C#/.NET detection block.
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

# Source detection library
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"

# Helper: make a fresh project dir
make_proj() {
    local name="$1"
    local dir="${TEST_TMPDIR}/${name}"
    mkdir -p "$dir"
    echo "$dir"
}

# =============================================================================
# Test 1: .sln-only project (no .csproj) — manifest should be "*.sln"
# =============================================================================
echo "=== detect_languages: C# with only .sln file ==="

SLN_DIR=$(make_proj "csharp_sln_only")
touch "$SLN_DIR/MyApp.sln"

sln_langs=$(detect_languages "$SLN_DIR")

if echo "$sln_langs" | grep -q "^csharp|"; then
    pass "C# detected with .sln-only project"
else
    fail "C# NOT detected with .sln-only project: got: $sln_langs"
fi

if echo "$sln_langs" | grep "^csharp|" | grep -q "\*.sln"; then
    pass "C# manifest is *.sln for .sln-only project"
else
    fail "C# manifest should be *.sln for .sln-only project: $sln_langs"
fi

# =============================================================================
# Test 2: .sln-only project produces no stderr
# =============================================================================
echo "=== detect_languages: .sln-only project generates no stderr ==="

SLN_DIR2=$(make_proj "csharp_sln_no_stderr")
touch "$SLN_DIR2/Solution.sln"

stderr_output=$(detect_languages "$SLN_DIR2" 2>&1 1>/dev/null)
if [[ -z "$stderr_output" ]]; then
    pass ".sln-only C# detection produces no stderr output"
else
    fail ".sln-only C# detection produced stderr: $stderr_output"
fi

# =============================================================================
# Test 3: .csproj project — manifest should be the filename, not "*.sln"
# =============================================================================
echo "=== detect_languages: C# with .csproj file ==="

CSPROJ_DIR=$(make_proj "csharp_csproj")
cat > "$CSPROJ_DIR/MyApp.csproj" << 'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <OutputType>Exe</OutputType>
  </PropertyGroup>
</Project>
EOF

csproj_langs=$(detect_languages "$CSPROJ_DIR")

if echo "$csproj_langs" | grep -q "^csharp|"; then
    pass "C# detected with .csproj project"
else
    fail "C# NOT detected with .csproj project: got: $csproj_langs"
fi

if echo "$csproj_langs" | grep "^csharp|" | grep -q "MyApp.csproj"; then
    pass "C# manifest is the actual .csproj filename"
else
    fail "C# manifest should be MyApp.csproj: $csproj_langs"
fi

# =============================================================================
# Test 4: .csproj project produces no stderr (basename 2>/dev/null fix)
# =============================================================================
echo "=== detect_languages: .csproj project generates no stderr ==="

CSPROJ_DIR2=$(make_proj "csharp_csproj_no_stderr")
cat > "$CSPROJ_DIR2/App.csproj" << 'EOF'
<Project Sdk="Microsoft.NET.Sdk">
</Project>
EOF

stderr_output=$(detect_languages "$CSPROJ_DIR2" 2>&1 1>/dev/null)
if [[ -z "$stderr_output" ]]; then
    pass ".csproj C# detection produces no stderr output"
else
    fail ".csproj C# detection produced stderr: $stderr_output"
fi

# =============================================================================
# Test 5: .csproj project with high source file count gets high confidence
# =============================================================================
echo "=== detect_languages: .csproj + .cs files → high confidence ==="

CS_DIR=$(make_proj "csharp_full")
cat > "$CS_DIR/App.csproj" << 'EOF'
<Project Sdk="Microsoft.NET.Sdk">
</Project>
EOF
touch "$CS_DIR/Program.cs" "$CS_DIR/Service.cs" "$CS_DIR/Model.cs"

cs_langs=$(detect_languages "$CS_DIR")

if echo "$cs_langs" | grep "^csharp|" | grep -q "high"; then
    pass "C# confidence is high when .csproj + .cs files present"
else
    fail "C# confidence not high with .csproj + .cs files: $cs_langs"
fi

# =============================================================================
# Test 6: .sln-only project has medium confidence (manifest, no source files)
# =============================================================================
echo "=== detect_languages: .sln-only → medium confidence ==="

SLN_MEDIUM_DIR=$(make_proj "csharp_sln_medium")
touch "$SLN_MEDIUM_DIR/Solution.sln"

sln_medium_langs=$(detect_languages "$SLN_MEDIUM_DIR")

if echo "$sln_medium_langs" | grep "^csharp|" | grep -q "medium"; then
    pass "C# confidence is medium for .sln-only (manifest but no source files)"
else
    fail "C# confidence should be medium for .sln-only: $sln_medium_langs"
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
