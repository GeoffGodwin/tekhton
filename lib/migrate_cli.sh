#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# migrate_cli.sh — CLI handlers and backup cleanup for migration framework
#
# Sourced by tekhton.sh after migrate.sh — do not run directly.
# Expects: All functions from migrate.sh (detect_config_version,
#   _running_major_minor, _applicable_migrations, run_migrations, etc.)
# =============================================================================

# --- CLI handlers ------------------------------------------------------------

# show_migration_status — --migrate --status
show_migration_status() {
    local project_dir="${PROJECT_DIR:-.}"
    local config_ver
    config_ver=$(detect_config_version "$project_dir")
    local running_ver
    running_ver=$(_running_major_minor)

    echo "Config version:  V${config_ver}"
    echo "Running version: V${running_ver}"

    if _version_eq "$config_ver" "$running_ver"; then
        echo "Status: Up to date"
    elif _version_lt "$config_ver" "$running_ver"; then
        local count=0
        local line
        while IFS= read -r line; do
            [[ -n "$line" ]] && count=$((count + 1))
        done < <(_applicable_migrations "$config_ver" "$running_ver")
        echo "Status: ${count} migration(s) available"
    else
        echo "Status: Config is newer than running version (safe)"
    fi
}

# show_migration_check — --migrate --check
show_migration_check() {
    local project_dir="${PROJECT_DIR:-.}"
    local config_ver
    config_ver=$(detect_config_version "$project_dir")
    local running_ver
    running_ver=$(_running_major_minor)

    echo "Dry run: migrations from V${config_ver} to V${running_ver}"
    echo

    local migrations
    migrations=$(_applicable_migrations "$config_ver" "$running_ver")

    if [[ -z "$migrations" ]]; then
        echo "No migrations needed."
        return 0
    fi

    local ver script
    while IFS='|' read -r ver script; do
        [[ -z "$ver" ]] && continue
        # Source to get description
        # shellcheck source=/dev/null
        source "$script"
        local desc
        desc=$(migration_description 2>/dev/null || echo "Migration to ${ver}")
        # Check if already applied
        if ! migration_check "$project_dir" 2>/dev/null; then
            echo "  [skip] V${ver}: ${desc} (already applied)"
        else
            echo "  [run]  V${ver}: ${desc}"
        fi
    done <<< "$migrations"
}

# run_migrate_command — --migrate entry point
run_migrate_command() {
    local force=false
    local rollback=false
    local check_only=false
    local status_only=false
    local cleanup=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --rollback) rollback=true; shift ;;
            --check) check_only=true; shift ;;
            --status) status_only=true; shift ;;
            --cleanup-backups) cleanup=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ "$status_only" = true ]]; then
        show_migration_status
        return 0
    fi

    if [[ "$check_only" = true ]]; then
        show_migration_check
        return 0
    fi

    if [[ "$rollback" = true ]]; then
        rollback_migration "${PROJECT_DIR:-.}"
        return $?
    fi

    if [[ "$cleanup" = true ]]; then
        _cleanup_old_backups "${PROJECT_DIR:-.}"
        return $?
    fi

    local project_dir="${PROJECT_DIR:-.}"
    local config_ver
    config_ver=$(detect_config_version "$project_dir")
    local running_ver
    running_ver=$(_running_major_minor)

    if _version_eq "$config_ver" "$running_ver" || ! _version_lt "$config_ver" "$running_ver"; then
        log "Project is up to date (V${config_ver})."
        return 0
    fi

    if [[ "$force" != true ]]; then
        echo "Project configured for V${config_ver}, running V${running_ver}."
        log "Apply migrations? [Y/n]"
        local choice
        read -r choice
        case "$choice" in
            n|N)
                log "Aborted."
                return 0
                ;;
        esac
    fi

    run_migrations "$config_ver" "$running_ver" "$project_dir"
}

# _cleanup_old_backups — Remove old migration backups, keep the last 3
_cleanup_old_backups() {
    local project_dir="$1"
    local backup_base="${project_dir}/${MIGRATION_BACKUP_DIR:-.claude/migration-backups}"
    local keep=3

    [[ -d "$backup_base" ]] || { log "No backups to clean up."; return 0; }

    local dirs=()
    local dir
    for dir in "${backup_base}"/pre-*; do
        [[ -d "$dir" ]] || continue
        dirs+=("$dir")
    done

    if [[ ${#dirs[@]} -le $keep ]]; then
        log "Only ${#dirs[@]} backup(s) exist — nothing to clean up (keeping last ${keep})."
        return 0
    fi

    local to_remove=$(( ${#dirs[@]} - keep ))
    local i
    for i in $(seq 0 $((to_remove - 1))); do
        rm -rf "${dirs[$i]}"
        log "Removed: $(basename "${dirs[$i]}")"
    done
    success "Cleaned up ${to_remove} old backup(s), kept last ${keep}."
}
