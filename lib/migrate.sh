#!/usr/bin/env bash
# =============================================================================
# migrate.sh — Version migration framework for project configurations
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TEKHTON_HOME, PROJECT_DIR, TEKHTON_VERSION from tekhton.sh
# Expects: log(), warn(), error(), success() from common.sh
#
# Provides:
#   detect_config_version     — infer project config version from artifacts
#   check_project_version     — startup version check + migration prompt
#   run_migrations            — execute applicable migration scripts
#   backup_project_config     — create pre-migration backup
#   rollback_migration        — restore from backup
#   show_migration_status     — display version info
#   show_migration_check      — dry-run: show what would run
# =============================================================================
set -euo pipefail

# --- Version watermark helpers -----------------------------------------------

# _running_major_minor — Extract MAJOR.MINOR from TEKHTON_VERSION
_running_major_minor() {
    echo "${TEKHTON_VERSION%.*}"
}

# _version_lt — Returns 0 if v1 < v2 (MAJOR.MINOR comparison)
_version_lt() {
    local v1="$1" v2="$2"
    local v1_major v1_minor v2_major v2_minor

    IFS='.' read -r v1_major v1_minor <<< "$v1"
    IFS='.' read -r v2_major v2_minor <<< "$v2"

    v1_major="${v1_major:-0}"; v1_minor="${v1_minor:-0}"
    v2_major="${v2_major:-0}"; v2_minor="${v2_minor:-0}"

    if [[ "$v1_major" -lt "$v2_major" ]]; then return 0; fi
    if [[ "$v1_major" -gt "$v2_major" ]]; then return 1; fi
    if [[ "$v1_minor" -lt "$v2_minor" ]]; then return 0; fi
    return 1
}

# _version_eq — Returns 0 if v1 == v2 (MAJOR.MINOR comparison)
_version_eq() {
    local v1="$1" v2="$2"
    local v1_major v1_minor v2_major v2_minor

    IFS='.' read -r v1_major v1_minor <<< "$v1"
    IFS='.' read -r v2_major v2_minor <<< "$v2"

    v1_major="${v1_major:-0}"; v1_minor="${v1_minor:-0}"
    v2_major="${v2_major:-0}"; v2_minor="${v2_minor:-0}"

    [[ "$v1_major" -eq "$v2_major" ]] && [[ "$v1_minor" -eq "$v2_minor" ]]
}

# --- Version detection -------------------------------------------------------

# detect_config_version PROJECT_DIR
# Returns the MAJOR.MINOR version of the project's Tekhton configuration.
# Checks explicit watermark first, then infers from artifacts.
detect_config_version() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"

    # Check explicit watermark
    if [[ -f "$conf_file" ]]; then
        local version_line
        version_line=$(grep '^TEKHTON_CONFIG_VERSION=' "$conf_file" 2>/dev/null || true)
        if [[ -n "$version_line" ]]; then
            local ver="${version_line#TEKHTON_CONFIG_VERSION=}"
            ver="${ver//\"/}"; ver="${ver//\'/}"
            ver="${ver#"${ver%%[![:space:]]*}"}"
            ver="${ver%"${ver##*[![:space:]]}"}"
            if [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
                echo "$ver"
                return 0
            fi
        fi
    fi

    # Infer from artifacts
    if [[ ! -f "$conf_file" ]]; then
        if [[ -d "${project_dir}/.claude" ]]; then
            echo "0.0"
            return 0
        fi
        echo "0.0"
        return 0
    fi

    # Has V3-era artifacts?
    if [[ -f "${project_dir}/.claude/milestones/MANIFEST.cfg" ]]; then
        echo "3.0"
        return 0
    fi

    # Has V2-era config keys?
    if grep -q 'CONTEXT_BUDGET_PCT\|CLARIFICATION_ENABLED\|AUTO_ADVANCE_ENABLED\|METRICS_ENABLED' \
        "$conf_file" 2>/dev/null; then
        echo "2.0"
        return 0
    fi

    # Default: V1 (basic pipeline.conf with only core keys)
    echo "1.0"
    return 0
}

# --- Migration script discovery ----------------------------------------------

# _list_migration_scripts — Lists migration scripts sorted by version
# Returns lines of: version|script_path
_list_migration_scripts() {
    local migrations_dir="${TEKHTON_HOME}/migrations"
    [[ -d "$migrations_dir" ]] || return 0

    local script
    for script in "${migrations_dir}"/*.sh; do
        [[ -f "$script" ]] || continue
        # Source in subshell to extract version
        local ver
        ver=$(bash -c "source '$script' && migration_version" 2>/dev/null || true)
        if [[ -n "$ver" ]] && [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
            echo "${ver}|${script}"
        fi
    done | sort -t'.' -k1,1n -k2,2n
}

# _applicable_migrations FROM_VERSION TO_VERSION
# Filters migration scripts to those in range (from < script_version <= to)
_applicable_migrations() {
    local from_ver="$1" to_ver="$2"
    local line ver script

    while IFS='|' read -r ver script; do
        [[ -z "$ver" ]] && continue
        # script_version > from_version AND script_version <= to_version
        if _version_lt "$from_ver" "$ver"; then
            if _version_lt "$ver" "$to_ver" || _version_eq "$ver" "$to_ver"; then
                echo "${ver}|${script}"
            fi
        fi
    done < <(_list_migration_scripts)
}

# --- Backup and rollback ----------------------------------------------------

# backup_project_config PROJECT_DIR FROM_VERSION TO_VERSION
backup_project_config() {
    local project_dir="$1"
    local from_ver="$2"
    local to_ver="$3"
    local backup_dir="${project_dir}/${MIGRATION_BACKUP_DIR:-.claude/migration-backups}/pre-${from_ver}-to-${to_ver}"

    mkdir -p "$backup_dir"

    # Copy files that migrations might modify
    local file
    for file in \
        ".claude/pipeline.conf" \
        "CLAUDE.md" \
        ".claude/milestones/MANIFEST.cfg"; do
        if [[ -f "${project_dir}/${file}" ]]; then
            local dir
            dir=$(dirname "${backup_dir}/${file}")
            mkdir -p "$dir"
            cp "${project_dir}/${file}" "${backup_dir}/${file}"
        fi
    done

    # Copy agent role files
    if [[ -d "${project_dir}/.claude/agents" ]]; then
        mkdir -p "${backup_dir}/.claude/agents"
        cp "${project_dir}/.claude/agents/"*.md "${backup_dir}/.claude/agents/" 2>/dev/null || true
    fi

    # Record the source version
    echo "$from_ver" > "${backup_dir}/FROM_VERSION"

    log "Backup created at ${backup_dir}/"
}

# rollback_migration PROJECT_DIR
# Lists available backups and restores the selected one.
rollback_migration() {
    local project_dir="$1"
    local backup_base="${project_dir}/${MIGRATION_BACKUP_DIR:-.claude/migration-backups}"

    if [[ ! -d "$backup_base" ]]; then
        error "No migration backups found at ${backup_base}/"
        return 1
    fi

    # List available backups
    local backups=()
    local dir
    for dir in "${backup_base}"/pre-*; do
        [[ -d "$dir" ]] || continue
        backups+=("$(basename "$dir")")
    done

    if [[ ${#backups[@]} -eq 0 ]]; then
        error "No migration backups found."
        return 1
    fi

    echo "Available backups:"
    local i
    for i in "${!backups[@]}"; do
        local from_ver=""
        if [[ -f "${backup_base}/${backups[$i]}/FROM_VERSION" ]]; then
            from_ver=$(cat "${backup_base}/${backups[$i]}/FROM_VERSION")
        fi
        echo "  $((i + 1)). ${backups[$i]} (config version: ${from_ver:-unknown})"
    done

    echo
    log "Select backup to restore [1-${#backups[@]}]: "
    local choice
    read -r choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "${#backups[@]}" ]]; then
        error "Invalid selection."
        return 1
    fi

    local selected="${backups[$((choice - 1))]}"
    local selected_dir="${backup_base}/${selected}"

    # Restore files
    local file
    for file in \
        ".claude/pipeline.conf" \
        "CLAUDE.md" \
        ".claude/milestones/MANIFEST.cfg"; do
        if [[ -f "${selected_dir}/${file}" ]]; then
            cp "${selected_dir}/${file}" "${project_dir}/${file}"
        fi
    done

    # Restore agent files
    if [[ -d "${selected_dir}/.claude/agents" ]]; then
        cp "${selected_dir}/.claude/agents/"*.md "${project_dir}/.claude/agents/" 2>/dev/null || true
    fi

    local restored_ver=""
    if [[ -f "${selected_dir}/FROM_VERSION" ]]; then
        restored_ver=$(cat "${selected_dir}/FROM_VERSION")
    fi

    if [[ -n "$restored_ver" ]]; then
        success "Rolled back to pre-migration state (V ${restored_ver})"
    else
        success "Rolled back to pre-migration state."
    fi
}

# --- Migration runner --------------------------------------------------------

# run_migrations FROM_VERSION TO_VERSION PROJECT_DIR
run_migrations() {
    local from_ver="$1"
    local to_ver="$2"
    local project_dir="$3"
    local applied=0
    local failed=false

    local migrations
    migrations=$(_applicable_migrations "$from_ver" "$to_ver")

    if [[ -z "$migrations" ]]; then
        log "No migrations needed between ${from_ver} and ${to_ver}."
        return 0
    fi

    # Create backup before any migration runs
    backup_project_config "$project_dir" "$from_ver" "$to_ver"

    local ver script
    while IFS='|' read -r ver script; do
        [[ -z "$ver" ]] && continue
        [[ -z "$script" ]] && continue

        # Source migration script
        # shellcheck source=/dev/null
        source "$script"

        local desc
        desc=$(migration_description 2>/dev/null || echo "Migration to ${ver}")
        log "Migrating project to V${ver}: ${desc}"

        # Idempotency check
        if ! migration_check "$project_dir"; then
            log "  Already applied — skipping."
            continue
        fi

        # Apply migration
        if migration_apply "$project_dir"; then
            success "  Applied successfully."
            applied=$((applied + 1))
        else
            error "  Migration to V${ver} failed. Stopping migration chain."
            error "  Use 'tekhton --migrate --rollback' to restore the pre-migration state."
            failed=true
            break
        fi
    done <<< "$migrations"

    if [[ "$failed" = true ]]; then
        # Write minimal failure context so --diagnose can detect the crash.
        # diagnose_output.sh may not be loaded yet, so write directly.
        local ctx_dir="${project_dir}/.claude"
        mkdir -p "$ctx_dir" 2>/dev/null || true
        local ctx_file="${ctx_dir}/LAST_FAILURE_CONTEXT.json"
        local timestamp_iso
        timestamp_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local safe_task=""
        if [[ -n "${TASK:-}" ]]; then
            safe_task=$(printf '%s' "$TASK" | sed 's/\\/\\\\/g; s/"/\\"/g')
        fi
        printf '{\n  "classification": "MIGRATION_FAILURE",\n  "stage": "migration",\n  "outcome": "failure",\n  "task": "%s",\n  "migration_from": "%s",\n  "migration_to": "%s",\n  "consecutive_count": 1,\n  "timestamp": "%s"\n}\n' \
            "$safe_task" "$from_ver" "$to_ver" "$timestamp_iso" \
            > "$ctx_file" 2>/dev/null || true
        return 1
    fi

    # Update watermark
    _write_config_version "$project_dir" "$to_ver"

    success "Migration complete: ${from_ver} → ${to_ver} (${applied} migration(s) applied)"
    return 0
}

# _write_config_version PROJECT_DIR VERSION
_write_config_version() {
    local project_dir="$1"
    local version="$2"
    local conf_file="${project_dir}/.claude/pipeline.conf"

    [[ -f "$conf_file" ]] || return 0

    # Check if key already exists
    if grep -q '^TEKHTON_CONFIG_VERSION=' "$conf_file" 2>/dev/null; then
        # Update existing value using temp file + mv for atomicity
        local tmpfile
        tmpfile=$(mktemp "${conf_file}.XXXXXX")
        sed "s/^TEKHTON_CONFIG_VERSION=.*/TEKHTON_CONFIG_VERSION=\"${version}\"/" \
            "$conf_file" > "$tmpfile"
        mv "$tmpfile" "$conf_file"
    else
        # Append after the header (before first config section)
        local tmpfile
        tmpfile=$(mktemp "${conf_file}.XXXXXX")
        local inserted=false
        while IFS= read -r line || [[ -n "$line" ]]; do
            echo "$line"
            # Insert after the first non-comment, non-empty line that contains PROJECT_NAME
            if [[ "$inserted" = false ]] && [[ "$line" == PROJECT_NAME=* ]]; then
                echo ""
                echo "# --- Tekhton config version (do not edit manually) -------------------------"
                echo "TEKHTON_CONFIG_VERSION=\"${version}\""
                inserted=true
            fi
        done < "$conf_file" > "$tmpfile"
        # If PROJECT_NAME not found, append at end
        if [[ "$inserted" = false ]]; then
            {
                echo ""
                echo "# --- Tekhton config version (do not edit manually) -------------------------"
                echo "TEKHTON_CONFIG_VERSION=\"${version}\""
            } >> "$tmpfile"
        fi
        mv "$tmpfile" "$conf_file"
    fi
}

# --- Startup integration ----------------------------------------------------

# check_project_version — Called at startup after config load.
# Detects version mismatch and prompts for migration.
check_project_version() {
    # Express mode has no pipeline.conf — migration is not applicable
    if [[ "${EXPRESS_MODE_ACTIVE:-false}" = true ]]; then
        return 0
    fi

    local project_dir="${PROJECT_DIR:-.}"
    local config_ver
    config_ver=$(detect_config_version "$project_dir")
    local running_ver
    running_ver=$(_running_major_minor)

    # No mismatch — proceed
    if _version_eq "$config_ver" "$running_ver" || ! _version_lt "$config_ver" "$running_ver"; then
        return 0
    fi

    # Count applicable migrations
    local migration_count=0
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && migration_count=$((migration_count + 1))
    done < <(_applicable_migrations "$config_ver" "$running_ver")

    if [[ "$migration_count" -eq 0 ]]; then
        return 0
    fi

    # In --complete/--auto-advance mode: auto-apply with logging
    if [[ "${COMPLETE_MODE_ENABLED:-false}" = true ]] || [[ "${AUTO_ADVANCE_ENABLED:-false}" = true ]]; then
        warn "Project configured for V${config_ver}, running V${running_ver}. Auto-applying ${migration_count} migration(s)."
        run_migrations "$config_ver" "$running_ver" "$project_dir"
        return $?
    fi

    # Interactive mode
    if [[ "${MIGRATION_AUTO:-true}" = true ]]; then
        echo
        warn "Project configured for V${config_ver}, running V${running_ver}."
        warn "${migration_count} migration(s) available."
        echo
        log "Apply migrations? [Y/n]"
        local choice
        read -r choice
        case "$choice" in
            n|N)
                warn "Skipping migration. Run 'tekhton --migrate' to apply later."
                return 0
                ;;
            *)
                run_migrations "$config_ver" "$running_ver" "$project_dir"
                return $?
                ;;
        esac
    else
        warn "Project configured for V${config_ver}, running V${running_ver}."
        warn "Run 'tekhton --migrate' to update project configuration."
        return 0
    fi
}

# --- CLI handlers (extracted to migrate_cli.sh) ------------------------------
# Sourced separately by tekhton.sh after migrate.sh
