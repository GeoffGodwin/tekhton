#!/usr/bin/env bash
# =============================================================================
# test_clarify_coder_nullrun.sh — m25 skip-stub.
#
# Exercised post-clarification null-run detection in stages/coder.sh that
# relied on lib/clarify.sh::detect_clarifications (deleted in m25). The
# coder stage now invokes `tekhton clarify detect/handle` via the CLI.
# Equivalent coverage for the underlying detection logic lives in
# internal/clarify/detect_test.go.
# =============================================================================
echo "test_clarify_coder_nullrun.sh: skipped (m25 — see internal/clarify/detect_test.go)"
exit 0
