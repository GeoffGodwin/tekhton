#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_preflight.sh — superseded by internal/preflight/*_test.go (m22)
#
# Bash-level coverage of `_preflight_check_*` and `run_preflight_checks`
# ported to the Go package as part of m22 (Preflight Port). The bash
# subsystem (lib/preflight*.sh) was deleted in the same milestone, so
# sourcing it would now fail at the top of this test.
#
# Coverage equivalent:
#   - go test ./internal/preflight/... covers every sub-check via
#     foundation_test.go, env_test.go, ui_audit_test.go, services_test.go,
#     services_infer_test.go.
#   - cmd/tekhton/preflight_test.go covers the CLI surface.
#   - tests/test_preflight_parity.sh asserts the Go orchestrator's report
#     output stays in the bash-compatible format dashboard parsers still
#     consume through m23.
#
# This file remains as a skip-stub so tests/run_tests.sh's pass count
# stays stable across m22 close; deletion comes later once no harness
# expects the filename.
# =============================================================================

echo "=== test_preflight.sh ==="
echo "  SKIPPED: superseded by internal/preflight/*_test.go (m22)"
exit 0
