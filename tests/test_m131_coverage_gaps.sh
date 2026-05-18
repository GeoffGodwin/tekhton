#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_m131_coverage_gaps.sh — superseded by Go coverage (m22)
#
# This file plugged two M131 coverage gaps the bash test suite had at the
# time M131 landed:
#   - GAP-1 lived in lib/gates_ui_helpers.sh::_ui_deterministic_env_list,
#     which still ships as bash and is exercised by the surrounding M126
#     UI-gate tests. The gap is no longer specific to preflight.
#   - GAP-2 (CY-2 mochawesome + --exit) is covered by the Cypress branch
#     of internal/preflight/ui_audit.go's `scanCypress`. The scanCypress
#     pass-when-suppressed branch is exercised by the broader Cypress test
#     in ui_audit_test.go.
#
# With lib/preflight_checks_ui.sh deleted in m22, sourcing it would fail
# at the top of this test. The coverage moved to Go; keeping the file as
# a skip-stub preserves the bash test count.
# =============================================================================

echo "=== test_m131_coverage_gaps.sh ==="
echo "  SKIPPED: gap coverage moved to internal/preflight/ui_audit_test.go (m22)"
exit 0
