#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# detect_workspaces.sh — Monorepo / workspace detection (Milestone 12)
#
# Sourced by tekhton.sh — do not run directly.
# Depends on: detect.sh (_DETECT_EXCLUDE_DIRS)
# Provides: detect_workspaces()
# =============================================================================

# Max subprojects to enumerate (avoid perf issues on huge monorepos)
_WORKSPACE_ENUM_LIMIT="${WORKSPACE_ENUM_LIMIT:-50}"

# detect_workspaces — Detects monorepo workspace roots and enumerates subprojects.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: One line per workspace: WORKSPACE_TYPE|ROOT_MANIFEST|SUBPROJECT_PATHS
#   SUBPROJECT_PATHS is comma-separated. If more than _WORKSPACE_ENUM_LIMIT,
#   excess paths are replaced with "...(N more)".
detect_workspaces() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"
    local found=false

    # --- npm/yarn/pnpm workspaces ---
    if [[ -f "$proj_dir/pnpm-workspace.yaml" ]]; then
        local subs
        subs=$(_enum_pnpm_workspaces "$proj_dir")
        [[ -n "$subs" ]] && { echo "pnpm-workspace|pnpm-workspace.yaml|${subs}"; found=true; }
    fi
    if [[ "$found" != true ]] && [[ -f "$proj_dir/package.json" ]]; then
        local ws_field
        ws_field=$(_extract_json_array_values "$proj_dir/package.json" '"workspaces"')
        if [[ -n "$ws_field" ]]; then
            local subs
            subs=$(_enum_glob_workspaces "$proj_dir" "$ws_field")
            [[ -n "$subs" ]] && { echo "npm-workspaces|package.json|${subs}"; found=true; }
        fi
    fi

    # --- Lerna ---
    if [[ "$found" != true ]] && [[ -f "$proj_dir/lerna.json" ]]; then
        local subs
        subs=$(_enum_lerna_packages "$proj_dir")
        [[ -n "$subs" ]] && { echo "lerna|lerna.json|${subs}"; found=true; }
    fi

    # --- Nx ---
    if [[ "$found" != true ]] && [[ -f "$proj_dir/nx.json" ]]; then
        local subs
        subs=$(_enum_nx_projects "$proj_dir")
        [[ -n "$subs" ]] && { echo "nx|nx.json|${subs}"; found=true; }
    fi

    # --- Cargo workspace ---
    if [[ -f "$proj_dir/Cargo.toml" ]]; then
        if grep -q '^\[workspace\]' "$proj_dir/Cargo.toml" 2>/dev/null; then
            local subs
            subs=$(_enum_cargo_workspace "$proj_dir")
            [[ -n "$subs" ]] && echo "cargo-workspace|Cargo.toml|${subs}"
        fi
    fi

    # --- Go workspace ---
    if [[ -f "$proj_dir/go.work" ]]; then
        local subs
        subs=$(_enum_go_workspace "$proj_dir")
        [[ -n "$subs" ]] && echo "go-workspace|go.work|${subs}"
    fi

    # --- Gradle multi-project ---
    if [[ -f "$proj_dir/settings.gradle" ]] || [[ -f "$proj_dir/settings.gradle.kts" ]]; then
        local gradle_settings="$proj_dir/settings.gradle"
        [[ -f "$proj_dir/settings.gradle.kts" ]] && gradle_settings="$proj_dir/settings.gradle.kts"
        if grep -q 'include' "$gradle_settings" 2>/dev/null; then
            local subs
            subs=$(_enum_gradle_subprojects "$proj_dir" "$gradle_settings")
            [[ -n "$subs" ]] && echo "gradle-multiproject|$(basename "$gradle_settings")|${subs}"
        fi
    fi

    # --- Maven multi-module ---
    if [[ -f "$proj_dir/pom.xml" ]]; then
        if grep -q '<modules>' "$proj_dir/pom.xml" 2>/dev/null; then
            local subs
            subs=$(_enum_maven_modules "$proj_dir")
            [[ -n "$subs" ]] && echo "maven-multimodule|pom.xml|${subs}"
        fi
    fi
}

# --- Workspace enumeration helpers -------------------------------------------

# _enum_pnpm_workspaces — Parse pnpm-workspace.yaml packages field.
_enum_pnpm_workspaces() {
    local proj_dir="$1"
    # Extract lines under "packages:" that start with "  - "
    local patterns
    patterns=$(awk '/^packages:/{found=1;next} found && /^[^ ]/{exit} found && /^  - /{s=$0; gsub(/^  - /,"",s); gsub(/["'\'']/,"",s); print s}' \
        "$proj_dir/pnpm-workspace.yaml" 2>/dev/null || true)
    _resolve_glob_patterns "$proj_dir" "$patterns"
}

# _enum_glob_workspaces — Resolve glob patterns from package.json workspaces.
_enum_glob_workspaces() {
    local proj_dir="$1"
    local patterns="$2"
    # patterns is comma-separated glob values like "packages/*","apps/*"
    local cleaned
    cleaned=$(echo "$patterns" | tr ',' '\n' | sed 's/[" ]//g')
    _resolve_glob_patterns "$proj_dir" "$cleaned"
}

# _enum_lerna_packages — Parse lerna.json packages.
_enum_lerna_packages() {
    local proj_dir="$1"
    local patterns
    patterns=$(awk '/"packages"/{found=1;next} found && /\]/{exit} found{gsub(/[",\[\] ]/,""); if(length>0) print}' \
        "$proj_dir/lerna.json" 2>/dev/null || true)
    [[ -z "$patterns" ]] && patterns="packages/*"
    _resolve_glob_patterns "$proj_dir" "$patterns"
}

# _enum_nx_projects — Find Nx project directories.
_enum_nx_projects() {
    local proj_dir="$1"
    local -a subs=()
    local count=0
    local d
    # Nx projects are directories with project.json
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        [[ "$count" -ge "$_WORKSPACE_ENUM_LIMIT" ]] && break
        subs+=("${d%/project.json}")
        count=$((count + 1))
    done < <(find "$proj_dir" -maxdepth 3 -name "project.json" -not -path "*/node_modules/*" 2>/dev/null | \
        sed "s|^${proj_dir}/||" | sort)
    _format_subprojects "${subs[@]+"${subs[@]}"}"
}

# _enum_cargo_workspace — Parse [workspace] members from Cargo.toml.
_enum_cargo_workspace() {
    local proj_dir="$1"
    local patterns
    patterns=$(awk '/^\[workspace\]/{found=1;next} found && /^members/{m=1;next} m && /\]/{exit} m{gsub(/[",\[\] ]/,""); if(length>0) print} found && /^\[/{exit}' \
        "$proj_dir/Cargo.toml" 2>/dev/null || true)
    _resolve_glob_patterns "$proj_dir" "$patterns"
}

# _enum_go_workspace — Parse use directives from go.work.
_enum_go_workspace() {
    local proj_dir="$1"
    local -a subs=()
    local count=0
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # go.work has: use ( ./dir1 ./dir2 ) or use ./dir1
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "$trimmed" == "use" ]] && continue
        [[ "$trimmed" == "(" ]] && continue
        [[ "$trimmed" == ")" ]] && continue
        trimmed="${trimmed#use }"
        trimmed="${trimmed#./}"
        trimmed="${trimmed%/}"
        [[ -z "$trimmed" ]] && continue
        [[ "$count" -ge "$_WORKSPACE_ENUM_LIMIT" ]] && break
        subs+=("$trimmed")
        count=$((count + 1))
    done < <(grep -E '^\s*(use\s+\.|\./)' "$proj_dir/go.work" 2>/dev/null || \
             awk '/^use \(/{found=1;next} found && /\)/{exit} found{print}' "$proj_dir/go.work" 2>/dev/null || true)
    _format_subprojects "${subs[@]+"${subs[@]}"}"
}

# _enum_gradle_subprojects — Parse include statements from settings.gradle.
_enum_gradle_subprojects() {
    local proj_dir="$1"
    local settings_file="$2"
    local -a subs=()
    local count=0
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Extract project names: include ':sub1', ':sub2' or include(":sub1")
        local cleaned
        cleaned=$(echo "$line" | sed "s/include[( ]*//" | tr "," "\n" | \
            sed "s/[\"'():; ]//g" | sed 's/^://')
        local sub
        while IFS= read -r sub; do
            [[ -z "$sub" ]] && continue
            [[ "$count" -ge "$_WORKSPACE_ENUM_LIMIT" ]] && break
            # Convert gradle colon notation to path
            local path="${sub//:///}"
            subs+=("$path")
            count=$((count + 1))
        done <<< "$cleaned"
    done < <(grep -i 'include' "$settings_file" 2>/dev/null || true)
    _format_subprojects "${subs[@]+"${subs[@]}"}"
}

# _enum_maven_modules — Parse <module> tags from pom.xml.
_enum_maven_modules() {
    local proj_dir="$1"
    local -a subs=()
    local count=0
    local mod
    while IFS= read -r mod; do
        [[ -z "$mod" ]] && continue
        mod=$(echo "$mod" | sed 's/.*<module>//;s/<\/module>.*//' | tr -d '[:space:]')
        [[ -z "$mod" ]] && continue
        [[ "$count" -ge "$_WORKSPACE_ENUM_LIMIT" ]] && break
        subs+=("$mod")
        count=$((count + 1))
    done < <(grep '<module>' "$proj_dir/pom.xml" 2>/dev/null || true)
    _format_subprojects "${subs[@]+"${subs[@]}"}"
}

# --- Common helpers ----------------------------------------------------------

# _resolve_glob_patterns — Expand glob patterns to actual directories.
_resolve_glob_patterns() {
    local proj_dir="$1"
    local patterns="$2"
    [[ -z "$patterns" ]] && return 0
    local -a subs=()
    local count=0
    local pattern
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        local d
        # Expand the glob directly (e.g., packages/* → packages/lib-a packages/lib-b)
        # shellcheck disable=SC2231  # intentional glob expansion
        for d in "$proj_dir"/${pattern}; do
            [[ ! -d "$d" ]] && continue
            [[ "$count" -ge "$_WORKSPACE_ENUM_LIMIT" ]] && break 2
            local rel="${d#"${proj_dir}/"}"
            rel="${rel%/}"
            subs+=("$rel")
            count=$((count + 1))
        done
    done <<< "$patterns"
    _format_subprojects "${subs[@]+"${subs[@]}"}"
}

# _extract_json_array_values — Extract array values from a JSON key (grep-based).
# Handles both multi-line and single-line array formats.
_extract_json_array_values() {
    local file="$1"
    local key="$2"
    awk -v k="$key" '
        $0 ~ k {
            found=1
            # Handle single-line: "workspaces": ["a","b"]
            if (match($0, /\[.*\]/)) {
                s = substr($0, RSTART+1, RLENGTH-2)
                n = split(s, arr, ",")
                for (i=1; i<=n; i++) {
                    gsub(/[" ]/, "", arr[i])
                    if (length(arr[i]) > 0) print arr[i]
                }
                exit
            }
            next
        }
        found && /\]/ { exit }
        found { gsub(/["\[\],[:space:]]/, ""); if (length > 0) print }
    ' "$file" 2>/dev/null | paste -sd',' || true
}

# _format_subprojects — Join array elements as comma-separated, capping at limit.
_format_subprojects() {
    local -a items=("$@")
    local count=${#items[@]}
    [[ "$count" -eq 0 ]] && return 0

    if [[ "$count" -le "$_WORKSPACE_ENUM_LIMIT" ]]; then
        local IFS=','
        echo "${items[*]}"
    else
        local -a capped=("${items[@]:0:$_WORKSPACE_ENUM_LIMIT}")
        local excess=$(( count - _WORKSPACE_ENUM_LIMIT ))
        local IFS=','
        echo "${capped[*]},...(${excess} more)"
    fi
}
