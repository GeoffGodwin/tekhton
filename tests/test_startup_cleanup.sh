#!/usr/bin/env bash
# =============================================================================
# test_startup_cleanup.sh — m24 skip-stub.
#
# Exercised the clear-completed sweep across HUMAN_NOTES.md +
# NON_BLOCKING_LOG.md + DRIFT_LOG.md. The notes-side path is now the
# `tekhton note clear-completed` CLI (cmd/tekhton/note_human.go ->
# internal/notes/cleanup.go::RemoveDone) and the non-blocking /
# drift-log paths are still bash, covered by:
#   - tests/test_drift_cleanup.sh
#   - tests/test_clear_resolved_nonblocking_notes.sh
#   - tests/test_cleanup_notes.sh (skip-stub)
# =============================================================================
echo "test_startup_cleanup.sh: skipped (m24 — see internal/notes/cleanup.go::RemoveDone)"
exit 0
