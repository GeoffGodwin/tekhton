#!/usr/bin/env bash
set -euo pipefail

# m33.1: Watchtower dashboard data layer ported to Go (internal/dashboard,
# cmd/tekhton/dashboard.go). Pre-m33.1 this test verified a specific
# `local` declaration in lib/dashboard_emitters.sh:162 caught a shellcheck
# bug. Post-m33.1 that file is deleted; the equivalent concern (using
# `local` for every loop variable inside a function so set -u stays clean)
# is enforced by Go's compile-time scoping and the parity gate.
#
# Skipping rather than rewriting — there is no equivalent Go assertion
# that would catch the same class of bug.
echo "SKIP: tests/test_nonblocking_dashboard_emitters.sh — m33.1 (bash-only concern, file deleted)."
exit 0
