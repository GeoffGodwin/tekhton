#!/usr/bin/env bash
# =============================================================================
# test_notes_acceptance.sh — m24 skip-stub.
#
# lib/notes_acceptance.sh + lib/notes_acceptance_helpers.sh were
# deleted in m24. The heuristics ported to internal/notes/acceptance.go
# and the `_hook_note_acceptance` finalize hook lives at
# internal/finalize/note_acceptance.go.
#
# Coverage:
#   - internal/notes/acceptance.go (RunAcceptance — heuristic body)
#   - internal/finalize/notes_hooks_test.go (hook wiring)
# =============================================================================
echo "test_notes_acceptance.sh: skipped (m24 — see internal/notes/ acceptance tests)"
exit 0
