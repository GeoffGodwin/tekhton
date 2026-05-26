#!/usr/bin/env bash
# =============================================================================
# test_with_notes_flag.sh — m24 skip-stub.
#
# Exercised the should-claim predicate (and its WITH_NOTES branch) from
# the deleted lib/notes.sh. The Go port is the
# `tekhton note should-claim` hidden CLI subcommand
# (cmd/tekhton/note_human.go). Coverage:
#   - cmd/tekhton/note_test.go (smoke)
#   - integration via stages/coder.sh::_m24_notes_should_claim wrapper
# =============================================================================
echo "test_with_notes_flag.sh: skipped (m24 — see cmd/tekhton/note_human.go::newNoteShouldClaimCmd)"
exit 0
