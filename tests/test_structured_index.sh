#!/usr/bin/env bash
# Skip-stubbed at m29.2.
#
# This test sourced lib/detect.sh for the `_DETECT_EXCLUDE_DIRS` constant
# and `_extract_json_keys` helper. Those moved to internal/detect/ in
# m29.2 and are not exposed back to bash. The behavior these tests cover
# (crawler + index emission) is exercised by tests/test_indexer*.sh and
# the upstream cmd/tekhton bash test harness; restoring a shim purely
# for these tests is not worth the wedge complexity.
echo "SKIP $(basename "${BASH_SOURCE[0]}"): m29.2 — relied on deleted lib/detect.sh internal constants"
exit 0
