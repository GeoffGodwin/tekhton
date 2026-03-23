#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# detect_test_frameworks.sh — Test framework detection (Milestone 12)
#
# Detects specific test frameworks (separate from TEST_CMD detection).
# The tester agent needs to know "use pytest" vs "use unittest" even when
# TEST_CMD is just "make test".
#
# Sourced by tekhton.sh — do not run directly.
# Provides: detect_test_frameworks()
# =============================================================================

# detect_test_frameworks — Identifies specific test frameworks.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: One line per framework: FRAMEWORK|CONFIG_FILE|CONFIDENCE
detect_test_frameworks() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"

    # --- Python ---
    _detect_python_test_fws "$proj_dir"

    # --- JavaScript/TypeScript ---
    _detect_js_test_fws "$proj_dir"

    # --- Go ---
    if [[ -f "$proj_dir/go.mod" ]]; then
        # Check for test files
        if find "$proj_dir" -maxdepth 3 -name "*_test.go" -not -path "*/vendor/*" 2>/dev/null | head -1 | grep -q .; then
            echo "go-test|go.mod|high"
        fi
        # Check for testify
        if grep -q 'stretchr/testify' "$proj_dir/go.mod" 2>/dev/null; then
            echo "testify|go.mod|high"
        fi
    fi

    # --- Rust ---
    if [[ -f "$proj_dir/Cargo.toml" ]]; then
        echo "cargo-test|Cargo.toml|high"
    fi

    # --- Ruby ---
    if [[ -f "$proj_dir/Gemfile" ]]; then
        if grep -q "'rspec'" "$proj_dir/Gemfile" 2>/dev/null || grep -q '"rspec"' "$proj_dir/Gemfile" 2>/dev/null; then
            echo "rspec|Gemfile|high"
        fi
        if grep -q "'minitest'" "$proj_dir/Gemfile" 2>/dev/null || grep -q '"minitest"' "$proj_dir/Gemfile" 2>/dev/null; then
            echo "minitest|Gemfile|high"
        fi
    fi
    if [[ -f "$proj_dir/.rspec" ]]; then
        echo "rspec|.rspec|high"
    fi

    # --- Java/Kotlin ---
    _detect_java_test_fws "$proj_dir"

    # --- C#/.NET ---
    if compgen -G "$proj_dir"/*.csproj >/dev/null 2>&1; then
        local csproj_content
        csproj_content=$(cat "$proj_dir"/*.csproj 2>/dev/null || true)
        if echo "$csproj_content" | grep -q 'xunit' 2>/dev/null; then
            echo "xunit|*.csproj|high"
        fi
        if echo "$csproj_content" | grep -q 'NUnit' 2>/dev/null; then
            echo "nunit|*.csproj|high"
        fi
        if echo "$csproj_content" | grep -q 'MSTest' 2>/dev/null; then
            echo "mstest|*.csproj|high"
        fi
    fi

    # --- Dart/Flutter ---
    if [[ -f "$proj_dir/pubspec.yaml" ]]; then
        if grep -q 'flutter_test:' "$proj_dir/pubspec.yaml" 2>/dev/null; then
            echo "flutter-test|pubspec.yaml|high"
        elif grep -q 'test:' "$proj_dir/pubspec.yaml" 2>/dev/null; then
            echo "dart-test|pubspec.yaml|high"
        fi
    fi

    # --- Shell ---
    if [[ -f "$proj_dir/tests/run_tests.sh" ]]; then
        echo "shell-tests|tests/run_tests.sh|high"
    fi
    if [[ -f "$proj_dir/test/bats" ]] || find "$proj_dir" -maxdepth 2 -name "*.bats" 2>/dev/null | head -1 | grep -q .; then
        echo "bats|*.bats|high"
    fi
}

# --- Python test framework helpers -------------------------------------------

_detect_python_test_fws() {
    local proj_dir="$1"

    # pytest
    if [[ -f "$proj_dir/pytest.ini" ]]; then
        echo "pytest|pytest.ini|high"
    elif [[ -f "$proj_dir/conftest.py" ]]; then
        echo "pytest|conftest.py|high"
    elif [[ -f "$proj_dir/pyproject.toml" ]] && grep -q '\[tool.pytest' "$proj_dir/pyproject.toml" 2>/dev/null; then
        echo "pytest|pyproject.toml|high"
    elif [[ -f "$proj_dir/setup.cfg" ]] && grep -q '\[tool:pytest\]' "$proj_dir/setup.cfg" 2>/dev/null; then
        echo "pytest|setup.cfg|high"
    elif [[ -f "$proj_dir/tox.ini" ]] && grep -q 'pytest' "$proj_dir/tox.ini" 2>/dev/null; then
        echo "pytest|tox.ini|medium"
    elif [[ -f "$proj_dir/pyproject.toml" ]] || [[ -f "$proj_dir/requirements.txt" ]]; then
        # Check if pytest is a dependency
        if grep -q 'pytest' "$proj_dir/pyproject.toml" 2>/dev/null || \
           grep -q 'pytest' "$proj_dir/requirements.txt" 2>/dev/null; then
            echo "pytest|requirements|medium"
        fi
    fi

    # unittest (check for test files using unittest patterns)
    if find "$proj_dir" -maxdepth 3 -name "test_*.py" -not -path "*/.venv/*" 2>/dev/null | head -1 | grep -q .; then
        # If pytest is already detected, unittest files may just be pytest-compatible
        if [[ ! -f "$proj_dir/pytest.ini" ]] && [[ ! -f "$proj_dir/conftest.py" ]]; then
            if ! grep -q 'pytest' "$proj_dir/pyproject.toml" 2>/dev/null && \
               ! grep -q 'pytest' "$proj_dir/requirements.txt" 2>/dev/null; then
                echo "unittest|test_*.py|medium"
            fi
        fi
    fi
}

# --- JS/TS test framework helpers --------------------------------------------

_detect_js_test_fws() {
    local proj_dir="$1"
    [[ ! -f "$proj_dir/package.json" ]] && return 0

    local pkg_content
    pkg_content=$(cat "$proj_dir/package.json" 2>/dev/null || true)

    # Jest
    if echo "$pkg_content" | grep -q '"jest"' 2>/dev/null; then
        local conf="package.json"
        [[ -f "$proj_dir/jest.config.js" ]] && conf="jest.config.js"
        [[ -f "$proj_dir/jest.config.ts" ]] && conf="jest.config.ts"
        echo "jest|${conf}|high"
    fi

    # Vitest
    if echo "$pkg_content" | grep -q '"vitest"' 2>/dev/null; then
        local conf="package.json"
        [[ -f "$proj_dir/vitest.config.ts" ]] && conf="vitest.config.ts"
        [[ -f "$proj_dir/vitest.config.js" ]] && conf="vitest.config.js"
        echo "vitest|${conf}|high"
    fi

    # Mocha
    if echo "$pkg_content" | grep -q '"mocha"' 2>/dev/null; then
        local conf="package.json"
        [[ -f "$proj_dir/.mocharc.yml" ]] && conf=".mocharc.yml"
        [[ -f "$proj_dir/.mocharc.yaml" ]] && conf=".mocharc.yaml"
        echo "mocha|${conf}|high"
    fi

    # Cypress (E2E)
    if echo "$pkg_content" | grep -q '"cypress"' 2>/dev/null; then
        local conf="package.json"
        [[ -f "$proj_dir/cypress.config.js" ]] && conf="cypress.config.js"
        [[ -f "$proj_dir/cypress.config.ts" ]] && conf="cypress.config.ts"
        echo "cypress|${conf}|high"
    fi

    # Playwright (E2E)
    if echo "$pkg_content" | grep -q '"@playwright/test"' 2>/dev/null || echo "$pkg_content" | grep -q '"playwright"' 2>/dev/null; then
        local conf="package.json"
        [[ -f "$proj_dir/playwright.config.ts" ]] && conf="playwright.config.ts"
        [[ -f "$proj_dir/playwright.config.js" ]] && conf="playwright.config.js"
        echo "playwright|${conf}|high"
    fi
}

# --- Java/Kotlin test framework helpers --------------------------------------

_detect_java_test_fws() {
    local proj_dir="$1"

    if [[ -f "$proj_dir/build.gradle" ]] || [[ -f "$proj_dir/build.gradle.kts" ]]; then
        local gradle_file="$proj_dir/build.gradle"
        [[ -f "$proj_dir/build.gradle.kts" ]] && gradle_file="$proj_dir/build.gradle.kts"
        if grep -q 'junit' "$gradle_file" 2>/dev/null; then
            echo "junit|$(basename "$gradle_file")|high"
        fi
    elif [[ -f "$proj_dir/pom.xml" ]]; then
        if grep -q 'junit' "$proj_dir/pom.xml" 2>/dev/null; then
            echo "junit|pom.xml|high"
        fi
    fi
}
