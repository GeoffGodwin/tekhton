# Docs Agent Report

## Files Updated
None.

## No Update Needed

This run implements a defensive observability fix (liveness probe for TUI sidecar)
that consists entirely of internal refactoring:

- `lib/tui_liveness.sh` (NEW) — internal utility, sourced by `lib/tui.sh`
- `_tui_check_sidecar_liveness` — internal sampled probe (no exported function)
- `_tui_write_status` — moved from `lib/tui.sh` to `lib/tui_liveness.sh` (internal)
- Per-iteration `out_reset_pass` + `tui_reset_for_next_milestone` calls in
  `_run_human_complete_loop` (internal control flow)

**No public-surface changes:** No new CLI flags, configuration keys, exported
functions, or API signatures. The user sees no change in behavior — the fix is
transparent. From the user's perspective, the TUI sidecar now gracefully detects
its own death and emits a `warn` line instead of silently failing.

Documentation (`README.md`, `docs/`) remains accurate. The `.sh` files already
document their own internals in header comments.

## Open Questions
None.
