#!/usr/bin/env bash
# =============================================================================
# test_clarify_intake_handler.sh — m25 skip-stub.
#
# Exercised _intake_handle_needs_clarity() in lib/intake_verdict_handlers.sh
# which previously sourced lib/clarify.sh (deleted in m25). The intake
# handler now invokes `tekhton clarify handle` via the CLI; the
# clarification detection/handle logic itself is covered by
# internal/clarify/{detect,handle}_test.go.
# =============================================================================
echo "test_clarify_intake_handler.sh: skipped (m25 — see internal/clarify/handle_test.go)"
exit 0
