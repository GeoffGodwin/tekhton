# Coder Summary
## Status: COMPLETE

## What Was Implemented

Milestone 90 — Auto-Advance Fix. Two independent bugs in `--auto-advance` are fixed:

1. **CLI count argument:** `--auto-advance N "task"` now accepts an optional bare
   integer immediately after the flag and uses it as `AUTO_ADVANCE_LIMIT` for
   this invocation. If the next token is not an integer, it is left for normal
   task-string parsing — so `--auto-advance "M05"` continues to behave exactly
   as before.

2. **State-file lifecycle:** The advance chain previously short-circuited because
   `finalize_run` deletes `MILESTONE_STATE_FILE` before
   `_run_auto_advance_chain` calls `should_auto_advance`. The fix introduces an
   in-memory session counter `_AA_SESSION_ADVANCES` that:
   - Initializes to `0` in `tekhton.sh` when `--auto-advance` is set (and is exported).
   - Is the source of truth for limit checking in `should_auto_advance`.
   - Is incremented inside `_run_auto_advance_chain` before each advance.
   - Is preferred by `advance_milestone` for the banner count when present
     (falls back to state-file-based count + 1 when unset, preserving the
     standalone-call contract used by tests).

   `should_auto_advance` now skips the disposition check when the state file is
   absent — the only call site that hits this path is `_run_auto_advance_chain`,
   which already owns the advance decision. When the state file exists (the
   pre-finalize call site in `run_complete_loop`), the disposition check still
   runs.

   `_run_auto_advance_chain` re-creates the state file via `init_milestone_state`
   for the new milestone before invoking `advance_milestone`, so each advance
   begins with a fresh, valid state file just like a first run.

   Removed two `write_milestone_disposition "COMPLETE_AND_WAIT"` calls in the
   chain's break paths — they were no-ops after `finalize_run` deleted the state
   file (the function warned and returned 1).

Help text updated in both grouped and full `--help` outputs to document the new
`[N]` argument. CLI reference docs also updated.

## Root Cause (bugs only)

- **No CLI count:** the `--auto-advance` case in `tekhton.sh` did not peek at
  the next argument, so any integer following it was silently swallowed by the
  task-string parser.
- **Short-circuit advance:** `finalize_run`'s `_hook_clear_state` removes
  `MILESTONE_STATE_FILE` after `should_auto_advance` is called once. The cached
  `_should_advance=true` triggered `_run_auto_advance_chain`, but its `while`
  guard called `should_auto_advance` again — which read the (deleted) state file
  via `get_milestone_disposition` (returns `"NONE"`) and exited the loop on the
  very first iteration without ever advancing.

## Files Modified

- `tekhton.sh` — `--auto-advance` parser peeks at next arg for optional integer;
  `_AA_SESSION_ADVANCES=0` initialized and exported when `AUTO_ADVANCE=true`;
  help text in two `--help` blocks updated to `--auto-advance [N]`.
- `lib/milestone_ops.sh` — `should_auto_advance` reads `_AA_SESSION_ADVANCES`
  for limit and conditionally checks disposition (only when state file present).
- `lib/orchestrate_helpers.sh` — `_run_auto_advance_chain` increments
  `_AA_SESSION_ADVANCES`, calls `init_milestone_state` to recreate the state
  file before `advance_milestone`, and removes dead
  `write_milestone_disposition` calls in break paths.
- `lib/milestones.sh` — `advance_milestone` prefers `_AA_SESSION_ADVANCES` for
  the banner/state-file count; falls back to state-file count + 1 when unset.
- `tests/test_milestones.sh` — replaced the state-file-based limit test with
  in-memory counter tests (`_AA_SESSION_ADVANCES=0` returns true, `=3` returns
  false, state-file-absent returns true, limit still enforced when state file
  absent); added new test block exercising `advance_milestone`'s
  `_AA_SESSION_ADVANCES`-vs-fallback path.
- `tests/test_milestones_flag_smoke.sh` — added Test 6 (help text documents
  `[N]`) and Test 7 (`--auto-advance 5 --help` exits 0; `--auto-advance --help`
  also works without an integer).
- `docs/cli-reference.md` — updated row for `--auto-advance` to `--auto-advance [N]`.
- `docs/reference/commands.md` — updated row for `--auto-advance` to `--auto-advance [N]`
  with description of the `N` override.

## Docs Updated

- `docs/cli-reference.md` — added `[N]` argument to `--auto-advance` row.
- `docs/reference/commands.md` — added `[N]` argument and behavior note.

## Human Notes Status

No human notes were listed for this task.

## Verification

- `shellcheck -e SC1091` on the four modified shell files: no warnings introduced
  on lines I touched (pre-existing warnings on lines 1416, 1417, 1830, 1832, 1833,
  1889, 1967, 2353, 2420 are unrelated to this change).
- `bash tests/test_milestones.sh`: 75 passed, 0 failed.
- `bash tests/test_milestones_flag_smoke.sh`: 14 passed, 0 failed.
- `bash tests/run_tests.sh`: shell 374 passed, 0 failed; python 87 passed.
