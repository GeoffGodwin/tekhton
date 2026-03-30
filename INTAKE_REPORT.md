## Verdict
TWEAKED

## Confidence
62

## Reasoning
- Core bug is well-understood: the Recent Runs section filters by run type (showing only `--milestone` runs) when it should show all run types, and the aggregation/count logic collapses multiple runs into one row
- Two distinct but related bugs are described together — both are in the same section and share a root cause (likely faulty query/aggregation), so keeping them in one milestone is appropriate
- No acceptance criteria are stated — the task describes the problem but not the expected post-fix behavior, which a developer would need to verify the fix is complete
- "Only ever shows the most recent run, with a count of 1" is slightly ambiguous: unclear whether "count" refers to a displayed row count, a numeric field in the table, or a pagination indicator — added a clarifying criterion
- [PM: Added acceptance criteria section] to make the fix verifiable

## Tweaked Content

[BUG] Watchtower Trends page: Recent Runs section does not show the latest two --human runs, it only shows the last --milestone run. This is critical for users to verify that their latest runs are being tracked and to see their most recent performance data. It also only ever shows the most recent run, with a count of 1 instead of all of them.

[PM: **Acceptance Criteria**]
[PM: - Recent Runs section displays runs of all invocation types (`--human`, `--milestone`, and any others), not filtered to a single type]
[PM: - Recent Runs section shows multiple distinct run rows — at minimum the last 5 runs, sorted by recency (most recent first)]
[PM: - Each run appears as a separate row; runs are not collapsed/aggregated into a single entry]
[PM: - After executing two `--human` runs followed by a `--milestone` run, the Recent Runs section shows all three runs, with the `--milestone` run at the top]
[PM: - Any count/total displayed in the section reflects the actual number of runs stored, not a hardcoded or incorrectly computed value]
[PM: - The Trends page loads without console errors after the fix]
