#!/usr/bin/env bash
# =============================================================================
# test_should_claim_notes.sh — m24 skip-stub.
#
# Exercised should_claim_notes from the deleted lib/notes.sh. The Go
# port is `tekhton note should-claim` (cmd/tekhton/note_human.go) —
# WITH_NOTES, HUMAN_MODE, and NOTES_FILTER env vars are the same
# inputs that gate the predicate.
# =============================================================================
echo "test_should_claim_notes.sh: skipped (m24 — see cmd/tekhton/note_human.go::newNoteShouldClaimCmd)"
exit 0
