#!/usr/bin/env bash
# =============================================================================
# test_inbox_processing.sh — m24 skip-stub.
#
# Exercised process_watchtower_inbox() from lib/inbox.sh in a context
# that sourced lib/notes_core.sh + lib/notes_cli.sh. Those notes files
# were deleted; lib/inbox.sh now exec's `tekhton note add` directly.
# Inbox integration coverage:
#   - cmd/tekhton/note_test.go    (add semantics)
#   - tests/test_notes_parity.sh  (CLI round-trip)
# =============================================================================
echo "test_inbox_processing.sh: skipped (m24 — see lib/inbox.sh CLI exec path)"
exit 0
