#!/usr/bin/env bash
# =============================================================================
# test_drift_config.sh — m25 skip-stub.
#
# Exercised drift-related config keys that loaded into lib/drift.sh
# globals (deleted in m25). The thresholds (DRIFT_OBSERVATION_THRESHOLD,
# DRIFT_RUNS_SINCE_AUDIT_THRESHOLD) are still part of pipeline.conf and
# are now consumed by `tekhton drift audit-status`; see
# cmd/tekhton/drift_test.go::TestDriftAuditStatus_JSONOutput.
# =============================================================================
echo "test_drift_config.sh: skipped (m25 — see cmd/tekhton/drift_test.go)"
exit 0
