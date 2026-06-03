# Coder Summary

## Status: COMPLETE

## What Was Implemented

m41 — three-pronged fix for the false-positive commit block on the
sdivi-rust dogfood run (milestone `49.2`, dotted ID + bold-label
milestone file).

1. **Goal 1 — Dotted-id + bold-label resolution
   (`lib/milestone_window.sh`, `lib/milestone_window_build.sh` NEW).**
   - `_read_milestone_file` adds a `shopt -s nullglob` glob fallback
     under `MILESTONE_DIR` for `<id>-*.md` / `<id>.md` (and a zero-padded
     `m{id#m0}-*.md` variant for ids like `m05.2`). When the DAG row has
     no file (downstream projects whose manifest pre-dates dotted ids,
     or no manifest at all) the function now still finds the on-disk
     milestone file. The DAG-known file path is checked first so the
     manifest stays the source of truth when populated.
   - `_extract_first_paragraph_and_acceptance` (truncation-mode summary
     helper) widened to match `## Acceptance Criteria` (H2/H3) and
     `**Acceptance Criteria:**` (bold-label) markup, and the
     heading-end check now exempts `## Watch For` / `## Seeds Forward`
     H2 markers so those sections survive the truncation hop into
     `build_milestone_window`.
   - Split the file: `milestone_window.sh` was 370 lines, over the
     300-line ceiling. Multi-milestone build logic (`_compute_milestone_budget`,
     `_milestone_priority_list`, `_extract_first_paragraph_and_acceptance`,
     `_extract_title_line`, `build_milestone_window`, header constant)
     moved to a new sibling `lib/milestone_window_build.sh` sourced from
     `milestone_window.sh`. Public callable surface (`set_focused_milestone_block`,
     `_read_milestone_file`, `build_milestone_window`) unchanged.

2. **Goal 2 — Block-unavailable is an input warning, not a result check
   (`stages/coder.sh:240-260`).**
   - Removed the `trip_commit_gate "milestone_block_unavailable_<id>"`
     call inside the `set_focused_milestone_block` failure branch.
   - Replaced the second warn line ("...likely produce nothing") with
     "...downstream hollow-run gates remain in effect" — the genuine
     hollow-run gates (`coder_did_not_produce_summary` at coder.sh:803,
     `completion_gate_failed_substantive_work_only` at coder.sh:1154,
     `reviewer_did_not_produce_report`, `tester_did_not_produce_report`)
     keep their teeth. The fix narrows ONE false-positive trip; it does
     not weaken the hollow-run protections.
   - Updated the surrounding comment block to reflect the m41 semantic:
     block population is an INPUT safeguard, not a RESULT check.

3. **Goal 3 — Honest, single-line block diagnostic
   (`lib/finalize_commit.sh`, `lib/finalize_commit_sentinel.sh` NEW).**
   - New `_final_check_reason_read` helper reads line 2 of
     `.final_check_result` (the `# <reason>` comment line written by
     `trip_commit_gate`), strips the `#`/`# ` marker, trims whitespace,
     and returns the reason. Empty when the sentinel is absent or has
     no reason line.
   - `_hook_commit` now prints `"Commit blocked: <reason> (see
     .tekhton/.final_check_result)"` when a reason is recorded, or
     `"Commit blocked: final checks failed (see ...)"` as a generic
     fallback. The legacy `"FINAL_CHECK_RESULT=0, persisted=1"`
     contradiction migrated to `log_verbose` for postmortem.
   - Extracted both sentinel readers (`_final_check_result_read` +
     `_final_check_reason_read`) into a new
     `lib/finalize_commit_sentinel.sh` (sourced by `finalize_commit.sh`)
     to bring `finalize_commit.sh` back under the 300-line ceiling after
     the m41 additions (was 300 → would have been 337 → now 287 via the
     extract + comment trim).

4. **Tests** — extended `tests/test_milestone_window_focused.sh` with 9
   new m41 assertions (dotted id `49.2` resolves via glob, bold-label
   sections appear verbatim in the focused block, the truncation-mode
   extractor matches both H2 and bold-label markup, Watch For / Seeds
   Forward H2 sections survive the truncation hop). Authored
   `tests/test_finalize_commit_block_reason.sh` (NEW) covering the
   reason reader (4 cases: absent / `# ` marker / `#` no-space / padded
   whitespace), the `_hook_commit` reason surfacing (4 sub-assertions:
   blocked, reason printed, legacy contradiction gone, sentinel path
   shown), the generic fallback when no reason recorded (3 cases), and
   the in-memory `FINAL_CHECK_RESULT` path. All 12 new + 34 m41-updated
   tests PASS. `tests/test_final_checks_commit_gate.sh` (existing) still
   passes — the 27 pre-existing assertions are intact.

5. **Docs** — `ARCHITECTURE.md` updated to describe the new
   `lib/milestone_window.sh` and `lib/milestone_window_build.sh` split
   and the m41 glob-fallback + markup-widening semantics. `CLAUDE.md`
   repository tree updated with `lib/milestone_window_build.sh` and
   `lib/finalize_commit_sentinel.sh` entries.

## Root Cause (bugs only)

The sdivi-rust dogfood run committed a successful milestone but was
hard-blocked at finalize. Two compounding defects:

a) **`set_focused_milestone_block` could not find the milestone file**
   for the dotted id `49.2`. The DAG-only file lookup (`dag_get_file`)
   returned empty because the downstream project's MANIFEST.cfg either
   did not have a row for `m49.2` or `_DAG_FILES[m49.2]` was unset, and
   the function had no on-disk fallback. The empty content caused the
   function to return non-zero.

b) **`stages/coder.sh:251-259` treated that non-zero return as a
   commit-blocking failure** by calling
   `trip_commit_gate "milestone_block_unavailable_${_CURRENT_MILESTONE}"`.
   The agent ran with the generic milestone-mode prompt (no per-id
   detail) and DID produce a valid `CODER_SUMMARY.md`; downstream stages
   (security, review, tester) all passed. But the sentinel left at the
   start by coder.sh blocked `_hook_commit` regardless.

c) **The operator-facing diagnostic was contradictory.** `_hook_commit`
   printed `"Commit blocked: final checks failed (FINAL_CHECK_RESULT=0,
   persisted=1)"`. Inline result said pass; persisted sentinel said fail;
   the recorded reason (`# milestone_block_unavailable_49.2` on line 2)
   was never surfaced.

The fix decouples the three: (a) resolves dotted ids via disk glob, (b)
makes block-unavailable warn-and-continue (the existing hollow-run gates
remain the real guard), (c) reads and prints the sentinel's recorded
reason.

## Files Modified

- `lib/milestone_window.sh` (modified — m41 dotted-id glob fallback +
  split-out helpers; net 153 LOC vs prior 370 LOC)
- `lib/milestone_window_build.sh` (NEW — extracted m41 budget+priority+
  build helpers + widened `_extract_first_paragraph_and_acceptance`
  for H2/bold-label markup; 275 LOC)
- `lib/finalize_commit.sh` (modified — m41 reason-surfacing in
  `_hook_commit`; sentinel readers extracted; comment trim; 287 LOC vs
  prior 300 LOC)
- `lib/finalize_commit_sentinel.sh` (NEW — m41 `_final_check_result_read`
  + `_final_check_reason_read`; 53 LOC)
- `stages/coder.sh` (modified — m41 removed the
  `milestone_block_unavailable` `trip_commit_gate`; kept the warn; the
  comment block above the call updated to reflect the new semantic)
- `tests/test_milestone_window_focused.sh` (modified — 9 new m41
  assertions: dotted-id glob, bold-label inclusion, H2 + bold-label
  extractor coverage, Watch For / Seeds Forward survival)
- `tests/test_finalize_commit_block_reason.sh` (NEW — 12 assertions
  across `_final_check_reason_read` and `_hook_commit` reason surfacing;
  chmod +x; 172 LOC)
- `ARCHITECTURE.md` (modified — `lib/milestone_window.sh` /
  `lib/milestone_window_build.sh` entries updated)
- `CLAUDE.md` (modified — repository tree: added
  `lib/finalize_commit_sentinel.sh` and `lib/milestone_window_build.sh`
  entries)

## Docs Updated

- `ARCHITECTURE.md` — milestone_window.sh / milestone_window_build.sh
  entries replaced to describe the m41 split + glob-fallback +
  markup-widening behavior.
- `CLAUDE.md` — repository layout tree picks up the two new
  helper files.

## Human Notes Status

N/A. The CLARIFICATIONS.md block in the prompt contains entries from
prior unrelated runs (Watchtower dashboard, NON_BLOCKING_LOG,
init/plan circular flow, HUMAN_NOTES inconsistency) where the answers
echo the question text back. None of those apply to this milestone's
scope.

## Acceptance Criteria

All acceptance criteria from the milestone are met:

- A milestone with a dotted id and bold-label sections populates
  `MILESTONE_BLOCK` (resolver returns 0) — verified by
  `tests/test_milestone_window_focused.sh` "[m41] returns 0 for dotted
  id 49.2 (file on disk, no manifest row)" and "[m41] MILESTONE_BLOCK
  carries the file body". PASS.
- A run where the coder produces a valid summary and all stages pass
  commits, even if `set_focused_milestone_block` had failed — verified
  by code inspection of `stages/coder.sh:240-260`: the
  `trip_commit_gate` is gone; only the warn remains. The genuine
  hollow-run gates (`coder_did_not_produce_summary`,
  `completion_gate_failed_substantive_work_only`,
  `reviewer_did_not_produce_report`, `tester_did_not_produce_report`)
  remain in their pre-m41 form and trip on real hollow runs.
- A genuinely hollow run (no `CODER_SUMMARY`) still blocks via the
  existing summary/completion gates — verified by code inspection that
  those gates are untouched by m41.
- The blocked-commit message names the actual reason; no
  `FINAL_CHECK_RESULT=0, persisted=1` contradiction in operator
  output — verified by
  `tests/test_finalize_commit_block_reason.sh` cases 5.2 ("blocked
  warning names the actual reason"), 5.3 ("legacy 'FINAL_CHECK_RESULT=0,
  persisted=1' contradiction is gone from operator output"), 5.4
  ("blocked warning points the operator to the sentinel file"), and 7.1
  ("in-memory FAIL path also prints recorded reason"). PASS.
- Existing `tests/test_milestone_window_focused.sh` cases still pass —
  verified: all 25 pre-existing assertions PASS alongside the 9 new
  m41 assertions (34 total PASS, 0 FAIL).
- Existing `tests/test_final_checks_commit_gate.sh` continues to pass —
  verified: 27 assertions PASS, 0 FAIL.
- Full test suite (`bash tests/run_tests.sh`) passes — verified: 503
  shell tests PASS, 0 FAIL; all Go tests PASS.

## Architecture Change Proposals

None — m41 is a bug fix narrowing the surface of one false-positive
trip. The Goal 1 split (`milestone_window_build.sh`) and Goal 3
extraction (`finalize_commit_sentinel.sh`) keep both files under the
300-line ceiling per CLAUDE.md Rule 8. Public callable surfaces are
unchanged. Sourcing is chained through the public files
(`milestone_window.sh` sources `milestone_window_build.sh`,
`finalize_commit.sh` sources `finalize_commit_sentinel.sh`), so no
caller needs to update its source list. `internal/stagerunner/helpers.go`
already lists `lib/milestone_window.sh`; the chained source is
transitive.

## Design Observations

The milestone description mentions a "500-char section cap" the work
"keep[s]". The 500-char number actually refers to the
`MILESTONE_WINDOW_MAX_CHARS=500` tight-budget scenario in
`tests/test_milestone_window.sh`, not a per-section cap that lives in
code. The actual behavior preserved is `set_focused_milestone_block`
returning the FULL file body regardless of any window budget — the test
at `test_milestone_window_focused.sh:218-231` asserts this with
`MILESTONE_WINDOW_MAX_CHARS=200` and the m41 work keeps it green.

The milestone says the `**Watch For:**` bold-label form is downstream
project style. In the upstream Tekhton manifest the m41 milestone file
itself uses bold-label form for "Watch For" and "Seeds Forward", and the
test fixture `m49.2-bold-label-fixture.md` mirrors that. Both
authoring styles work for `set_focused_milestone_block` because it
dumps full content verbatim; the markup-widening is necessary for the
TRUNCATION-mode extractor `_extract_first_paragraph_and_acceptance` so
those sections survive the build_milestone_window truncation hop.

## Observed Issues (out of scope)

- `stages/coder.sh` is 1202 lines, well above the 300-line ceiling
  (CLAUDE.md Rule 8). m41 made a 6-line edit in a 70-line region and
  did not refactor the surrounding file — splitting `stages/coder.sh`
  is its own milestone-scale piece of work. Net m41 change to the file
  is +2 lines (added 5, removed 3). Already noted as long-running tech
  debt by the existing `stages/coder_prerun.sh`,
  `stages/coder_buildfix.sh`, `stages/coder_buildfix_helpers.sh`
  split — further extraction is queued behind m39.4 (the coder stage
  port milestone visible in `git log`).
- `tests/test_milestone_window_focused.sh` is now 476 lines (added 144
  for the m41 cases). Test files in this codebase routinely exceed 300
  lines (test_quota.sh 707, test_diagnose.sh 669, test_migration.sh
  663, …) so the file-length rule is treated as a `lib/`-and-`stages/`
  rule by convention. Left as-is for consistency with the project's
  test-file conventions.

## Remaining Work

None.
