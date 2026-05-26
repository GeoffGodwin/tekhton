#!/usr/bin/env bash
# =============================================================================
# test_human_mode_state_resume.sh — m24 skip-stub.
#
# Sourced the deleted lib/notes_core.sh + lib/notes_single.sh. The
# state-machine semantics ported to internal/notes/state.go +
# internal/notes/single.go. Crash-resume guarantees (CURRENT_NOTE_ID
# env restore, idempotent re-claim of an Active note) are now bash
# wrappers in lib/human_mode_notes.sh that exec `tekhton note
# pick-next/claim/find`.
# =============================================================================
echo "test_human_mode_state_resume.sh: skipped (m24 — see internal/notes/single.go)"
exit 0
