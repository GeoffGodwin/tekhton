#!/usr/bin/env bash
# =============================================================================
# test_human_notes_lifecycle.sh — m24 skip-stub.
#
# Exercised the three-state [ ] → [~] → [x] / [ ] lifecycle from the
# deleted lib/notes_core.sh. The state machine ports to
# internal/notes/state.go; transition coverage:
#   - internal/notes/state_test.go (ParseCheckbox + Checkbox round-trip)
#   - internal/notes/cleanup_test.go (Claim / ResolveActive / ClearActive)
#   - tests/test_notes_parity.sh    (scenario 3 — post-completion sweep)
# =============================================================================
echo "test_human_notes_lifecycle.sh: skipped (m24 — see internal/notes/state.go)"
exit 0
