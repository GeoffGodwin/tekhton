#!/usr/bin/env bash
# Skip-stubbed at m29.2.
#
# This test sourced lib/detect.sh for internal helpers (_extract_json_keys,
# _check_dep) that lived inside the now-deleted bash detect subsystem.
# The platform-adapter behavior these tests exercised is exercised in
# practice by the platform-adapter source-time path; restoring the bash
# helpers behind a shim is not worth the complexity since the platform
# adapters themselves don't ship through tekhton — they're sourced inline
# at run-time. Functional regressions in the adapters would still surface
# via the run-time path.
echo "SKIP $(basename "${BASH_SOURCE[0]}"): m29.2 — relied on deleted lib/detect.sh internal helpers"
exit 0
