## Test Audit Report

### Audit Summary
Tests audited: 1 file, 58 test cases (inline, not function-wrapped)
Verdict: CONCERNS

---

### Findings

#### COVERAGE: `rollback_migration()` is entirely untested
- File: tests/test_migration.sh:344–370 (Suite 10)
- Issue: Suite 10 is labeled "Rollback" but never calls `rollback_migration()`. It
  manually calls `backup_project_config`, appends a line to simulate migration, then
  manually does `cp backup → conf`. The actual `rollback_migration()` function in
  `lib/migrate.sh:189–259` contains: interactive `read -r choice`, array-based backup
  selection, multi-file restore (pipeline.conf + CLAUDE.md + MANIFEST.cfg + agents/),
  and error handling for missing backup dirs. None of that logic is exercised. The
  test only validates that a file copied from a backup matches the original — which is
  tautologically true and does not test the implementation at all.
- Severity: HIGH
- Action: Test `rollback_migration()` by pre-creating a backup dir (same structure as
  `backup_project_config` produces), then invoking `rollback_migration "$dir" <<< "1"`
  to simulate user selecting backup #1. Assert that all restored files match the
  backup contents. Test the "no backup dir" error path separately.

#### COVERAGE: `check_project_version()` is entirely untested
- File: tests/test_migration.sh (absent — no suite covers this function)
- Issue: `check_project_version()` in `lib/migrate.sh:371–425` is the startup
  integration point: it detects version mismatch, counts applicable migrations, and
  branches on `COMPLETE_MODE`, `AUTO_ADVANCE`, and `MIGRATION_AUTO`. All three
  control paths are untested. This is the primary consumer of `detect_config_version`
  and `run_migrations` — a bug here would silently skip migrations on every pipeline
  startup without any test catching it.
- Severity: HIGH
- Action: Add a suite that exercises: (a) no-mismatch path returns 0 without
  prompting; (b) COMPLETE_MODE=true auto-applies migrations without prompt; (c)
  MIGRATION_AUTO=false emits warning and returns 0 without applying. Use temp project
  dirs as in other suites. The interactive Y/n path can be covered with `<<< "Y"` and
  `<<< "n"` redirections.

#### INTEGRITY: `$?` assertions after `set -euo pipefail` calls always pass
- File: tests/test_migration.sh:207, 242, 405
- Issue: Three assertions — "4.2 V1→V2 apply success", "5.2 V2→V3 apply success",
  "12.1 no backup dir returns 0" — follow the pattern:
  ```
  some_function "$dir"
  assert_eq "..." "0" "$?"
  ```
  The test file has `set -euo pipefail` (line 9). If `some_function` returned non-zero,
  the script would have exited before reaching `assert_eq`. These assertions can never
  fire as failures — they are structurally inert. They add to the pass count without
  providing any detection capability.
- Severity: MEDIUM
- Action: Capture exit codes explicitly:
  ```bash
  migration_apply "$dir"; rc=$?
  assert_eq "4.2 V1→V2 apply success" "0" "$rc"
  ```
  Or wrap in a subshell: `(migration_apply "$dir")` and check `$?` in the parent.
  The `set -e` concern is removed if the function is called in a subshell.

#### COVERAGE: No test for mid-chain failure behavior in `run_migrations`
- File: tests/test_migration.sh (absent — Suite 8 only tests success path)
- Issue: `run_migrations()` in `lib/migrate.sh:263–322` has explicit logic to stop
  the chain and return 1 when a migration fails mid-chain (line 307–309). This path
  is never tested. A regression here could cause partial migrations to be silently
  reported as successful.
- Severity: MEDIUM
- Action: Create a temporary `migrations/` directory override with a fake migration
  script whose `migration_apply` returns 1. Verify that `run_migrations` exits
  non-zero and that the watermark is NOT written (since line 318 only runs on
  success).

#### COVERAGE: Missing edge case — `_write_config_version` when `pipeline.conf` absent
- File: tests/test_migration.sh (absent)
- Issue: `_write_config_version()` in `lib/migrate.sh:325–365` silently returns 0
  when `pipeline.conf` doesn't exist (`[[ -f "$conf_file" ]] || return 0`). Suite 7
  only tests insert and update on an existing file. The silent-no-op path is not
  verified, meaning a caller operating on a missing conf would get no error and no
  watermark — a potential silent failure.
- Severity: LOW
- Action: Add a test that calls `_write_config_version "$dir" "3.20"` on a project
  dir with no pipeline.conf, and asserts no file is created (not a crash).

#### INTEGRITY: Weak string match in test 11.3
- File: tests/test_migration.sh:390
- Issue: `assert_contains "11.3 status shows migrations available" "migration" "$status_output"` — the substring "migration" appears in the string "Config version:", "Running version:", "Status: 2 migration(s) available", and even the word "migrations". Any output from `show_migration_status` that mentions "migration" anywhere passes. The intent is to verify that the status line correctly reports a count, but the assertion would pass even if the count was wrong.
- Severity: LOW
- Action: Assert the full expected substring: `"migration(s) available"` — or better,
  check for `"2 migration"` to verify the count matches the two migrations applicable
  from V1.0 to V3.20.
