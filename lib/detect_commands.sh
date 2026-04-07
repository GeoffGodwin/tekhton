#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# detect_commands.sh — Command inference, entry point detection, project type
#                      classification
#
# Sourced by tekhton.sh — do not run directly.
# Depends on: detect.sh (detect_languages, detect_frameworks)
# =============================================================================

# --- Command detection --------------------------------------------------------

# detect_commands — Infers build, test, and lint commands from manifests + conventions.
# Priority cascade:
#   1. CI/CD config (highest confidence — this is what actually runs)
#   2. Makefile / Taskfile / justfile targets
#   3. Package manager scripts (package.json, pyproject.toml)
#   4. Convention-based fallback (lowest confidence)
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: One line per command: CMD_TYPE|COMMAND|SOURCE|CONFIDENCE
detect_commands() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"

    # Collect all commands, then deduplicate by type preferring highest confidence
    local all_commands=""
    all_commands=$(_detect_commands_raw "$proj_dir")

    # Deduplicate: for each cmd_type, keep the highest-confidence entry
    local -A seen_types=()
    local line cmd_type conf
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        cmd_type=$(echo "$line" | cut -d'|' -f1)
        conf=$(echo "$line" | cut -d'|' -f4)
        local existing_conf="${seen_types[$cmd_type]:-}"
        if [[ -z "$existing_conf" ]] || _conf_higher "$conf" "$existing_conf"; then
            seen_types[$cmd_type]="$conf"
        fi
    done <<< "$all_commands"

    # Emit deduplicated (first entry of highest confidence per type)
    local -A emitted_types=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        cmd_type=$(echo "$line" | cut -d'|' -f1)
        conf=$(echo "$line" | cut -d'|' -f4)
        if [[ -z "${emitted_types[$cmd_type]+x}" ]] && [[ "$conf" == "${seen_types[$cmd_type]}" ]]; then
            echo "$line"
            emitted_types[$cmd_type]=1
        fi
    done <<< "$all_commands"
}

# _conf_higher — Returns 0 if $1 is higher confidence than $2.
_conf_higher() {
    local a="$1" b="$2"
    local -A rank=([high]=3 [medium]=2 [low]=1)
    [[ "${rank[$a]:-0}" -gt "${rank[$b]:-0}" ]]
}

# _detect_commands_raw — Collects commands from all sources (unsorted).
_detect_commands_raw() {
    local proj_dir="$1"

    # --- CI/CD detected commands (highest priority) ---
    if type -t detect_ci_config &>/dev/null; then
        _inject_ci_commands "$proj_dir"
    fi

    # --- Makefile / Taskfile / justfile (priority 2) ---
    _detect_makefile_commands "$proj_dir"

    # --- Package manager scripts (priority 3) ---
    _detect_package_commands "$proj_dir"

    # --- Pre-commit hooks as authoritative linter source ---
    _detect_precommit_linters "$proj_dir"
}

# _inject_ci_commands — Extracts build/test/lint from CI detection output.
_inject_ci_commands() {
    local proj_dir="$1"
    local ci_output
    ci_output=$(detect_ci_config "$proj_dir" 2>/dev/null || true)
    [[ -z "$ci_output" ]] && return 0

    local line ci_sys build_cmd test_cmd lint_cmd conf
    while IFS='|' read -r ci_sys build_cmd test_cmd lint_cmd _deploy _lang conf; do
        [[ -z "$ci_sys" ]] && continue
        local ci_conf="${conf:-high}"
        [[ -n "$build_cmd" ]] && echo "build|${build_cmd}|${ci_sys} CI|${ci_conf}"
        [[ -n "$test_cmd" ]] && echo "test|${test_cmd}|${ci_sys} CI|${ci_conf}"
        [[ -n "$lint_cmd" ]] && echo "analyze|${lint_cmd}|${ci_sys} CI|${ci_conf}"
    done <<< "$ci_output"
}

# _detect_makefile_commands — Check Makefile, Taskfile, justfile.
_detect_makefile_commands() {
    local proj_dir="$1"

    if [[ -f "$proj_dir/Makefile" ]]; then
        grep -q '^test:' "$proj_dir/Makefile" 2>/dev/null && echo "test|make test|Makefile test target|high"
        grep -q '^lint:' "$proj_dir/Makefile" 2>/dev/null && echo "analyze|make lint|Makefile lint target|high"
        grep -q '^build:' "$proj_dir/Makefile" 2>/dev/null && echo "build|make build|Makefile build target|high"
    fi

    if [[ -f "$proj_dir/Taskfile.yml" ]] || [[ -f "$proj_dir/Taskfile.yaml" ]]; then
        local taskfile="$proj_dir/Taskfile.yml"
        [[ -f "$proj_dir/Taskfile.yaml" ]] && taskfile="$proj_dir/Taskfile.yaml"
        grep -q 'test:' "$taskfile" 2>/dev/null && echo "test|task test|Taskfile test target|high"
        grep -q 'lint:' "$taskfile" 2>/dev/null && echo "analyze|task lint|Taskfile lint target|high"
        grep -q 'build:' "$taskfile" 2>/dev/null && echo "build|task build|Taskfile build target|high"
    fi

    if [[ -f "$proj_dir/justfile" ]]; then
        grep -q '^test' "$proj_dir/justfile" 2>/dev/null && echo "test|just test|justfile test recipe|high"
        grep -q '^lint' "$proj_dir/justfile" 2>/dev/null && echo "analyze|just lint|justfile lint recipe|high"
        grep -q '^build' "$proj_dir/justfile" 2>/dev/null && echo "build|just build|justfile build recipe|high"
    fi
}

# _detect_package_commands — Original package manager detection.
_detect_package_commands() {
    local proj_dir="$1"

    # --- Package.json scripts ---
    if [[ -f "$proj_dir/package.json" ]]; then
        local scripts
        scripts=$(_extract_json_keys "$proj_dir/package.json" '"scripts"')

        local test_cmd
        test_cmd=$(echo "$scripts" | grep '"test"' | head -1 | sed 's/.*: *"\(.*\)".*/\1/' || true)
        if [[ -n "$test_cmd" ]] && [[ "$test_cmd" != *"no test specified"* ]]; then
            echo "test|npm test|package.json scripts.test|high"
        fi

        local lint_cmd
        lint_cmd=$(echo "$scripts" | grep '"lint"' | head -1 | sed 's/.*: *"\(.*\)".*/\1/' || true)
        if [[ -n "$lint_cmd" ]]; then
            echo "analyze|npm run lint|package.json scripts.lint|high"
        elif [[ -d "$proj_dir/node_modules/.bin" ]] && [[ -x "$proj_dir/node_modules/.bin/eslint" ]]; then
            echo "analyze|npx eslint .|node_modules/.bin/eslint exists|medium"
        fi

        local build_cmd
        build_cmd=$(echo "$scripts" | grep '"build"' | head -1 | sed 's/.*: *"\(.*\)".*/\1/' || true)
        if [[ -n "$build_cmd" ]]; then
            echo "build|npm run build|package.json scripts.build|high"
        fi
    fi

    # --- Cargo.toml (Rust) ---
    if [[ -f "$proj_dir/Cargo.toml" ]]; then
        echo "test|cargo test|Cargo.toml present|high"
        echo "build|cargo build|Cargo.toml present|high"
        echo "analyze|cargo clippy|Cargo.toml present|medium"
    fi

    # --- pyproject.toml / Python ---
    if [[ -f "$proj_dir/pyproject.toml" ]]; then
        local pyconf
        pyconf=$(cat "$proj_dir/pyproject.toml" 2>/dev/null)
        if echo "$pyconf" | grep -q '\[tool.pytest' 2>/dev/null; then
            echo "test|pytest|pyproject.toml [tool.pytest]|high"
        else
            echo "test|pytest|pyproject.toml present|medium"
        fi
        if echo "$pyconf" | grep -q '\[tool.ruff' 2>/dev/null; then
            echo "analyze|ruff check .|pyproject.toml [tool.ruff]|high"
        elif echo "$pyconf" | grep -q '\[tool.flake8' 2>/dev/null; then
            echo "analyze|flake8 .|pyproject.toml [tool.flake8]|high"
        else
            echo "analyze|ruff check .|convention|low"
        fi
    elif [[ -f "$proj_dir/requirements.txt" ]] || [[ -f "$proj_dir/setup.py" ]]; then
        echo "test|pytest|Python project detected|medium"
        echo "analyze|ruff check .|convention|low"
    fi

    # --- go.mod (Go) ---
    if [[ -f "$proj_dir/go.mod" ]]; then
        echo "test|go test ./...|go.mod present|high"
        echo "build|go build ./...|go.mod present|high"
        echo "analyze|go vet ./...|go.mod present|high"
    fi

    # --- Gemfile (Ruby) ---
    if [[ -f "$proj_dir/Gemfile" ]]; then
        if grep -q 'rspec' "$proj_dir/Gemfile" 2>/dev/null; then
            echo "test|bundle exec rspec|rspec in Gemfile|high"
        elif grep -q 'minitest' "$proj_dir/Gemfile" 2>/dev/null; then
            echo "test|bundle exec rake test|minitest in Gemfile|high"
        fi
        if grep -q 'rubocop' "$proj_dir/Gemfile" 2>/dev/null; then
            echo "analyze|bundle exec rubocop|rubocop in Gemfile|high"
        fi
    fi

    # --- build.gradle / pom.xml (Java/Kotlin) ---
    if [[ -f "$proj_dir/build.gradle" ]] || [[ -f "$proj_dir/build.gradle.kts" ]]; then
        echo "test|./gradlew test|build.gradle present|high"
        echo "build|./gradlew build|build.gradle present|high"
    elif [[ -f "$proj_dir/pom.xml" ]]; then
        echo "test|mvn test|pom.xml present|high"
        echo "build|mvn package|pom.xml present|high"
    fi

    # --- .csproj (C#/.NET) ---
    if compgen -G "$proj_dir"/*.csproj >/dev/null 2>&1 || compgen -G "$proj_dir"/*.sln >/dev/null 2>&1; then
        echo "test|dotnet test|.csproj present|high"
        echo "build|dotnet build|.csproj present|high"
    fi

    # --- pubspec.yaml (Dart/Flutter) ---
    if [[ -f "$proj_dir/pubspec.yaml" ]]; then
        if grep -q 'flutter:' "$proj_dir/pubspec.yaml" 2>/dev/null; then
            echo "test|flutter test|flutter in pubspec.yaml|high"
            echo "build|flutter build|flutter in pubspec.yaml|high"
            echo "analyze|flutter analyze|flutter in pubspec.yaml|high"
        else
            echo "test|dart test|pubspec.yaml present|high"
            echo "analyze|dart analyze|pubspec.yaml present|high"
        fi
    fi

    # --- mix.exs (Elixir) ---
    if [[ -f "$proj_dir/mix.exs" ]]; then
        echo "test|mix test|mix.exs present|high"
        echo "build|mix compile|mix.exs present|high"
    fi

    # --- Shell project (tekhton-like) ---
    if [[ -f "$proj_dir/tests/run_tests.sh" ]]; then
        echo "test|bash tests/run_tests.sh|tests/run_tests.sh exists|high"
    fi
}

# _detect_precommit_linters — Pre-commit hooks as authoritative lint source.
_detect_precommit_linters() {
    local proj_dir="$1"
    [[ ! -f "$proj_dir/.pre-commit-config.yaml" ]] && return 0

    # Extract repo hooks for common linters
    local content
    content=$(cat "$proj_dir/.pre-commit-config.yaml" 2>/dev/null || true)
    if echo "$content" | grep -q 'eslint' 2>/dev/null; then
        echo "analyze|npx eslint .|.pre-commit-config.yaml|high"
    fi
    if echo "$content" | grep -q 'ruff' 2>/dev/null; then
        echo "analyze|ruff check .|.pre-commit-config.yaml|high"
    fi
    if echo "$content" | grep -q 'black' 2>/dev/null; then
        echo "format|black .|.pre-commit-config.yaml|high"
    fi
    if echo "$content" | grep -q 'prettier' 2>/dev/null; then
        echo "format|npx prettier --check .|.pre-commit-config.yaml|high"
    fi
    if echo "$content" | grep -q 'shellcheck' 2>/dev/null; then
        echo "analyze|shellcheck|.pre-commit-config.yaml|high"
    fi
    if echo "$content" | grep -q 'mypy' 2>/dev/null; then
        echo "analyze|mypy .|.pre-commit-config.yaml|high"
    fi
}

# --- UI test command detection (Milestone 28) ---------------------------------

# detect_ui_test_cmd — Infers E2E / UI test command from framework and scripts.
# Args: $1 = project directory, $2 = detected UI framework (optional)
# Output: command string, or empty if none detected
# Priority: CI config > package.json e2e scripts > framework convention
detect_ui_test_cmd() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"
    local framework="${2:-${UI_FRAMEWORK:-}}"

    # --- Priority 1: CI config referencing E2E commands ---
    if type -t detect_ci_config &>/dev/null; then
        local ci_output
        ci_output=$(detect_ci_config "$proj_dir" 2>/dev/null || true)
        if [[ -n "$ci_output" ]]; then
            local line
            while IFS='|' read -r _ci_sys _build_cmd test_cmd _lint_cmd _deploy _lang _conf; do
                [[ -z "$test_cmd" ]] && continue
                # Check if CI test command looks like an E2E command
                if echo "$test_cmd" | grep -qiE 'playwright|cypress|e2e|selenium|detox' 2>/dev/null; then
                    echo "$test_cmd"
                    return 0
                fi
            done <<< "$ci_output"
        fi
    fi

    # --- Priority 2: package.json e2e/ui-related scripts ---
    if [[ -f "$proj_dir/package.json" ]]; then
        local scripts
        scripts=$(_extract_json_keys "$proj_dir/package.json" '"scripts"')
        local script_name
        for script_name in "test:e2e" "e2e" "test:ui" "test:integration"; do
            if echo "$scripts" | grep -q "\"${script_name}\"" 2>/dev/null; then
                echo "npm run ${script_name}"
                return 0
            fi
        done
    fi

    # --- Priority 3: Framework convention ---
    case "$framework" in
        playwright)  echo "npx playwright test" ;;
        cypress)     echo "npx cypress run" ;;
        detox)       echo "npx detox test" ;;
        selenium)
            if [[ -f "$proj_dir/requirements.txt" ]]; then
                echo "pytest tests/ -k e2e"
            fi
            ;;
        *)           return 0 ;;  # No command inferred
    esac
}

# --- Entry point detection ----------------------------------------------------

# detect_entry_points — Identifies likely application entry points.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: One file path per line (relative to project dir)
detect_entry_points() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"

    local -a candidates=(
        "main.py" "app.py" "manage.py"
        "index.ts" "index.js" "src/index.ts" "src/index.js" "src/main.ts" "src/main.js"
        "src/main.rs"
        "cmd/main.go" "main.go"
        "lib/main.dart"
        "Program.cs"
        "App.java" "src/main/java/App.java"
        "app/Main.hs"
        "lib/index.rb" "config.ru"
        "Makefile"
        "docker-compose.yml" "docker-compose.yaml" "Dockerfile"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        [[ -f "$proj_dir/$candidate" ]] && echo "$candidate"
    done

    # Go cmd/ pattern — find cmd/*/main.go
    if [[ -d "$proj_dir/cmd" ]]; then
        local cmd_dir
        for cmd_dir in "$proj_dir"/cmd/*/; do
            [[ -f "${cmd_dir}main.go" ]] && echo "${cmd_dir#"$proj_dir/"}main.go"
        done
    fi
}

# --- Project type classification ----------------------------------------------

# detect_project_type — Classifies project into one of the --plan template categories.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: One of: web-app, web-game, cli-tool, api-service, mobile-app, library, custom
detect_project_type() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"
    # Accept pre-computed results to avoid redundant detection calls
    local languages="${2:-$(detect_languages "$proj_dir")}"
    local frameworks="${3:-$(detect_frameworks "$proj_dir")}"
    local entry_points="${4:-$(detect_entry_points "$proj_dir")}"

    # Mobile app detection (highest priority — unambiguous)
    if echo "$frameworks" | grep -q 'flutter\|swiftui' 2>/dev/null; then
        echo "mobile-app"
        return 0
    fi
    if [[ -f "$proj_dir/pubspec.yaml" ]] && grep -q 'flutter:' "$proj_dir/pubspec.yaml" 2>/dev/null; then
        echo "mobile-app"
        return 0
    fi

    # Web app detection (frontend frameworks)
    if echo "$frameworks" | grep -qE 'next\.js|react|vue|angular|svelte' 2>/dev/null; then
        echo "web-app"
        return 0
    fi
    # Pages/routes directory heuristic
    if [[ -d "$proj_dir/src/pages" ]] || [[ -d "$proj_dir/pages" ]] || [[ -d "$proj_dir/src/routes" ]]; then
        echo "web-app"
        return 0
    fi

    # API service detection (backend frameworks without frontend)
    if echo "$frameworks" | grep -qE 'express|fastify|django|flask|fastapi|rails|spring-boot|asp\.net|actix|axum|gin' 2>/dev/null; then
        echo "api-service"
        return 0
    fi

    # Web game detection (canvas/game-related deps in package.json)
    if [[ -f "$proj_dir/package.json" ]]; then
        local pkg_content
        pkg_content=$(cat "$proj_dir/package.json" 2>/dev/null)
        if echo "$pkg_content" | grep -qE '"phaser"|"pixi"|"three"|"babylon"' 2>/dev/null; then
            echo "web-game"
            return 0
        fi
    fi

    # CLI tool detection
    if echo "$entry_points" | grep -qE 'cmd/.*/main\.go|src/main\.rs' 2>/dev/null; then
        # Check for CLI argument parsing libraries
        if [[ -f "$proj_dir/Cargo.toml" ]] && grep -qE 'clap|structopt|argh' "$proj_dir/Cargo.toml" 2>/dev/null; then
            echo "cli-tool"
            return 0
        fi
        if [[ -f "$proj_dir/go.mod" ]] && grep -qE 'cobra|urfave/cli' "$proj_dir/go.mod" 2>/dev/null; then
            echo "cli-tool"
            return 0
        fi
    fi
    # Shell projects are typically CLI tools
    local primary_lang
    primary_lang=$(echo "$languages" | head -1 | cut -d'|' -f1)
    if [[ "$primary_lang" == "shell" ]]; then
        echo "cli-tool"
        return 0
    fi

    # Library detection (no entry points, has manifest)
    if [[ -z "$entry_points" ]] && [[ -n "$languages" ]]; then
        # Check for library indicators
        if [[ -f "$proj_dir/Cargo.toml" ]] && grep -q '\[lib\]' "$proj_dir/Cargo.toml" 2>/dev/null; then
            echo "library"
            return 0
        fi
        if [[ -f "$proj_dir/package.json" ]]; then
            local pkg
            pkg=$(cat "$proj_dir/package.json" 2>/dev/null)
            if echo "$pkg" | grep -q '"main"' 2>/dev/null && ! echo "$pkg" | grep -q '"start"' 2>/dev/null; then
                echo "library"
                return 0
            fi
        fi
    fi

    # Fallback
    echo "custom"
}
