# Coder Summary

## Status: COMPLETE

## What Was Implemented

M137 — Resilience Arc V3.2 Migration Script. Created the V3.1 → V3.2
migration script that automates upgrade of a pre-arc project to the
resilience arc (m126–m136) configuration surface. No runtime changes
to any `lib/`, `stages/`, or `prompts/` files. The migration runner
auto-discovers the new script via `_list_migration_scripts` — no
changes to `lib/migrate.sh` were needed.

**Sub-task A — `_032_append_arc_config_section`.** Appends a
commented `V3.2 Resilience Arc` section to `pipeline.conf` with all
13 arc keys. `BUILD_FIX_ENABLED=true` is the first emitted key (active,
not commented) and serves as the idempotency sentinel for
`migration_check`. The other 12 keys are commented `# KEY=value` lines
so the operator can discover and tune them; the live runtime values
come from `lib/config_defaults.sh` (registered by M136).

**Sub-task B — `_032_update_gitignore`.** Adds the two new arc
artifact paths (`.tekhton/BUILD_FIX_REPORT.md`,
`.claude/preflight_bak/`) to `.gitignore` if not already present.
Mirrors the idempotent grep-then-append pattern used by
`_ensure_gitignore_entries` in `lib/common.sh`. Reuses an existing
`# Tekhton runtime artifacts` header if present (e.g., on projects
that ran `--init` after M135 landed) and only emits the V3.2-tagged
header when no Tekhton runtime artifacts header exists yet.

**Sub-task C — `_032_create_preflight_bak_dir`.** Creates
`.claude/preflight_bak/` so the backup tree exists before the first
preflight auto-fix attempt. Idempotent: returns 0 immediately if the
directory is already present.

## Plan Deviations

**1. `BUILD_FIX_MAX_TURN_MULTIPLIER` documented as `100` in the
appended section, not `1.0`.** The design block in the milestone
showed `# BUILD_FIX_MAX_TURN_MULTIPLIER=1.0`, but the M128 runtime
contract (preserved by M136) uses integer-percent encoding
(`100 = 1.0×`) — the build-fix loop performs
`(( ... * MULTIPLIER / 100 ))` arithmetic. Documenting `1.0` would
mislead any operator who uncomments the line. Used `100` with an
inline comment explaining the encoding, matching the existing
documentation in `templates/pipeline.conf.example` (where M136 also
uses `100` for the same key for the same reason). This same
correction was made by M136 for the example file; M137 follows the
established precedent.

**2. `PREFLIGHT_BAK_RETAIN_COUNT` documented as `10` in the
appended section, not `5`.** The design block showed `=5`, but the
runtime default registered by M136 in `lib/config_defaults.sh` is
`10`. Using `5` in the migrated file would mislead the operator
about what the actual default is when the line is commented.

## Files Modified

- `migrations/031_to_032.sh` (NEW) — V3.1 → V3.2 migration script,
  128 lines. Implements all four required functions (`migration_version`,
  `migration_description`, `migration_check`, `migration_apply`) and
  the three sub-tasks (`_032_append_arc_config_section`,
  `_032_update_gitignore`, `_032_create_preflight_bak_dir`). Uses the
  `_032_*` private helper prefix to prevent collision with `_031_*` /
  `_003_*` helpers when chained migrations source into the same shell.
- `tests/test_migrate_032.sh` (NEW) — 257 lines, 18 assertions across
  the 12 specified test cases (T1–T12, several with `a/b` sub-asserts).
  Self-contained: stubs out `log`/`warn`/`success`/`error`/`header`
  before sourcing the migration script, builds V3.1 fixtures with
  `_make_v31_project`, and verifies idempotency, gitignore handling,
  and pre-existing state.
- `VERSION` — bumped from `3.136.0` to `3.137.0` per acceptance
  criteria.

The M137 row in `.claude/milestones/MANIFEST.cfg` was already in place
from a previous run (status `in_progress`); the milestone framework
will mark it `done` on successful completion.

## Human Notes Status

N/A — no human notes for this task.

## Docs Updated

- `README.md` — Updated version tagline from v3.125.4 to v3.137.0

## Verification

- `shellcheck tekhton.sh lib/*.sh stages/*.sh migrations/*.sh` —
  clean (no output, exit 0).
- `bash tests/test_migrate_032.sh` — 18 passed, 0 failed.
- `bash tests/run_tests.sh` — 469 shell tests passed (up from 468
  pre-task — the new test file was picked up by `run_tests.sh`'s
  `test_*.sh` glob without modification), 0 failed; 247 Python tests
  passed, 14 skipped, 0 failed.
- File line counts: `migrations/031_to_032.sh` 128,
  `tests/test_migrate_032.sh` 257 — both under the 300-line ceiling.
