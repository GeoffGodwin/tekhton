## Status: COMPLETE

## Summary
Senior coder rework cycle for M96 (CLI Output Hygiene). The reviewer's three
remaining Complex Blockers are now resolved:

1. **IA2 — Version bump in Pipeline Complete banner.** `bump_version_files`
   now exports `_BUMPED_VERSION_OLD`, `_BUMPED_VERSION_NEW`, and
   `_BUMPED_VERSION_TYPE` after a successful bump. `_hook_commit` reads them
   and emits a `Version: <old> → <new> (<type>)` line directly under the
   Milestone line in the banner. No display when no bump occurred.
2. **IA3 — `What's next:` promoted to final printed line.** Removed the
   `_compute_next_action` block from `_print_action_items` and added a small
   helper `_print_next_action` in `lib/finalize_display.sh`. `_hook_commit`
   invokes it after each terminal `print_run_summary` + commit-confirmation
   path (commit, edit-then-commit, and skip).
3. **Coverage gap closed.** `tests/test_cli_output_hygiene.sh` now exists.
   Two assertions: (a) runtime smoke — sourcing causality.sh and calling
   `emit_event >/dev/null` produces no event ID on stdout; (b) static —
   every `emit_event` call site in `lib/` and `stages/` either captures via
   command substitution or redirects stdout (a bare `2>/dev/null` is rejected,
   confirmed by manual regression-injection).

## Files Modified
- `lib/finalize.sh` — Added Version line in banner; added `_print_next_action`
  call after each commit/skip case.
- `lib/finalize_display.sh` — Removed the inline next-action block from
  `_print_action_items`; added `_print_next_action` helper.
- `lib/project_version_bump.sh` — Export `_BUMPED_VERSION_*` after bump so
  the banner can read them.

## New Files Created
- `tests/test_cli_output_hygiene.sh` — Hygiene contract test (M96 AC-1).

## Tests Run
- `tests/test_cli_output_hygiene.sh` — 2/2 PASS
- `tests/test_finalize_run.sh` — 106/106 PASS
- `tests/test_next_action_computation.sh` — 8/8 PASS
- `tests/test_project_version_bump.sh` — 22/22 PASS
- `shellcheck lib/finalize.sh lib/finalize_display.sh lib/project_version_bump.sh tests/test_cli_output_hygiene.sh` — clean

## Remaining Work
None for this rework. Reviewer's non-blocking notes (NR2 archival under-emission,
IA4/IA5 deferral) are out of scope for this cycle per the report.
