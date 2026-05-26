#!/usr/bin/env bash
# =============================================================================
# test_drift_cleanup.sh — m25 skip-stub.
#
# Exercised the non-blocking-log lifecycle in lib/drift_cleanup.sh (deleted
# in m25). Equivalent coverage lives in internal/drift/nonblocking_test.go
# plus internal/finalize/notes_hooks_test.go::TestPruneResolvedNonBlocking.
# =============================================================================
echo "test_drift_cleanup.sh: skipped (m25 — see internal/drift/nonblocking_test.go)"
exit 0
