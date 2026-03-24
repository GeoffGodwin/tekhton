# Tekhton Migration Scripts

This directory contains migration scripts that upgrade project configurations
when Tekhton's version advances past what the project was set up with.

## How it works

Every project gets a `TEKHTON_CONFIG_VERSION=X.Y` watermark in pipeline.conf.
On startup, Tekhton compares this against the running version. When there's a
gap, migrations run automatically (with user confirmation) or on-demand via
`tekhton --migrate`.

## Writing a migration script

Each migration script must export four functions:

```bash
#!/usr/bin/env bash
set -euo pipefail

migration_version() { echo "4.0"; }

migration_description() {
    echo "Brief description of what this migration does"
}

migration_check() {
    # Return 0 if this migration needs to run, 1 if already applied.
    # Must be idempotent — safe to call repeatedly.
    local project_dir="$1"
    # Check for presence of a V4-era artifact
    [[ -f "${project_dir}/.claude/some-v4-file" ]] && return 1
    return 0
}

migration_apply() {
    # Perform the migration. Return 0 on success, non-zero on failure.
    local project_dir="$1"
    # ... migration logic ...
    return 0
}
```

## Conventions

1. **Non-destructive**: Never delete user files. Never overwrite existing
   agent role files. Only append new config keys, never replace existing values.

2. **Idempotent**: Running the same migration twice produces the same result.
   The `migration_check()` function detects already-applied state.

3. **Atomic config writes**: When modifying pipeline.conf, append new keys.
   Never modify existing user-set values.

4. **Naming**: `NNN_to_NNN.sh` — e.g., `001_to_002.sh` for V1→V2.
   The numeric prefix determines sort order.

5. **Backup**: The framework creates a backup before any migration runs.
   Users can restore via `tekhton --migrate --rollback`.

6. **Chain behavior**: Migrations run in version order. If one fails, the
   chain stops — no further migrations execute. This prevents partial state.

7. **Testing**: Each migration should be tested against fixture projects
   that represent the source version's configuration state.

## CLI commands

```bash
tekhton --migrate                # Run with confirmation
tekhton --migrate --force        # Run without confirmation
tekhton --migrate --check        # Dry run — show what would run
tekhton --migrate --status       # Show config version vs running version
tekhton --migrate --rollback     # Restore from backup
tekhton --migrate --cleanup-backups  # Remove old backups (keeps last 3)
```
