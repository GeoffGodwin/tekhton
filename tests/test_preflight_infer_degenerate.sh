#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_preflight_infer_degenerate.sh — superseded by services_infer_test.go (m22)
#
# The bash inference helper (_pf_infer_from_compose) was deleted in m22;
# its Go replacement (inferFromCompose in internal/preflight/services_infer.go)
# uses a regex-based service-name matcher with deterministic guard ordering
# so the "service named like image:" failure mode is structurally
# impossible. Coverage equivalent: services_infer_test.go.
# =============================================================================

echo "=== test_preflight_infer_degenerate.sh ==="
echo "  SKIPPED: superseded by internal/preflight/services_infer_test.go (m22)"
exit 0
