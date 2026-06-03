# Reviewer Report — m41

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
None

## Simple Blockers (jr coder)
None

## Non-Blocking Notes
- `stages/coder.sh` is 1202 lines, well above the 300-line bash ceiling. m41 added 2 net lines to pre-existing debt. Coder correctly flagged this; extraction is queued behind the coder-port milestone (m39.4).
- `lib/milestone_window_build.sh` sits at 276/300 lines after extraction. Any future addition to this file risks pushing it over the ceiling; prefer further extraction if that work is needed.
- `_extract_first_paragraph_and_acceptance` (milestone_window_build.sh:112): the acceptance-start regex uses `^[[:space:]]*` as a leading anchor, meaning an indented line like `    Acceptance Criteria:` would open the acceptance block. In practice milestone files don't indent section headers, but the permissiveness is worth noting.

## Coverage Gaps
- No test covers the path where the DAG manifest has a non-empty `file` entry for an ID but the file doesn't exist on disk — causing `_read_milestone_file` to skip the DAG-known path and fall through to the glob fallback. The glob path itself is tested; the DAG-path-present-but-stale case is not.

## Drift Observations
- `milestone_window_build.sh:263` — the WINDOW_HEADER heredoc uses single-quoted form (`<< 'WINDOW_HEADER'`), so `${CODER_SUMMARY_FILE}` inside it is a literal string rather than the resolved path. Pre-existing behavior moved verbatim from `milestone_window.sh`; worth a follow-up fix or comment if agents are confused by the unexpanded variable in the prompt.
- `set -euo pipefail` appears at the top of both new sourced lib files (`milestone_window_build.sh:25`, `finalize_commit_sentinel.sh:16`). Consistent with pre-existing project convention in `milestone_window.sh:23` and `finalize_commit.sh:21`, but inconsistent with the reviewer checklist rule that sourced lib files should not set pipefail. Pre-existing drift across ~20+ files — not introduced by m41; harmonisation is its own cleanup ticket.
