#!/usr/bin/env bash
# Skip-stubbed at m29.2.
#
# This test exercised the deleted lib/detect*.sh files (ported to
# internal/detect/ in m29.2). Functional coverage now lives in:
#   - internal/detect/<file>_test.go     (Go unit tests per detector)
#   - tests/test_detect_parity.sh        (byte-identical bash-baseline gate)
#   - cmd/tekhton/detect_test.go         (CLI surface + registration order)
#
# Restoring this test as a bash shim-boundary test is reasonable if a
# specific behavior re-emerges as a regression — at that point write a
# narrow shim test that drives _tk_detect_* wrappers, not the deleted
# bash internals.
echo "SKIP $(basename "${BASH_SOURCE[0]}"): m29.2 — bash detect subsystem ported to internal/detect/"
exit 0
