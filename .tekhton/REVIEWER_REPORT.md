# Reviewer Report — m41

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `stages/coder.sh` is 1202 lines, well above the 300-line bash ceiling. m41 added 2 net lines to pre-existing debt. Coder correctly flagged this; extraction is queued behind the coder-port milestone (m39.4).
- `set -euo pipefail` appears at the top of both new sourced lib files (`milestone_window_build.sh:25`, `finalize_commit_sentinel.sh:16`). This is consistent with the pre-existing project convention (`milestone_window.sh:23`, `finalize_commit.sh:21`) but inconsistent with the reviewer checklist. Pre-existing drift — not introduced by m41; harmonisation would require touching ~20+ files and is its own cleanup ticket.

## Coverage Gaps
- None

## Drift Observations
- `milestone_window_build.sh:263` — the WINDOW_HEADER heredoc uses a single-quoted form (`<< 'WINDOW_HEADER'`), so `${CODER_SUMMARY_FILE}` is a literal string in the coder prompt rather than the resolved path. Pre-existing behavior moved verbatim from `milestone_window.sh`; the coder notes it in Design Observations. Worth a follow-up comment or fix if it causes agent confusion in practice.
