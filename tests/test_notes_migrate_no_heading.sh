#!/usr/bin/env bash
# =============================================================================
# test_notes_migrate_no_heading.sh — m24 skip-stub.
#
# lib/notes_migrate.sh was deleted; V1→V2 migration ports to
# internal/notes/migrate.go and the user surface is `tekhton note migrate`.
# The no-heading edge case is covered by internal/notes/migrate_test.go.
# =============================================================================
echo "test_notes_migrate_no_heading.sh: skipped (m24 — see internal/notes/migrate_test.go)"
exit 0
