# M137 - Resilience Arc V3.2 Migration Script

<!-- milestone-meta
id: "137"
status: "pending"
-->

## Overview

| Migration context | Value |
|------------------|-------|
| Current latest migration | `3.1` (`003_to_031.sh`) |
| New migration | `3.2` (`031_to_032.sh`) |
| Trigger condition | `TEKHTON_CONFIG_VERSION` < `3.2` in project's `pipeline.conf` |
| Files produced | `migrations/031_to_032.sh` |

The resilience arc (m126–m136) introduced thirteen new config variables,
two new runtime artifact paths, new gitignore entries, and a new
`pipeline.conf` section. A project that was initialized before the arc
landed — the common case for all existing bifl-tracker-style projects —
gets none of this automatically. The `--migrate` command is the standard
Tekhton upgrade path for such projects.

Without m137, an operator upgrading their Tekhton installation must:
1. Manually identify which of the thirteen new vars their project needs.
2. Manually add gitignore entries for the two new artifact paths.
3. Know that `PREFLIGHT_UI_CONFIG_AUTO_FIX` exists (it is not in their
   config file and not visible in `--validate-config` output on pre-arc
   configs because the vars are absent, not wrong).

M137 creates `migrations/031_to_032.sh` — the V3.1 → V3.2 migration
script that automates all of the above safely and idempotently.

## Design

### Migration script convention (follow existing pattern exactly)

Every migration script exposes four functions (three mandatory; `migration_description` has a runner fallback but should always be implemented):

| Function | Signature | Contract |
|----------|-----------|---------|
| `migration_version` | `() → string` | Returns the target version as `MAJOR.MINOR` (e.g. `"3.2"`). |
| `migration_description` | `() → string` | One-line human-readable description shown during `--migrate`. |
| `migration_check` | `(project_dir) → 0/1` | Returns `0` if migration is needed, `1` if already applied. Idempotency guard. |
| `migration_apply` | `(project_dir) → 0/nonzero` | Applies the migration. Returns `0` on success. |

The script lives in `${TEKHTON_HOME}/migrations/031_to_032.sh`.

The migration runner (`lib/migrate.sh` → `run_migrations`) calls
`migration_check` first and skips the script if it returns `1`. This
makes `migration_apply` safe to implement without defensive guards —
the check handles idempotency.

### Step 1 — `migration_check`: detect whether the migration is needed

The migration is already applied if any of the following is true:
- `pipeline.conf` does not exist (express mode, bare init — nothing to
  migrate).
- `pipeline.conf` already contains `BUILD_FIX_ENABLED` (the unique V3.2
  sentinel key; a project that already has this line was migrated or
  initialized post-arc).

```bash
migration_check() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"

    # No conf: express mode or uninitialized — skip
    [[ -f "$conf_file" ]] || return 1

    # Sentinel key present → already migrated
    if grep -q '^BUILD_FIX_ENABLED=' "$conf_file" 2>/dev/null; then
        return 1
    fi
    return 0
}
```

**Why `BUILD_FIX_ENABLED` as sentinel:** It is the first line emitted
by `migration_apply` and is always present after migration. It is a
boolean enabled/disabled flag (not a numeric or path), so it cannot
appear in a pre-arc config by accident. Using the first-written key as
the sentinel is the same pattern as `002_to_003.sh` using
`SECURITY_AGENT_ENABLED` and `003_to_031.sh` using `TEKHTON_DIR`.

### Step 2 — `migration_apply`: three ordered sub-tasks

```bash
migration_apply() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"
    local gitignore_file="${project_dir}/.gitignore"

    [[ -f "$conf_file" ]] || return 1

    _032_append_arc_config_section "$conf_file"
    _032_update_gitignore "$gitignore_file"
    _032_create_preflight_bak_dir "$project_dir"

    return 0
}
```

#### Sub-task A — `_032_append_arc_config_section`

Appends the resilience arc commented section to `pipeline.conf`.
Uses `>>` (append), never overwrites. The sentinel key
`BUILD_FIX_ENABLED=true` is the first line so `migration_check`
will detect it on the next call.

```bash
_032_append_arc_config_section() {
    local conf_file="$1"

    cat >> "$conf_file" << 'EOF'

# ═══════════════════════════════════════════════════════════════════════════════
# V3.2 Resilience Arc (added by migration: m126–m136)
# UI gate robustness, build-fix continuation, and causal failure context
# ═══════════════════════════════════════════════════════════════════════════════

# === Build-Fix Continuation Loop (m128) ===
BUILD_FIX_ENABLED=true
# BUILD_FIX_MAX_ATTEMPTS=3          # Max fix attempts per pipeline cycle
# BUILD_FIX_BASE_TURN_DIVISOR=3     # Attempt-1 budget divisor
# BUILD_FIX_MAX_TURN_MULTIPLIER=1.0  # Upper cap multiplier against EFFECTIVE_CODER_MAX_TURNS
# BUILD_FIX_REQUIRE_PROGRESS=true   # Stop continuation when attempts show no progress
# BUILD_FIX_TOTAL_TURN_CAP=120      # Cumulative turn cap across the build-fix loop
# BUILD_FIX_CLASSIFICATION_REQUIRED=true  # Require code_dominant classification

# === UI Gate Non-Interactive Enforcement (m126) ===
# UI_GATE_ENV_RETRY_ENABLED=true    # Retry with non-interactive env on timeout
# UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=0.5  # Retry timeout as fraction of UI_TEST_TIMEOUT
# TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0  # 0=auto 1=always force non-interactive

# === Preflight UI Config Audit (m131) ===
# PREFLIGHT_UI_CONFIG_AUDIT_ENABLED=true  # Scan test framework configs for interactive-mode
# PREFLIGHT_UI_CONFIG_AUTO_FIX=true  # Auto-patch reporter: 'html' to CI-guarded form
# PREFLIGHT_BAK_RETAIN_COUNT=5       # Backup files to keep in .claude/preflight_bak/
EOF
}
```

**Why all keys below `BUILD_FIX_ENABLED=true` are commented:** The
defaults registered in `config_defaults.sh` (m136) are sensible for
all projects. The migration only needs to make the keys discoverable —
a developer reading their `pipeline.conf` can now see them. The one
exception is `BUILD_FIX_ENABLED=true` which is active because: (a) it
is the sentinel for idempotency, and (b) the loop is safe to enable
by default — it only fires on code_dominant errors and is bounded by
`BUILD_FIX_MAX_ATTEMPTS`.

#### Sub-task B — `_032_update_gitignore`

Adds the two new arc artifact paths to `.gitignore` if not already present.
Follows the same idempotent grep-then-append pattern already used by
`_ensure_gitignore_entries` in `lib/common.sh`.

```bash
_032_update_gitignore() {
    local gi_file="$1"

    # Create .gitignore if it doesn't exist yet
    [[ -f "$gi_file" ]] || touch "$gi_file"

    local _added=0
    local -a _new_entries=(
        ".tekhton/BUILD_FIX_REPORT.md"
        ".claude/preflight_bak/"
    )
    local entry
    for entry in "${_new_entries[@]}"; do
        if ! grep -qF "$entry" "$gi_file" 2>/dev/null; then
            if (( _added == 0 )) && ! grep -qF "# Tekhton runtime artifacts" "$gi_file" 2>/dev/null; then
                # Ensure newline before new block
                if [[ -s "$gi_file" ]] && [[ "$(tail -c1 "$gi_file" | wc -l)" -eq 0 ]]; then
                    printf '\n' >> "$gi_file"
                fi
                printf '\n# Tekhton runtime artifacts (added by V3.2 migration)\n' >> "$gi_file"
            fi
            printf '%s\n' "$entry" >> "$gi_file"
            _added=$(( _added + 1 ))
        fi
    done

    (( _added > 0 )) && log "Added ${_added} gitignore entry/entries for resilience arc artifacts."
    return 0
}
```

**Edge case — `.gitignore` section header already exists:** The inner
`grep -qF "# Tekhton runtime artifacts"` guard prevents adding a second
block header on projects that had `_ensure_gitignore_entries` run
previously (e.g., via `--plan`). Each new entry gets its own
idempotency guard.

#### Sub-task C — `_032_create_preflight_bak_dir`

Creates `.claude/preflight_bak/` with a `.gitkeep` so the directory
exists before the first preflight auto-fix, and git-tracks it correctly
(the directory itself is gitignored via `preflight_bak/` but the
`.gitkeep` is exempt).

```bash
_032_create_preflight_bak_dir() {
    local project_dir="$1"
    local bak_dir="${project_dir}/.claude/preflight_bak"

    [[ -d "$bak_dir" ]] && return 0  # Already exists

    mkdir -p "$bak_dir"
    # .gitkeep is NOT gitignored — the entry in .gitignore covers the
    # directory contents but the dir itself needs to be tracked.
    # Use an empty .gitkeep to satisfy git's no-empty-directory rule.
    touch "${bak_dir}/.gitkeep"
    log "Created .claude/preflight_bak/ for preflight auto-fix backups."
    return 0
}
```

**Why `.gitkeep` is not affected by the `.gitignore` entry:** The entry
added to `.gitignore` is `.claude/preflight_bak/` — trailing slash
means it applies to the directory contents only (files within it), not
to the directory itself or `.gitkeep`. This is standard git behaviour.
If the project's `.gitignore` uses a pattern without trailing slash
(e.g. `preflight_bak`), it would affect `.gitkeep` too — but our entry
includes the full `.claude/preflight_bak/` path with trailing slash.

### Complete migration script

```bash
#!/usr/bin/env bash
# =============================================================================
# 031_to_032.sh — V3.1 → V3.2 migration
#
# Adds resilience arc config section to pipeline.conf (m126–m136):
#   - Build-fix continuation loop keys
#   - UI gate non-interactive enforcement keys
#   - Preflight UI config audit keys
# Updates .gitignore with new arc artifact paths.
# Creates .claude/preflight_bak/ directory.
#
# Part of Tekhton migration framework — sourced by lib/migrate.sh
# =============================================================================
set -euo pipefail

migration_version() { echo "3.2"; }

migration_description() {
    echo "Add resilience arc config (m126–m136): build-fix, UI gate, preflight audit"
}

migration_check() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"
    [[ -f "$conf_file" ]] || return 1
    grep -q '^BUILD_FIX_ENABLED=' "$conf_file" 2>/dev/null && return 1
    return 0
}

migration_apply() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"
    local gitignore_file="${project_dir}/.gitignore"
    [[ -f "$conf_file" ]] || return 1
    _032_append_arc_config_section "$conf_file"
    _032_update_gitignore "$gitignore_file"
    _032_create_preflight_bak_dir "$project_dir"
    return 0
}

_032_append_arc_config_section() { ... }
_032_update_gitignore() { ... }
_032_create_preflight_bak_dir() { ... }
```

(Full function bodies from the design sections above.)

### Migration runner integration

No changes to `lib/migrate.sh` are needed. The runner auto-discovers
scripts via `_list_migration_scripts` → `bash -c "source '$script' &&
migration_version"`. Placing `031_to_032.sh` in `${TEKHTON_HOME}/migrations/`
is sufficient.

`detect_config_version` in `lib/migrate.sh` infers version from
`TEKHTON_CONFIG_VERSION=` in `pipeline.conf`. After migration runs, the
watermark is bumped by `_write_config_version` — no changes needed there
either.

**Existing V3.0 projects** (no `TEKHTON_DIR`): The `003_to_031.sh`
migration runs first (3.0 → 3.1), then `031_to_032.sh` runs (3.1 → 3.2).
Both are idempotent; the runner chains them automatically.

**Projects with V3.1 already** (have `.tekhton/`): Only `031_to_032.sh`
runs. `003_to_031.sh` is skipped (already applied — `_version_lt`
filter).

### Tests

Add to `tests/test_migrate.sh` (or create `tests/test_migrate_032.sh`
if the existing test file is already long):

```
T1: migration_check on a V3.1 conf without BUILD_FIX_ENABLED → returns 0 (needs migration)
T2: migration_check on a conf with BUILD_FIX_ENABLED= → returns 1 (already migrated)
T3: migration_check with no pipeline.conf → returns 1 (skip — express mode)
T4: migration_apply on V3.1 conf → conf now contains BUILD_FIX_ENABLED=true
T5: migration_apply on V3.1 conf → conf contains # BUILD_FIX_MAX_ATTEMPTS (commented)
T6: migration_apply on V3.1 conf → .gitignore gains .tekhton/BUILD_FIX_REPORT.md
T7: migration_apply on V3.1 conf → .gitignore gains .claude/preflight_bak/
T8: migration_apply called twice (idempotency) → second call returns 1 (migration_check),
    conf does not contain duplicate BUILD_FIX_ENABLED entries
T9: migration_apply on conf with existing "# Tekhton runtime artifacts" section →
    new gitignore entries appear after it, not in a second header block
T10: .claude/preflight_bak/ created with .gitkeep on fresh project
T11: .claude/preflight_bak/ already exists → migration_apply does not fail,
     no .gitkeep duplication
T12: migration_apply on project with no .gitignore → creates .gitignore with entries
```

Fixture pattern:

```bash
# Create a minimal V3.1 pipeline.conf fixture
cat > "${TMPDIR}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-project"
TEKHTON_CONFIG_VERSION=3.1
TEKHTON_DIR=".tekhton"
BUILD_CHECK_CMD="npm run build"
TEST_CMD="npm test"
SECURITY_AGENT_ENABLED=true
MILESTONE_DAG_ENABLED=true
EOF
```

## Files Modified

| File | Change |
|------|--------|
| `migrations/031_to_032.sh` | **New file.** Complete migration script with all four functions and three sub-tasks. |
| `tests/test_migrate_032.sh` (or `tests/test_migrate.sh`) | 12 new test cases. |
| `tekhton.sh` | Bump `TEKHTON_VERSION` to `3.137.0`. |
| `.claude/milestones/MANIFEST.cfg` | Add M137 row (`depends_on=m135,m136`, group `resilience`). |

No changes to any `lib/` files. Migration scripts are self-contained.

## Acceptance Criteria

- [ ] `migrations/031_to_032.sh` exists with correct `migration_version` → `"3.2"`.
- [ ] `migration_check` returns `0` on a V3.1 pipeline.conf without `BUILD_FIX_ENABLED`.
- [ ] `migration_check` returns `1` on a conf already containing `BUILD_FIX_ENABLED=`.
- [ ] `migration_check` returns `1` when `pipeline.conf` does not exist.
- [ ] `migration_apply` appends the V3.2 section with `BUILD_FIX_ENABLED=true` as the first line.
- [ ] All thirteen arc vars are present in the appended section (1 active: `BUILD_FIX_ENABLED=true`; 12 commented).
- [ ] `.gitignore` gains `.tekhton/BUILD_FIX_REPORT.md` after migration.
- [ ] `.gitignore` gains `.claude/preflight_bak/` after migration.
- [ ] Calling `migration_apply` twice does not produce duplicate `BUILD_FIX_ENABLED` lines.
- [ ] `.claude/preflight_bak/.gitkeep` exists after migration on a fresh project.
- [ ] `migration_apply` is a no-op (returns `0`) when `preflight_bak/` already exists.
- [ ] The migration chains correctly after `003_to_031.sh` (V3.0 → V3.1 → V3.2) on a V3.0 project.
- [ ] `shellcheck` clean for `migrations/031_to_032.sh`.
- [ ] All 12 test cases pass.
- [ ] `tekhton.sh` `TEKHTON_VERSION` is `3.137.0`.
- [ ] `.claude/milestones/MANIFEST.cfg` contains the M137 row (`depends_on=m135,m136`, group `resilience`).

## Watch For

- **`migration_check` return codes are counter-intuitive.** `return 0` means the migration *is needed* and the runner will proceed. `return 1` means already applied or not applicable — the runner skips. This is the inverse of typical "success = 0" bash convention. The `run_migrations` loop reads `if ! migration_check "$project_dir"; then log "Already applied"` — the `!` inverts as expected. Do not swap the codes.
- **`set -euo pipefail` propagates to the caller.** The script is `source`d (not run in a subshell) by `lib/migrate.sh`. `set -euo pipefail` at the top of the sourced script modifies the calling shell's options. This is the established pattern (`002_to_003.sh` and `003_to_031.sh` do the same) — follow it exactly, and do not add a balancing `set +euo pipefail` at the end.
- **Private helper prefix `_032_` is load-order critical.** During a V3.0 → V3.1 → V3.2 chain, `002_to_003.sh` and `003_to_031.sh` are also sourced into the same shell session. All helper functions must carry the `_032_` prefix to prevent name collision with `_031_*` or `_003_*` helpers from those scripts.
- **Sentinel key must be the first line emitted.** `BUILD_FIX_ENABLED=true` must appear as the first line in `_032_append_arc_config_section`'s heredoc. If the order is rearranged and the sentinel moves after another key, `migration_check` still works (grep matches anywhere in the file), but the stated design rationale breaks and future readers will be confused.
- **Heredoc boundary blank lines.** The `cat >> "$conf_file" << 'EOF'` block begins with a blank line and ends with a blank line before `EOF`. This ensures exactly one blank line between the last existing content and the new section header, and one trailing blank line after the block. Do not remove either boundary line.
- **`.gitignore` trailing-slash semantics.** The entry `.claude/preflight_bak/` (with trailing slash) gitignores directory *contents* but not the directory itself or the `.gitkeep` file. Omitting the trailing slash (e.g. `.claude/preflight_bak`) would also ignore `.gitkeep`, preventing the directory from being tracked. The trailing slash must be preserved.
- **No changes to `lib/migrate.sh`.** The migration runner auto-discovers scripts by version; placing `031_to_032.sh` in the `migrations/` directory is all that is required. Do not modify the runner, `detect_config_version`, or `_write_config_version`.

## Seeds Forward

- **m138 — Runtime CI environment auto-detection.** The next arc milestone adds `_detect_runtime_ci_environment` and `_get_ci_platform_name` to `lib/config_defaults.sh`, executed before the `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` `:=` default. When a CI environment is detected and the variable is unset, m138 sets it to `1` automatically. m137's migration leaves `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` as a commented key in `pipeline.conf`; operators who uncomment and set it explicitly will have their value honoured by m138's logic. No file conflict.
- **Future migration scripts (V3.3+).** The naming convention (`NNN_to_NNN.sh`), the `_NNN_*` private helper prefix, the sentinel-key idempotency pattern, and the four-function contract established here are the canonical template for subsequent migration scripts. Follow them.
