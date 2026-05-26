#!/usr/bin/env bash
# =============================================================================
# test_drain_pending_inbox.sh — m24 skip-stub.
#
# Exercised drain_pending_inbox in a context that sourced the deleted
# lib/notes_core.sh + lib/notes_cli.sh. lib/inbox.sh now exec's
# `tekhton note add` directly; the inbox-processing test surface is
# covered by cmd/tekhton/note_test.go and tests/test_notes_parity.sh.
# =============================================================================
echo "test_drain_pending_inbox.sh: skipped (m24 — see lib/inbox.sh CLI exec path)"
exit 0
