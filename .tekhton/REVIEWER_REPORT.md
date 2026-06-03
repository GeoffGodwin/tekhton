# Reviewer Report — m41

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
None

## Simple Blockers (jr coder)
None

## Non-Blocking Notes
- `stages/coder.sh` is 1202 lines, well above the 300-line bash ceiling. m41 added 2 net lines to pre-existing debt. Coder correctly flagged this; extraction is queued behind the coder-port milestone (m39.4).
- `milestone_window_build.sh` is 275 lines, close to the 300-line ceiling. Any future addition risks pushing it over; prefer further extraction if follow-on work touches this file.
- `milestone_window_build.sh::build_milestone_window` (~line 199): `num=$(dag_id_to_number "$id")` lacks a `|| true` guard. Under `set -euo pipefail`, a non-zero return from `dag_id_to_number` would abort `build_milestone_window` early and silently drop the milestone window. The variable is only used for cosmetic `warn` output. This is pre-existing code moved verbatim from `milestone_window.sh` — not a regression — but worth adding `|| num="$id"` in a cleanup pass.
- `_extract_first_paragraph_and_acceptance` (milestone_window_build.sh:112): the acceptance-start regex uses `^[[:space:]]*` as a leading anchor, so an indented line like `    Acceptance Criteria:` opens the block. Milestone files don't indent section headers in practice, but the permissiveness is worth noting.
- `tests/test_milestone_window_focused.sh` is 476 lines, above the 300-line ceiling. Consistent with the established project test-file convention (test_quota.sh 707, test_diagnose.sh 669, test_migration.sh 663) — no action needed.

## Coverage Gaps
- `_read_milestone_file`: no test covers the case where the DAG manifest has a non-empty `file` entry for an ID but that file is missing on disk — the DAG-known path is attempted, fails the `[[ -f "$path" ]]` check, then falls through to the glob fallback. The glob path is tested; the stale-manifest-entry path is not.
- `_extract_first_paragraph_and_acceptance`: the m41 tests cover `## Watch For` survival explicitly. A matching assertion for `## Seeds Forward` (the other exempted H2 pattern) is not called out in the test file summary. If the `m49.2-bold-label-fixture.md` fixture lacks a `## Seeds Forward` section, the exemption for that pattern is untested.

## Drift Observations
- `milestone_window_build.sh:263` — the WINDOW_HEADER heredoc uses a single-quoted delimiter (`<< 'WINDOW_HEADER'`), so `${CODER_SUMMARY_FILE}` on the last instruction line is a literal string in the rendered prompt rather than the resolved filename. Pre-existing behavior moved verbatim from `milestone_window.sh`; agents that read the instruction literally will look for a file named `${CODER_SUMMARY_FILE}`. Worth a follow-up fix (change delimiter to unquoted, or replace with the literal `CODER_SUMMARY.md`).
- `set -euo pipefail` appears at the top of both new sourced lib files (`milestone_window_build.sh:25`, `finalize_commit_sentinel.sh:16`), consistent with pre-existing convention in `milestone_window.sh:23` and `finalize_commit.sh:21` but inconsistent with the reviewer-checklist rule that sourced lib files should inherit rather than re-declare pipefail. ~20+ existing files carry this — drift pre-dates m41 and harmonisation is its own cleanup ticket.
