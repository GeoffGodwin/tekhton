#!/usr/bin/env bash
# =============================================================================
# test_notes_cli.sh — m24 skip-stub.
#
# The bash lib/notes_cli.sh + lib/notes_cli_write.sh files were deleted
# in m24 as part of the notes-subsystem port to internal/notes/. The
# `tekhton note add/list/done/...` CLI is the replacement surface;
# coverage now lives in:
#
#   - cmd/tekhton/note_test.go            (CLI smoke + JSON envelope)
#   - internal/notes/add_test.go          (add semantics, tag validation)
#   - internal/notes/parser_test.go       (round-trip fidelity)
#   - tests/test_notes_parity.sh          (cross-subsystem parity gate)
# =============================================================================
echo "test_notes_cli.sh: skipped (m24 — see cmd/tekhton/note_test.go)"
exit 0
