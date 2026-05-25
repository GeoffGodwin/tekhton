#!/usr/bin/env bash
# m23: This test exercised TUI bash globals (_TUI_STAGES_COMPLETE,
# _TUI_RECENT_EVENTS, _TUI_STAGE_ORDER, _TUI_STAGE_CYCLE,
# _TUI_CLOSED_LIFECYCLE_IDS) and/or internal helpers (_tui_json_build_status,
# _tui_check_sidecar_liveness, _tui_autoclose_substage_if_open) that moved
# to the Go-owned internal/tui/ package alongside the m23 writer port. The
# six bash files that defined them (tui_helpers, tui_liveness, tui_ops,
# tui_ops_pause, tui_ops_substage; lib/tui.sh now a thin shim) were deleted
# at m23 close.
#
# Replacement coverage lives in internal/tui/*_test.go:
#   - state_test.go        — atomic write, legacy/envelope round-trip
#   - ops_test.go          — stage begin/end, lifecycle ids, drop-late ticks
#   - pause_test.go        — enter/update/exit pause state
#   - liveness_test.go     — sampled probe, dead-sidecar warn
# Plus cmd/tekhton/tui_test.go covers the CLI handler boundary.
#
# Migrating the bash tests to drive `tekhton tui ...` CLI invocations is
# tracked as follow-up work; skipping here preserves the green-tests
# invariant required by acceptance criteria.
printf 'SKIP %s: ported to internal/tui/ — see internal/tui/*_test.go\n' "${BASH_SOURCE[0]##*/}"
exit 0
