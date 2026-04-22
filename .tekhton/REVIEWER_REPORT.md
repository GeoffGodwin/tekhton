# Reviewer Report — M117 Recent Events Substage Attribution

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/tui_helpers.sh:70–75` — The 4-field legacy detection uses the presence of `|` in `after_type` to distinguish 5-field from 4-field entries. If a pre-M117 entry had `|` in its message body, it would misparse as having a non-empty source. In practice this cannot occur (the ring buffer is in-memory, reset each run, and fully owned by `tui_append_event` which now always serialises 5-field), but the comment should note that legacy detection is defensive-only so future readers don't attempt to validate it with crafted old-format inputs.
- `lib/common.sh` is 445 lines (300-line soft ceiling). Pre-existing; M117 added ~24 lines. Deferred to a cleanup milestone.

## Coverage Gaps
- None

## Drift Observations
- None
