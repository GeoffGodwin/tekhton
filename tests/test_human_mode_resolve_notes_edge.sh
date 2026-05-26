#!/usr/bin/env bash
# =============================================================================
# test_human_mode_resolve_notes_edge.sh — m24 skip-stub.
#
# Exercised the bash `_hook_resolve_notes` fall-through paths from the
# deleted lib/notes.sh + lib/finalize_core_hooks.sh. The hook ports to
# internal/finalize/resolve_notes.go (uses notes.ResolveActive) and
# unit coverage lives in internal/finalize/notes_hooks_test.go.
# =============================================================================
echo "test_human_mode_resolve_notes_edge.sh: skipped (m24 — see internal/finalize/notes_hooks_test.go)"
exit 0
