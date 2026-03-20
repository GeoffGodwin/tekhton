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
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: One line per command: CMD_TYPE|COMMAND|SOURCE|CONFIDENCE
detect_commands() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"

    # --- Package.json scripts (highest priority for Node.js) ---
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

    # --- Makefile (universal fallback) ---
    if [[ -f "$proj_dir/Makefile" ]]; then
        grep -q '^test:' "$proj_dir/Makefile" 2>/dev/null && echo "test|make test|Makefile test target|high"
        grep -q '^lint:' "$proj_dir/Makefile" 2>/dev/null && echo "analyze|make lint|Makefile lint target|high"
        grep -q '^build:' "$proj_dir/Makefile" 2>/dev/null && echo "build|make build|Makefile build target|high"
    fi

    # --- Shell project (tekhton-like) ---
    if [[ -f "$proj_dir/tests/run_tests.sh" ]]; then
        echo "test|bash tests/run_tests.sh|tests/run_tests.sh exists|high"
    fi
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
