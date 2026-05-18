#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_preflight_ui_config.sh — superseded by ui_audit_test.go (m22)
#
# Bash-level M131 coverage (the four scanners in lib/preflight_checks_ui.sh)
# ported to internal/preflight/ui_audit.go + ui_audit_test.go in m22. The
# bash file was deleted; the Go test exercises the same PW-1 / PW-2 / PW-3
# / CY-1 / CY-2 / JV-1 paths plus the four PREFLIGHT_UI_* contract vars.
# =============================================================================

echo "=== test_preflight_ui_config.sh ==="
echo "  SKIPPED: superseded by internal/preflight/ui_audit_test.go (m22)"
exit 0
