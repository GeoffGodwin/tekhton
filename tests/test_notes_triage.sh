#!/usr/bin/env bash
# =============================================================================
# test_notes_triage.sh — m24 skip-stub.
#
# lib/notes_triage*.sh files were deleted in m24. The heuristic
# scoring + report ports to internal/notes/triage.go and the user
# surface is `tekhton note triage [--tag TAG]`.
#
# Coverage:
#   - internal/notes/triage.go (heuristic + cached-hash shortcut)
#   - cmd/tekhton/note_test.go (CLI smoke)
# The interactive promotion-to-milestone flow (`triage_before_claim`)
# is the only behaviour that has not yet ported; lib/human_mode_notes.sh
# stubs it as "always proceed" until the follow-on milestone.
# =============================================================================
echo "test_notes_triage.sh: skipped (m24 — see internal/notes/triage.go)"
exit 0
