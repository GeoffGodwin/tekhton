#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# detect.sh — Tech stack detection: languages, frameworks, and manifest parsing
#
# Sourced by tekhton.sh — do not run directly.
# Provides: detect_languages(), detect_frameworks()
# Depends on: common.sh (log, warn)
# =============================================================================

# --- Exclusion list (matches _generate_codebase_summary in replan_brownfield.sh) ---

_DETECT_EXCLUDE_DIRS="node_modules|.git|__pycache__|.dart_tool|build|dist|.next|vendor|third_party|.bundle|.gradle|target|.build|Pods|.pub-cache|.cargo"

# --- Language detection -------------------------------------------------------

# detect_languages — Scans file extensions, shebangs, and manifest files.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: One line per language: LANG|CONFIDENCE|MANIFEST
# Confidence: high (manifest + source), medium (manifest OR source), low (few sources)
detect_languages() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"
    local -A lang_manifest=()
    local -A lang_source_count=()

    # --- Manifest detection ---
    [[ -f "$proj_dir/package.json" ]] && {
        if [[ -f "$proj_dir/tsconfig.json" ]] || _has_source_files "$proj_dir" "ts tsx"; then
            lang_manifest[typescript]="package.json"
        else
            lang_manifest[javascript]="package.json"
        fi
    }
    [[ -f "$proj_dir/Cargo.toml" ]]        && lang_manifest[rust]="Cargo.toml"
    [[ -f "$proj_dir/go.mod" ]]            && lang_manifest[go]="go.mod"
    [[ -f "$proj_dir/pyproject.toml" ]]    && lang_manifest[python]="pyproject.toml"
    [[ -f "$proj_dir/requirements.txt" ]]  && lang_manifest[python]="${lang_manifest[python]:-requirements.txt}"
    [[ -f "$proj_dir/setup.py" ]]          && lang_manifest[python]="${lang_manifest[python]:-setup.py}"
    [[ -f "$proj_dir/Pipfile" ]]           && lang_manifest[python]="${lang_manifest[python]:-Pipfile}"
    [[ -f "$proj_dir/Gemfile" ]]           && lang_manifest[ruby]="Gemfile"
    [[ -f "$proj_dir/composer.json" ]]     && lang_manifest[php]="composer.json"
    [[ -f "$proj_dir/pubspec.yaml" ]]      && lang_manifest[dart]="pubspec.yaml"
    [[ -f "$proj_dir/Package.swift" ]]     && lang_manifest[swift]="Package.swift"
    [[ -f "$proj_dir/mix.exs" ]]           && lang_manifest[elixir]="mix.exs"
    if [[ -f "$proj_dir/stack.yaml" ]]; then
        lang_manifest[haskell]="stack.yaml"
    elif [[ -f "$proj_dir/cabal.project" ]]; then
        lang_manifest[haskell]="cabal.project"
    fi

    # Java/Kotlin — check build tools
    if [[ -f "$proj_dir/build.gradle" ]] || [[ -f "$proj_dir/build.gradle.kts" ]]; then
        if _has_source_files "$proj_dir" "kt kts"; then
            lang_manifest[kotlin]="build.gradle"
        else
            lang_manifest[java]="build.gradle"
        fi
    elif [[ -f "$proj_dir/pom.xml" ]]; then
        lang_manifest[java]="pom.xml"
    fi

    # C#/.NET
    if compgen -G "$proj_dir"/*.csproj >/dev/null 2>&1 || compgen -G "$proj_dir"/*.sln >/dev/null 2>&1; then
        local _csproj_match
        _csproj_match=$(compgen -G "$proj_dir"/*.csproj 2>/dev/null | head -1) || true
        if [[ -n "$_csproj_match" ]]; then
            lang_manifest[csharp]="$(basename "$_csproj_match")"
        else
            lang_manifest[csharp]="*.sln"
        fi
    fi

    # --- Source file counting (top 2 levels, excluding vendored dirs) ---
    _count_source_files "$proj_dir" lang_source_count

    # --- Merge results and assign confidence ---
    local -A all_langs=()
    local lang
    for lang in "${!lang_manifest[@]}"; do all_langs[$lang]=1; done
    for lang in "${!lang_source_count[@]}"; do all_langs[$lang]=1; done

    for lang in "${!all_langs[@]}"; do
        local has_manifest="${lang_manifest[$lang]:-}"
        local source_count="${lang_source_count[$lang]:-0}"
        local confidence="low"
        local manifest="${has_manifest:-none}"

        if [[ -n "$has_manifest" ]] && [[ "$source_count" -gt 0 ]]; then
            confidence="high"
        elif [[ -n "$has_manifest" ]] || [[ "$source_count" -ge 5 ]]; then
            confidence="medium"
        fi

        # Skip languages with no manifest and very few source files (likely vendored)
        if [[ -z "$has_manifest" ]] && [[ "$source_count" -lt 3 ]]; then
            continue
        fi

        echo "${lang}|${confidence}|${manifest}"
    done | awk -F'|' '{
        rank = ($2 == "high" ? 1 : ($2 == "medium" ? 2 : 3))
        print rank "|" $0
    }' | sort -t'|' -k1,1n -k3,3 | cut -d'|' -f2-
}

# _has_source_files — Check if source files with given extensions exist (top 2 levels).
# Args: $1 = directory, $2 = space-separated extensions
_has_source_files() {
    local dir="$1"
    local exts="$2"
    local ext
    # shellcheck disable=SC2086  # intentional word-splitting of $exts
    for ext in $exts; do
        if _find_source_files "$dir" | grep -q "\.${ext}$" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# _find_source_files — Lists tracked/non-excluded source files at top 2 levels.
# Args: $1 = directory
_find_source_files() {
    local dir="$1"
    if git -C "$dir" rev-parse --git-dir &>/dev/null; then
        git -C "$dir" ls-files 2>/dev/null | grep -Ev "(^|/)(${_DETECT_EXCLUDE_DIRS})/" || true
    else
        find "$dir" -maxdepth 2 -type f \
            -not -path '*/.git/*' \
            -not -path '*/node_modules/*' \
            -not -path '*/__pycache__/*' \
            -not -path '*/vendor/*' \
            -not -path '*/third_party/*' \
            -not -path '*/build/*' \
            -not -path '*/dist/*' \
            -not -path '*/target/*' \
            2>/dev/null | sed "s|^${dir}/||" || true
    fi
}

# _count_source_files — Counts source files by language in the top 2 levels.
# Args: $1 = directory, $2 = nameref to associative array
# shellcheck disable=SC2154  # nameref array keys are dynamic
_count_source_files() {
    local dir="$1"
    local -n _counts="$2"
    local files
    files=$(_find_source_files "$dir")

    # Extension-to-language mapping
    local line ext
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ext="${line##*.}"
        case "$ext" in
            ts|tsx)   _counts[typescript]=$(( ${_counts[typescript]:-0} + 1 )) ;;
            js|jsx|mjs|cjs) _counts[javascript]=$(( ${_counts[javascript]:-0} + 1 )) ;;
            py|pyw)   _counts[python]=$(( ${_counts[python]:-0} + 1 )) ;;
            rs)       _counts[rust]=$(( ${_counts[rust]:-0} + 1 )) ;;
            go)       _counts[go]=$(( ${_counts[go]:-0} + 1 )) ;;
            java)     _counts[java]=$(( ${_counts[java]:-0} + 1 )) ;;
            kt|kts)   _counts[kotlin]=$(( ${_counts[kotlin]:-0} + 1 )) ;;
            rb)       _counts[ruby]=$(( ${_counts[ruby]:-0} + 1 )) ;;
            php)      _counts[php]=$(( ${_counts[php]:-0} + 1 )) ;;
            dart)     _counts[dart]=$(( ${_counts[dart]:-0} + 1 )) ;;
            swift)    _counts[swift]=$(( ${_counts[swift]:-0} + 1 )) ;;
            cs)       _counts[csharp]=$(( ${_counts[csharp]:-0} + 1 )) ;;
            ex|exs)   _counts[elixir]=$(( ${_counts[elixir]:-0} + 1 )) ;;
            hs|lhs)   _counts[haskell]=$(( ${_counts[haskell]:-0} + 1 )) ;;
            lua)      _counts[lua]=$(( ${_counts[lua]:-0} + 1 )) ;;
            sh|bash)  _counts[shell]=$(( ${_counts[shell]:-0} + 1 )) ;;
            c|h)      _counts[c]=$(( ${_counts[c]:-0} + 1 )) ;;
            cpp|cc|cxx|hpp|hxx) _counts[cpp]=$(( ${_counts[cpp]:-0} + 1 )) ;;
        esac
    done <<< "$files"
}

# --- Framework detection ------------------------------------------------------

# detect_frameworks — Reads manifest files for framework signatures.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: One line per framework: FRAMEWORK|LANG|EVIDENCE
detect_frameworks() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"

    # Node.js frameworks (from package.json dependencies)
    if [[ -f "$proj_dir/package.json" ]]; then
        local deps
        deps=$(_extract_json_keys "$proj_dir/package.json" '"dependencies"' '"devDependencies"')

        _check_dep "$deps" '"next"'       && echo "next.js|typescript|\"next\" in package.json dependencies"
        _check_dep "$deps" '"react"'      && ! _check_dep "$deps" '"next"' && echo "react|typescript|\"react\" in package.json dependencies"
        _check_dep "$deps" '"vue"'        && echo "vue|typescript|\"vue\" in package.json dependencies"
        _check_dep "$deps" '"@angular/core"' && echo "angular|typescript|\"@angular/core\" in package.json dependencies"
        _check_dep "$deps" '"svelte"'     && echo "svelte|typescript|\"svelte\" in package.json dependencies"
        _check_dep "$deps" '"express"'    && echo "express|javascript|\"express\" in package.json dependencies"
        _check_dep "$deps" '"fastify"'    && echo "fastify|javascript|\"fastify\" in package.json dependencies"
    fi

    # Python frameworks
    if [[ -f "$proj_dir/pyproject.toml" ]]; then
        local pydeps
        pydeps=$(cat "$proj_dir/pyproject.toml" 2>/dev/null)
        echo "$pydeps" | grep -qi '"django"\|django' && echo "django|python|django in pyproject.toml"
        echo "$pydeps" | grep -qi '"flask"\|flask'   && echo "flask|python|flask in pyproject.toml"
        echo "$pydeps" | grep -qi '"fastapi"\|fastapi' && echo "fastapi|python|fastapi in pyproject.toml"
    elif [[ -f "$proj_dir/requirements.txt" ]]; then
        local reqdeps
        reqdeps=$(cat "$proj_dir/requirements.txt" 2>/dev/null)
        echo "$reqdeps" | grep -qi '^django'  && echo "django|python|django in requirements.txt"
        echo "$reqdeps" | grep -qi '^flask'   && echo "flask|python|flask in requirements.txt"
        echo "$reqdeps" | grep -qi '^fastapi' && echo "fastapi|python|fastapi in requirements.txt"
    fi

    # Ruby frameworks
    if [[ -f "$proj_dir/Gemfile" ]]; then
        grep -q "'rails'" "$proj_dir/Gemfile" 2>/dev/null && echo "rails|ruby|\"rails\" in Gemfile"
    fi

    # Java/Kotlin frameworks
    if [[ -f "$proj_dir/build.gradle" ]] || [[ -f "$proj_dir/build.gradle.kts" ]]; then
        local gradle_file
        gradle_file="$proj_dir/build.gradle"
        [[ -f "$proj_dir/build.gradle.kts" ]] && gradle_file="$proj_dir/build.gradle.kts"
        grep -q 'spring-boot' "$gradle_file" 2>/dev/null && echo "spring-boot|java|spring-boot in build.gradle"
    elif [[ -f "$proj_dir/pom.xml" ]]; then
        grep -q 'spring-boot' "$proj_dir/pom.xml" 2>/dev/null && echo "spring-boot|java|spring-boot in pom.xml"
    fi

    # .NET frameworks
    if compgen -G "$proj_dir"/*.csproj >/dev/null 2>&1; then
        local csproj
        csproj=$(cat "$proj_dir"/*.csproj 2>/dev/null)
        echo "$csproj" | grep -q 'Microsoft.AspNetCore' && echo "asp.net|csharp|Microsoft.AspNetCore in .csproj"
    fi

    # Dart/Flutter
    if [[ -f "$proj_dir/pubspec.yaml" ]]; then
        grep -q 'flutter:' "$proj_dir/pubspec.yaml" 2>/dev/null && echo "flutter|dart|flutter in pubspec.yaml"
    fi

    # Swift
    if [[ -f "$proj_dir/Package.swift" ]]; then
        grep -q 'SwiftUI' "$proj_dir/Package.swift" 2>/dev/null && echo "swiftui|swift|SwiftUI in Package.swift"
    fi

    # Rust frameworks
    if [[ -f "$proj_dir/Cargo.toml" ]]; then
        local cargo
        cargo=$(cat "$proj_dir/Cargo.toml" 2>/dev/null)
        echo "$cargo" | grep -q 'actix-web' && echo "actix|rust|actix-web in Cargo.toml"
        echo "$cargo" | grep -q 'axum'      && echo "axum|rust|axum in Cargo.toml"
    fi

    # Go frameworks
    if [[ -f "$proj_dir/go.mod" ]]; then
        grep -q 'github.com/gin-gonic/gin' "$proj_dir/go.mod" 2>/dev/null && echo "gin|go|gin-gonic/gin in go.mod"
    fi
}

# --- JSON key extraction (grep-based, no jq dependency) -----------------------

# _extract_json_keys — Extracts content between two JSON section markers.
# This is a best-effort grep-based parser for package.json dependency blocks.
# Args: $1 = file, $2... = section names to extract from
_extract_json_keys() {
    local file="$1"
    shift
    local section
    for section in "$@"; do
        # Extract lines between the section key and the next closing brace
        awk -v sect="$section" '
            $0 ~ sect { found=1; next }
            found && /\}/ { found=0; next }
            found { print }
        ' "$file" 2>/dev/null || true
    done
}

# _check_dep — Check if a dependency name appears in extracted dep text.
# Args: $1 = deps text, $2 = dependency pattern (e.g., '"next"')
_check_dep() {
    echo "$1" | grep -q "$2" 2>/dev/null
}
