#!/usr/bin/env bash
# =============================================================================
# test_human_mode_crash_resume.sh — m24 skip-stub.
#
# Exercised pick_next_note / claim_single_note / extract_note_text from
# the deleted lib/notes_single.sh. The Go ports live in
# internal/notes/single.go (PickNext, ClaimSingle, ExtractText) and
# the bash bridge for the --human mode loop is in
# lib/human_mode_notes.sh, calling `tekhton note pick-next/claim/find`.
# Crash-recovery semantics (CURRENT_NOTE_ID env restore) are now
# enforced by the Go-side state machine — re-claim of an Active note
# is a soft success.
# =============================================================================
echo "test_human_mode_crash_resume.sh: skipped (m24 — see internal/notes/single.go)"
exit 0
