#!/usr/bin/env bash
# =============================================================================
# test_notes_cli_printf.sh — m24 skip-stub.
#
# Exercised printf-format edge cases in the deleted lib/notes_cli.sh.
# The Go `tekhton note list` writer uses a fixed Fprintf format string
# so the original failure mode (uncontrolled format injection via
# user-supplied note titles) is structurally impossible. Coverage in
# cmd/tekhton/note_test.go::TestNoteAddListDone exercises the writer
# path; internal/notes/parser_test.go covers metadata round-trip.
# =============================================================================
echo "test_notes_cli_printf.sh: skipped (m24 — see cmd/tekhton/note_test.go)"
exit 0
