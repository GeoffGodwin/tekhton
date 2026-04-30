# Coder Summary
## Status: COMPLETE
## What Was Implemented

Defensive observability fix for the TUI sidecar's silent-death failure mode.
The polish task asked for a sampled liveness check in `_tui_write_status` so
that a watchdog-self-terminated (or otherwise crashed) Python sidecar is
detected by the parent shell, instead of `_TUI_ACTIVE=true` lingering while
`tui_*` calls write to a status file that nobody reads.

The implementation already exists in HEAD (commit 513c792) and matches every
requirement in the task description. This run audited the existing code,
verified all three Scout-identified test files exercise the implementation
correctly, ran shellcheck and the full test suite, and updated CLAUDE.md and
ARCHITECTURE.md to document the new `lib/tui_liveness.sh` file (the prior
commit added the file but did not register it in the architecture map).

Behaviour summary:

- `_tui_write_status` (lib/tui_liveness.sh:31-49) calls
  `_tui_check_sidecar_liveness` on every entry; the probe itself only fires
  the `kill -0` syscall once per `_TUI_LIVENESS_INTERVAL` (default 20)
  writes, keeping the hot path cheap.
- On detected death the probe sets `_TUI_ACTIVE=false`, clears `_TUI_PID`,
  removes `${PROJECT_DIR}/.claude/tui_sidecar.pid`, and emits
  `warn "TUI sidecar exited (pid <pid>; likely watchdog timeout); continuing in CLI mode"`.
- All public `tui_*` callers in `lib/tui_ops.sh` already gate on
  `_TUI_ACTIVE` and become silent no-ops once the flag flips, so the user
  sees a clean TUI → CLI transition with one warn line marking the
  boundary.

## Root Cause (bugs only)

Not a bug — observability fix. The companion BUG entry in HUMAN_NOTES (the
missing per-iteration reset in `_run_human_complete_loop`) was addressed in
the same prior commit and is independent of this polish item.

## Files Modified

- `CLAUDE.md` — added `lib/tui_liveness.sh` to the repository layout tree
  under the lib/ section so its place in the architecture is visible.
- `ARCHITECTURE.md` — added a `lib/tui_liveness.sh` bullet to the Layer 3
  library list, documenting `_tui_write_status` / `_tui_check_sidecar_liveness`
  and the sampling-interval invariant.

Already in HEAD (audited, not modified by this run):

- `lib/tui_liveness.sh` (NEW in 513c792, 73 lines) — hosts the writer +
  sampled probe.
- `lib/tui.sh` — sources `lib/tui_liveness.sh`; old inline
  `_tui_write_status` removed.
- `tests/test_tui_liveness_probe.sh` (NEW in 513c792) — 9 probe-behaviour
  tests, all green.
- `tests/test_tui_liveness_sampling.sh` (NEW in 513c792) — 7 sampling /
  interval tests, all green.
- `tests/test_human_complete_loop_resets.sh` (NEW in 513c792) — 8 tests
  covering the companion BUG's reset-between-iterations behaviour, all green.

## Docs Updated

- `CLAUDE.md` — repository layout (lib/ tree).
- `ARCHITECTURE.md` — Layer 3 library catalogue.
- `docs/resilience.md` — added TUI sidecar health monitoring as a resilience feature.

## Verification

- `shellcheck -x tekhton.sh lib/*.sh stages/*.sh` — clean (only suppressed
  SC1091 source-not-following info, which is project-standard).
- `bash tests/run_tests.sh` — 479/479 shell tests passed, 250/250 python
  tests passed (14 skipped, expected).
- `wc -l lib/tui_liveness.sh` — 73 lines, well under the 300-line ceiling.
- Spot-check on the three Scout-identified tests:
  - `tests/test_tui_liveness_probe.sh` — 9/9 passed.
  - `tests/test_tui_liveness_sampling.sh` — 7/7 passed.
  - `tests/test_human_complete_loop_resets.sh` — 8/8 passed.

## Human Notes Status

No human notes were injected for this run.
