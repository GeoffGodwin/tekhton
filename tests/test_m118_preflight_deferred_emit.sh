#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_m118_preflight_deferred_emit.sh — superseded by Go (m22)
#
# M118 was the "set _PREFLIGHT_SUMMARY instead of calling success()" timing
# fix on lib/preflight.sh's PASS path. With the bash preflight subsystem
# deleted in m22, the deferred-emit dance is no longer needed — the
# in-process Go orchestrator writes its summary line synchronously after
# the TUI pill state, eliminating the bash-era race the M118 fix patched
# around. The summary-line contract is exercised by SummaryLine() in
# internal/preflight/orchestrator_test.go and by the runner integration
# test in internal/runner/hooks_test.go.
# =============================================================================

echo "=== test_m118_preflight_deferred_emit.sh ==="
echo "  SKIPPED: superseded by Go orchestrator's synchronous summary line (m22)"
exit 0
