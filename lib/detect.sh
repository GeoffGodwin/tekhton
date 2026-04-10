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

_DETECT_EXCLUDE_DIRS="node_modules|\\.git|__pycache__|\\.dart_tool|build|dist|\\.next|vendor|third_party|\\.bundle|\\.gradle|target|\\.build|Pods|\\.pub-cache|\\.cargo"

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
            lang_manifest[csharp]="$(basename "$_csproj_match" 2>/dev/null)"
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

    local _detected_output=""
    _detected_output=$(for lang in "${!all_langs[@]}"; do
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
    }' | sort -t'|' -k1,1n -k3,3 | cut -d'|' -f2-)

    # Fallback: consult CLAUDE.md for tech stack when file-based detection is empty
    if [[ -z "$_detected_output" ]] && [[ -f "${proj_dir}/CLAUDE.md" ]]; then
        local _known_langs='TypeScript|JavaScript|Python|Go|Rust|Java|Kotlin|Swift|Dart|Ruby|PHP|C#|Elixir|Haskell'
        local _claude_langs=""

        # Strategy 1: Structured **Languages:** list (produced by --plan generator).
        # Matches bullets directly under a "**Languages:**" label anywhere in the file,
        # stopping at the first blank line or non-bullet line after the list starts.
        local _in_langs_block=false
        while IFS= read -r _line; do
            if echo "$_line" | grep -qiE '^[[:space:]]*\*\*Languages(:|\*\*)'; then
                _in_langs_block=true
                continue
            fi
            if [[ "$_in_langs_block" == true ]]; then
                if echo "$_line" | grep -qE '^[[:space:]]*-[[:space:]]+'; then
                    local _bullet_text
                    _bullet_text=$(echo "$_line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/[[:space:]].*//')
                    if echo "$_bullet_text" | grep -qiE "^(${_known_langs})$"; then
                        _claude_langs+="${_bullet_text}"$'\n'
                    fi
                elif [[ -z "${_line// /}" ]]; then
                    _in_langs_block=false
                else
                    _in_langs_block=false
                fi
            fi
        done < "${proj_dir}/CLAUDE.md" || true

        # Strategy 2: Bullet starting with a language name in the Project Identity block.
        if [[ -z "$_claude_langs" ]]; then
            local _identity_block
            # Stop at any heading at the same or higher level (## or ###) after the match.
            _identity_block=$(awk '/^#+ .*Project Identity/{found=1;next} found && /^##/{exit} found{print}' "${proj_dir}/CLAUDE.md" || true)
            if [[ -n "$_identity_block" ]]; then
                _claude_langs=$(echo "$_identity_block" | grep -ioE "^[[:space:]]*-[[:space:]]+(${_known_langs})" | sed 's/^[[:space:]]*-[[:space:]]*//' || true)
            fi
        fi

        # Strategy 3: Word-boundary scan of the entire CLAUDE.md (last resort).
        if [[ -z "$_claude_langs" ]]; then
            _claude_langs=$(grep -oiE "\b(${_known_langs})\b" "${proj_dir}/CLAUDE.md" | sort -u || true)
        fi

        if [[ -n "$_claude_langs" ]]; then
            local _lang_name _lower
            while IFS= read -r _lang_name; do
                [[ -z "$_lang_name" ]] && continue
                _lower=$(echo "$_lang_name" | tr '[:upper:]' '[:lower:]')
                # Align C# identifier with file-based detection key
                [[ "$_lower" == "c#" ]] && _lower="csharp"
                # Deduplicate
                echo "$_detected_output" | grep -qF "${_lower}|" && continue
                _detected_output+="${_lower}|low|CLAUDE.md"$'\n'
            done <<< "$_claude_langs"
        fi
    fi

    if [[ -n "$_detected_output" ]]; then
        printf '%s' "${_detected_output%$'\n'}"
    fi
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
        # Limit to top 2 directory levels (matching non-git fallback's -maxdepth 2)
        git -C "$dir" ls-files 2>/dev/null | { grep -Ev "(^|/)(${_DETECT_EXCLUDE_DIRS})/" || true; } | awk -F/ 'NF<=2'
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

        _check_dep "$deps" '"next"'       && echo "next.js|node|\"next\" in package.json dependencies"
        _check_dep "$deps" '"react"'      && ! _check_dep "$deps" '"next"' && echo "react|node|\"react\" in package.json dependencies"
        _check_dep "$deps" '"vue"'        && echo "vue|node|\"vue\" in package.json dependencies"
        _check_dep "$deps" '"@angular/core"' && echo "angular|node|\"@angular/core\" in package.json dependencies"
        _check_dep "$deps" '"svelte"'     && echo "svelte|node|\"svelte\" in package.json dependencies"
        _check_dep "$deps" '"express"'    && echo "express|node|\"express\" in package.json dependencies"
        _check_dep "$deps" '"fastify"'    && echo "fastify|node|\"fastify\" in package.json dependencies"
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

# --- UI framework detection (Milestone 28) ------------------------------------

# detect_ui_framework — Detects E2E test frameworks and UI project indicators.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Sets globals: UI_PROJECT_DETECTED, UI_FRAMEWORK (when UI_FRAMEWORK=auto or empty)
# Output: framework name if detected, empty otherwise
detect_ui_framework() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"
    local detected_framework=""
    local ui_signals=0

    # --- E2E framework detection (specific → generic) ---

    # Playwright
    if [[ -f "$proj_dir/playwright.config.ts" ]] || [[ -f "$proj_dir/playwright.config.js" ]]; then
        detected_framework="playwright"
    elif [[ -f "$proj_dir/package.json" ]]; then
        local deps
        deps=$(_extract_json_keys "$proj_dir/package.json" '"dependencies"' '"devDependencies"')
        if _check_dep "$deps" '"@playwright/test"'; then
            detected_framework="playwright"
        elif _check_dep "$deps" '"cypress"'; then
            detected_framework="cypress"
        elif _check_dep "$deps" '"puppeteer"'; then
            detected_framework="puppeteer"
        fi

        # Testing Library (component-level E2E)
        if [[ -z "$detected_framework" ]]; then
            if _check_dep "$deps" '"@testing-library/react"' || \
               _check_dep "$deps" '"@testing-library/vue"' || \
               _check_dep "$deps" '"@testing-library/svelte"'; then
                detected_framework="testing-library"
            fi
        fi

        # Detox (mobile E2E)
        if [[ -z "$detected_framework" ]]; then
            if _check_dep "$deps" '"detox"'; then
                detected_framework="detox"
            fi
        fi
    fi

    # Cypress (config file check — may not be in package.json)
    if [[ -z "$detected_framework" ]]; then
        if [[ -f "$proj_dir/cypress.config.ts" ]] || [[ -f "$proj_dir/cypress.config.js" ]] || \
           [[ -d "$proj_dir/cypress" ]]; then
            detected_framework="cypress"
        fi
    fi

    # Selenium (Python/Java)
    if [[ -z "$detected_framework" ]]; then
        if [[ -f "$proj_dir/requirements.txt" ]] && grep -qi 'selenium' "$proj_dir/requirements.txt" 2>/dev/null; then
            detected_framework="selenium"
        elif [[ -f "$proj_dir/pom.xml" ]] && grep -q 'selenium' "$proj_dir/pom.xml" 2>/dev/null; then
            detected_framework="selenium"
        fi
    fi

    # Detox (config file check)
    if [[ -z "$detected_framework" ]]; then
        if [[ -f "$proj_dir/.detoxrc.js" ]] || [[ -f "$proj_dir/.detoxrc.json" ]]; then
            detected_framework="detox"
        fi
    fi

    # --- Generic web UI detection (requires MULTIPLE signals) ---
    if [[ -z "$detected_framework" ]]; then
        # Count UI signals — need 2+ to classify as UI project
        # Signal: component files (React/Vue/Svelte)
        if _has_source_files "$proj_dir" "tsx jsx"; then
            ui_signals=$((ui_signals + 1))
        fi
        if _has_source_files "$proj_dir" "vue svelte"; then
            ui_signals=$((ui_signals + 1))
        fi
        # Signal: templates directory with HTML
        if [[ -d "$proj_dir/templates" ]] || [[ -d "$proj_dir/app/views" ]] || \
           [[ -d "$proj_dir/src/pages" ]] || [[ -d "$proj_dir/pages" ]]; then
            ui_signals=$((ui_signals + 1))
        fi
        # Signal: frontend framework dependency
        if [[ -f "$proj_dir/package.json" ]]; then
            local _ui_deps
            _ui_deps=$(_extract_json_keys "$proj_dir/package.json" '"dependencies"')
            if _check_dep "$_ui_deps" '"react"' || _check_dep "$_ui_deps" '"vue"' || \
               _check_dep "$_ui_deps" '"svelte"' || _check_dep "$_ui_deps" '"@angular/core"'; then
                ui_signals=$((ui_signals + 1))
            fi
        fi
        # Signal: CSS/SCSS modules
        if _has_source_files "$proj_dir" "scss css module.css"; then
            ui_signals=$((ui_signals + 1))
        fi
        # Signal: Django/Rails/Flask templates
        if [[ -d "$proj_dir/templates" ]] && [[ -f "$proj_dir/manage.py" ]]; then
            ui_signals=$((ui_signals + 1))
        fi
        if [[ -d "$proj_dir/app/views" ]] && [[ -f "$proj_dir/Gemfile" ]]; then
            ui_signals=$((ui_signals + 1))
        fi

        # Require 2+ signals to avoid false positives (single HTML README ≠ UI project)
        if [[ "$ui_signals" -ge 2 ]]; then
            detected_framework="generic"
        fi
    fi

    # --- Apply results ---
    if [[ -n "$detected_framework" ]]; then
        UI_PROJECT_DETECTED="true"
        export UI_PROJECT_DETECTED
        # Only override UI_FRAMEWORK if set to "auto" or empty
        if [[ -z "${UI_FRAMEWORK:-}" ]] || [[ "${UI_FRAMEWORK:-}" == "auto" ]]; then
            if [[ "$detected_framework" != "generic" ]]; then
                UI_FRAMEWORK="$detected_framework"
            else
                UI_FRAMEWORK=""
            fi
            export UI_FRAMEWORK
        fi
        echo "$detected_framework"
    fi
}

# --- JSON key extraction (grep-based, no jq dependency) -----------------------

# _extract_json_keys — Extracts content between two JSON section markers.
# This is a best-effort grep-based parser for package.json dependency blocks.
# Note: Also called by detect_commands.sh. Callers must source detect.sh before detect_commands.sh.
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
