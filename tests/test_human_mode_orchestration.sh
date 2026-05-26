#!/usr/bin/env bash
# =============================================================================
# test_human_mode_orchestration.sh — m24 skip-stub.
#
# Exercised pick_next_note, claim_single_note, resolve_single_note,
# count_unchecked_notes from the deleted lib/notes*.sh family. The
# Go ports live in internal/notes/single.go; coverage:
#   - internal/notes/single.go        (PickNext / ClaimSingle / ResolveSingle)
#   - internal/notes/cleanup.go       (ClearActive / ResolveActive)
#   - cmd/tekhton/note_human.go       (pick-next / claim-bulk / resolve-bulk)
#   - cmd/tekhton/note_test.go        (CLI smoke + JSON envelope)
# =============================================================================
echo "test_human_mode_orchestration.sh: skipped (m24 — see internal/notes/single.go)"
exit 0
