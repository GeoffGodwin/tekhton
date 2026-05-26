#!/usr/bin/env bash
# =============================================================================
# test_drift_resolution_sourcing_convention.sh — m25 skip-stub.
#
# Tested the bash source-order convention for drift.sh / drift_cleanup.sh /
# drift_artifacts.sh — all deleted in m25 in favour of internal/drift/.
# Sourcing order is no longer load-bearing now that Go owns the
# subsystem. No Go replacement needed; the concern goes away with the
# bash files.
# =============================================================================
echo "test_drift_resolution_sourcing_convention.sh: skipped (m25 — bash sourcing replaced by internal/drift/)"
exit 0
