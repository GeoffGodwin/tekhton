#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# crawler_deps.sh — Dependency graph extraction and manifest parsers
#
# Sourced by crawler_content.sh — do not run directly.
# Depends on: detect.sh (_extract_json_keys)
# =============================================================================

# _annotate_package — Maps well-known packages to short purpose descriptions.
_annotate_package() {
    case "$1" in
        express|koa|hapi|fastify|django|flask|fastapi|starlette|actix-web|axum|warp|rocket|gin|fiber|chi) echo "Web framework" ;;
        react|preact|vue|svelte|angular*|@angular/*) echo "Frontend framework" ;;
        next|nuxt|gatsby|rails) echo "Full-stack framework" ;;
        typescript) echo "TypeScript compiler" ;;
        webpack|vite|rollup|esbuild|parcel) echo "Build tool / bundler" ;;
        jest|vitest|mocha|ava|tap|pytest|unittest|nose2|rspec) echo "Test framework" ;;
        eslint|prettier|rome|biome) echo "Linter / formatter" ;;
        axios|node-fetch|got|superagent|requests|httpx|aiohttp) echo "HTTP client" ;;
        lodash|underscore|ramda) echo "Utility library" ;;
        mongoose|sequelize|prisma|typeorm|drizzle*|sqlalchemy|gorm) echo "ORM / database" ;;
        redis|ioredis|pg|mysql2|sqlite3|better-sqlite3) echo "Database driver" ;;
        numpy|pandas|scipy) echo "Scientific computing" ;;
        pydantic) echo "Data validation" ;;
        celery) echo "Task queue" ;;
        serde|tokio|reqwest) echo "Core Rust library" ;;
        clap|structopt) echo "CLI argument parser" ;;
        spring-boot*) echo "Application framework" ;;
        echo) echo "HTTP router" ;;
        *) echo "" ;;
    esac
}

# --- Dependency graph ---------------------------------------------------------

# _crawl_dependency_graph — Extracts dependencies from manifest files.
# Args: $1 = project directory
_crawl_dependency_graph() {
    local project_dir="$1"
    local output=""
    local found_any=false

    # --- Monorepo detection ---
    local sub_projects=()
    local sub_dir
    for sub_dir in "${project_dir}/packages" "${project_dir}/apps"; do
        if [[ -d "$sub_dir" ]]; then
            local count=0
            local entry
            for entry in "$sub_dir"/*/; do
                [[ ! -d "$entry" ]] && continue
                if [[ -f "${entry}package.json" ]] || [[ -f "${entry}Cargo.toml" ]] || \
                   [[ -f "${entry}pyproject.toml" ]] || [[ -f "${entry}go.mod" ]]; then
                    sub_projects+=("$entry")
                    count=$(( count + 1 ))
                    [[ "$count" -ge 5 ]] && break  # Cap at 5 sub-projects
                fi
            done
        fi
    done

    # Parse root-level manifests
    output+=$(_parse_node_deps "$project_dir" "")
    output+=$(_parse_cargo_deps "$project_dir" "")
    output+=$(_parse_python_deps "$project_dir" "")
    output+=$(_parse_go_deps "$project_dir" "")
    output+=$(_parse_gemfile_deps "$project_dir" "")
    output+=$(_parse_gradle_deps "$project_dir" "")
    output+=$(_parse_pom_deps "$project_dir" "")

    # Parse sub-project manifests
    local sp
    for sp in "${sub_projects[@]+"${sub_projects[@]}"}"; do
        local sp_name
        sp_name=$(basename "$sp")
        output+=$(_parse_node_deps "$sp" "$sp_name")
        output+=$(_parse_cargo_deps "$sp" "$sp_name")
        output+=$(_parse_python_deps "$sp" "$sp_name")
    done

    [[ -n "$output" ]] && found_any=true
    if [[ "$found_any" != true ]]; then
        output="(no dependency manifests found)"
    fi

    printf '%s' "$output"
}

# --- Per-manifest parsers -----------------------------------------------------

_parse_node_deps() {
    local dir="$1" prefix="$2"
    [[ ! -f "${dir}/package.json" ]] && return 0
    local label="package.json"
    [[ -n "$prefix" ]] && label="${prefix}/package.json"
    local output=""
    output+="### ${label}"$'\n\n'
    output+="| Package | Version | Purpose |"$'\n'
    output+="| ------- | ------- | ------- |"$'\n'

    local deps_text
    deps_text=$(_extract_json_keys "${dir}/package.json" '"dependencies"' '"devDependencies"')
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pkg ver annotation
        pkg=$(echo "$line" | sed -n 's/.*"\([^"]*\)"\s*:.*/\1/p')
        ver=$(echo "$line" | sed -n 's/.*:\s*"\([^"]*\)".*/\1/p')
        [[ -z "$pkg" ]] && continue
        annotation=$(_annotate_package "$pkg")
        output+="| ${pkg} | ${ver} | ${annotation} |"$'\n'
    done <<< "$deps_text"
    output+=$'\n'
    printf '%s' "$output"
}

_parse_cargo_deps() {
    local dir="$1" prefix="$2"
    [[ ! -f "${dir}/Cargo.toml" ]] && return 0
    local label="Cargo.toml"
    [[ -n "$prefix" ]] && label="${prefix}/Cargo.toml"
    local output=""
    output+="### ${label}"$'\n\n'
    output+="| Crate | Version | Purpose |"$'\n'
    output+="| ----- | ------- | ------- |"$'\n'

    local in_deps=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[dependencies\] ]] || [[ "$line" =~ ^\[dev-dependencies\] ]]; then
            in_deps=true; continue
        fi
        [[ "$line" =~ ^\[ ]] && { in_deps=false; continue; }
        [[ "$in_deps" != true ]] && continue
        [[ -z "$line" ]] && continue

        local crate ver annotation
        # Simple: crate = "version"
        if [[ "$line" =~ ^([a-zA-Z0-9_-]+)[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
            crate="${BASH_REMATCH[1]}"
            ver="${BASH_REMATCH[2]}"
        # Table: crate = { version = "x" }
        elif [[ "$line" =~ ^([a-zA-Z0-9_-]+)[[:space:]]*= ]]; then
            crate="${BASH_REMATCH[1]}"
            ver=$(echo "$line" | sed -n 's/.*version\s*=\s*"\([^"]*\)".*/\1/p')
            [[ -z "$ver" ]] && ver="(workspace/path)"
        else
            continue
        fi
        annotation=$(_annotate_package "$crate")
        output+="| ${crate} | ${ver} | ${annotation} |"$'\n'
    done < "${dir}/Cargo.toml"
    output+=$'\n'
    printf '%s' "$output"
}

_parse_python_deps() {
    local dir="$1" prefix="$2"
    [[ ! -f "${dir}/pyproject.toml" ]] && return 0
    local label="pyproject.toml"
    [[ -n "$prefix" ]] && label="${prefix}/pyproject.toml"
    local output=""
    output+="### ${label}"$'\n\n'
    output+="| Package | Constraint | Purpose |"$'\n'
    output+="| ------- | ---------- | ------- |"$'\n'

    local in_deps=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^dependencies[[:space:]]*= ]] || \
           [[ "$line" =~ ^\[project\] ]] && [[ "$line" =~ dependencies ]]; then
            in_deps=true; continue
        fi
        # End of array
        [[ "$in_deps" == true ]] && [[ "$line" =~ ^\] ]] && { in_deps=false; continue; }
        [[ "$in_deps" != true ]] && continue
        [[ -z "$line" ]] && continue
        # Parse "package>=version" or "package"
        local pkg constraint annotation
        pkg="${line#"${line%%[![:space:]\"]*}"}"
        pkg="${pkg%%[^a-zA-Z0-9_-]*}"
        constraint=$(echo "$line" | sed -n 's/^[[:space:]]*"[a-zA-Z0-9_-]*\([^"]*\)".*/\1/p')
        [[ -z "$pkg" ]] && continue
        annotation=$(_annotate_package "$pkg")
        output+="| ${pkg} | ${constraint:-any} | ${annotation} |"$'\n'
    done < "${dir}/pyproject.toml"
    output+=$'\n'
    printf '%s' "$output"
}

_parse_go_deps() {
    local dir="$1" prefix="$2"
    [[ ! -f "${dir}/go.mod" ]] && return 0
    local label="go.mod"
    [[ -n "$prefix" ]] && label="${prefix}/go.mod"
    local output=""
    output+="### ${label}"$'\n\n'
    output+="| Module | Version | Purpose |"$'\n'
    output+="| ------ | ------- | ------- |"$'\n'

    local in_require=false
    while IFS= read -r line; do
        [[ "$line" =~ ^require[[:space:]]*\( ]] && { in_require=true; continue; }
        [[ "$line" =~ ^\) ]] && { in_require=false; continue; }
        [[ "$in_require" != true ]] && continue
        [[ -z "$line" ]] && continue
        local mod ver short_mod annotation
        mod=$(echo "$line" | awk '{print $1}')
        ver=$(echo "$line" | awk '{print $2}')
        short_mod="${mod##*/}"
        annotation=$(_annotate_package "$short_mod")
        output+="| ${mod} | ${ver} | ${annotation} |"$'\n'
    done < "${dir}/go.mod"
    output+=$'\n'
    printf '%s' "$output"
}

_parse_gemfile_deps() {
    local dir="$1" prefix="$2"
    [[ ! -f "${dir}/Gemfile" ]] && return 0
    local label="Gemfile"
    [[ -n "$prefix" ]] && label="${prefix}/Gemfile"
    local output=""
    output+="### ${label}"$'\n\n'
    output+="| Gem | Constraint | Purpose |"$'\n'
    output+="| --- | ---------- | ------- |"$'\n'

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*gem[[:space:]] ]] || continue
        local gem ver annotation
        gem=$(echo "$line" | sed -n "s/.*gem[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
        ver=$(echo "$line" | sed -n "s/.*gem[[:space:]]*['\"][^'\"]*['\"][[:space:]]*,[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
        [[ -z "$gem" ]] && continue
        annotation=$(_annotate_package "$gem")
        output+="| ${gem} | ${ver:-any} | ${annotation} |"$'\n'
    done < "${dir}/Gemfile"
    output+=$'\n'
    printf '%s' "$output"
}

_parse_gradle_deps() {
    local dir="$1" prefix="$2"
    local gradle_file=""
    [[ -f "${dir}/build.gradle.kts" ]] && gradle_file="${dir}/build.gradle.kts"
    [[ -f "${dir}/build.gradle" ]]     && gradle_file="${dir}/build.gradle"
    [[ -z "$gradle_file" ]] && return 0
    local label
    label=$(basename "$gradle_file")
    [[ -n "$prefix" ]] && label="${prefix}/${label}"
    local output=""
    output+="### ${label}"$'\n\n'
    output+="| Dependency | Purpose |"$'\n'
    output+="| ---------- | ------- |"$'\n'

    while IFS= read -r line; do
        [[ "$line" =~ implementation|api|testImplementation|compileOnly ]] || continue
        local dep
        dep=$(echo "$line" | sed -n "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/p" | head -1)
        [[ -z "$dep" ]] && continue
        local short="${dep##*:}"
        short="${short%%:*}"
        local annotation
        annotation=$(_annotate_package "$short")
        output+="| ${dep} | ${annotation} |"$'\n'
    done < "$gradle_file"
    output+=$'\n'
    printf '%s' "$output"
}

_parse_pom_deps() {
    local dir="$1" prefix="$2"
    [[ ! -f "${dir}/pom.xml" ]] && return 0
    local label="pom.xml"
    [[ -n "$prefix" ]] && label="${prefix}/pom.xml"
    local output=""
    output+="### ${label} (simplified)"$'\n\n'
    output+="| GroupId:ArtifactId | Purpose |"$'\n'
    output+="| ------------------ | ------- |"$'\n'

    # Simplified XML parsing — extract groupId + artifactId pairs
    local group="" artifact=""
    while IFS= read -r line; do
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        if [[ "$trimmed" =~ \<groupId\>(.*)\</groupId\> ]]; then
            group="${BASH_REMATCH[1]}"
        elif [[ "$trimmed" =~ \<artifactId\>(.*)\</artifactId\> ]]; then
            artifact="${BASH_REMATCH[1]}"
            if [[ -n "$group" ]]; then
                local annotation
                annotation=$(_annotate_package "$artifact")
                output+="| ${group}:${artifact} | ${annotation} |"$'\n'
                group="" artifact=""
            fi
        fi
    done < "${dir}/pom.xml"
    output+=$'\n'
    printf '%s' "$output"
}
