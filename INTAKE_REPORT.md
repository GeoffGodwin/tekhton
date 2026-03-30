## Verdict
TWEAKED

## Confidence
58

## Reasoning
- The bug description clearly identifies the problem symptoms (wrong run type filtered, count stuck at 1)
- However, there are **no acceptance criteria** — a developer cannot know when the fix is complete without them
- The expected behavior is partially implicit: "show all recent runs including --human runs" but the desired count/limit is unspecified
- Two distinct bugs are bundled (run type filter + count aggregation) — both are clearly related to the same data source/query, so splitting is not warranted
- No UI testability criterion is present

## Tweaked Content

**[BUG] Watchtower Trends page: Recent Runs section does not show the latest two --human runs, it only shows the last --milestone run.**

The Recent Runs section on the Trends page has two defects:
1. **Run type filter bug**: Only `--milestone` runs appear; `--human` runs (and any other run modes) are excluded.
2. **Count/aggregation bug**: Only the single most recent run is shown with a count of 1, instead of displaying all recent runs up to the display limit.

This is critical for users to verify that their latest runs are being tracked and to see their most recent performance data.

### Acceptance Criteria

- Recent Runs section displays runs from all invocation modes (`--human`, `--milestone`, and any other modes) without filtering by type
- Recent Runs section shows the last N runs (N = existing display limit, or 10 if no limit was previously defined) [PM: limit is unspecified in the bug; use existing limit or default to 10]
- Each entry in the list represents a distinct run, not an aggregated count
- After two consecutive `--human` runs, both appear in the Recent Runs list
- After a `--milestone` run followed by a `--human` run, both appear (not just the milestone run)
- [PM: UI criterion added] The Recent Runs section renders without console errors after a page load when run history contains mixed run types

### Watch For
- [PM: added] The data query or aggregation feeding Recent Runs may be grouping by task/mode instead of by run timestamp — check whether a `GROUP BY` or deduplication step is incorrectly collapsing rows
- [PM: added] Separate from the Trends Average Stage Times bug (noted in Human Notes) — do not conflate the two data paths; they may share the same broken query or be independent

## Questions
- What is the intended maximum number of runs to display in Recent Runs? (Used "10" as default above — confirm or override.)
