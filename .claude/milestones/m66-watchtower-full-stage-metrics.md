# Milestone 66: Watchtower Full-Stage Metrics & Hierarchical Breakdown
<!-- milestone-meta
id: "66"
status: "pending"
-->

## Overview

Watchtower's Per-Stage Breakdown on the Trends screen only tracks 4 stages from
metrics.jsonl (Scout, Coder, Reviewer, Tester) even though the pipeline can
execute 10+ distinct timed steps per run. Security scans, Test Audit, Analyze
Cleanup, specialists, and rework cycles are all invisible — in a recent run,
these "invisible" steps accounted for 28% of total wall-clock time (11m40s of
40m51s).

Meanwhile, the Run Summary banner printed at the end of each run *does* show
every step — it already has the data. The problem is that this data never flows
into metrics.jsonl or the Watchtower frontend.

This milestone closes the gap with two changes:
1. **Backend:** Record all stage/step durations and turn counts in metrics.jsonl
2. **Frontend:** Render a hierarchical Per-Stage Breakdown that groups sub-steps
   under parent stages, with collapsed-by-default drill-down

The default view remains clean and scannable. Expanding a row reveals the
sub-steps that composed it (review cycles, rework iterations, test audit, etc.).

Depends on M57 (last completed milestone) for stable pipeline baseline.

## Scope

### 1. Expand metrics.jsonl Stage Recording

**File:** `lib/metrics.sh`

Add recording for all pipeline steps that currently have `_STAGE_DURATION` /
`_STAGE_TURNS` data but are not written to metrics.jsonl:

| Field | Source | Currently Recorded |
|-------|--------|--------------------|
| `security_turns` / `security_duration_s` | `_STAGE_DURATION[security]` | No |
| `security_rework_cycles` | `SECURITY_REWORK_CYCLES_DONE` | No |
| `test_audit_turns` / `test_audit_duration_s` | `_STAGE_DURATION[test_audit]` | No |
| `cleanup_turns` / `cleanup_duration_s` | `_STAGE_DURATION[cleanup]` | No |
| `analyze_cleanup_turns` / `analyze_cleanup_duration_s` | Captured in hooks.sh | No |
| `review_cycles` | `REVIEW_CYCLE` | Partial (in RUN_SUMMARY.json, not metrics.jsonl) |
| `specialist_security_turns` / `_duration_s` | `_STAGE_DURATION[specialist_security]` | No |
| `specialist_performance_turns` / `_duration_s` | `_STAGE_DURATION[specialist_perf]` | No |
| `specialist_api_turns` / `_duration_s` | `_STAGE_DURATION[specialist_api]` | No |

Steps that don't run in a given pipeline invocation emit nothing (sparse keys).
This is already how the existing 4 stages work — no change to the JSONL schema
contract, just additional optional fields.

### 2. Track Sub-Step Durations in _STAGE_DURATION

**Files:** `stages/security.sh`, `stages/review.sh`, `stages/tester.sh`,
`lib/hooks.sh`, `lib/specialists.sh`

Ensure every agent invocation that contributes to a parent stage records its
duration in `_STAGE_DURATION` with a namespaced key:

- `security` (parent) → `security_scan`, `security_rework_1`, `security_rework_2`
- `reviewer` (parent) → `reviewer_cycle_1`, `reviewer_cycle_2`, `reviewer_cycle_3`
- `tester` (parent) → `tester_write`, `tester_audit`
- `post_pipeline` (parent) → `cleanup`, `analyze_cleanup`

Parent stage duration remains the wall-clock total. Sub-steps are recorded
separately so the frontend can show the breakdown.

### 3. Update metrics.jsonl Parser (Backend)

**File:** `lib/dashboard_parsers_runs.sh`

Expand both the Python and bash parsers to extract the new stage fields:

```python
# Extended stage extraction
for sname, skey in [
    ('coder','coder_turns'), ('reviewer','reviewer_turns'),
    ('tester','tester_turns'), ('scout','scout_turns'),
    ('security','security_turns'), ('test_audit','test_audit_turns'),
    ('cleanup','cleanup_turns'), ('analyze_cleanup','analyze_cleanup_turns'),
]:
    ...
```

Add sub-step data as nested objects within the parent stage:

```json
{
  "stages": {
    "reviewer": {
      "turns": 42, "duration_s": 720, "budget": 28,
      "cycles": 2,
      "sub_steps": [
        {"label": "Review (cycle 1)", "turns": 14, "duration_s": 90},
        {"label": "Rework + Re-review", "turns": 28, "duration_s": 630}
      ]
    },
    "tester": {
      "turns": 26, "duration_s": 984, "budget": 40,
      "sub_steps": [
        {"label": "Test Writing", "turns": 1, "duration_s": 782},
        {"label": "Test Audit", "turns": 25, "duration_s": 204}
      ]
    },
    "post_pipeline": {
      "turns": 1, "duration_s": 436,
      "sub_steps": [
        {"label": "Analyze Cleanup", "turns": 1, "duration_s": 436}
      ]
    }
  }
}
```

### 4. Frontend: Hierarchical Stage Grouping

**File:** `templates/watchtower/app.js`

Update `stageOrder`, `stageLabels`, and `renderStageBreakdown()`:

**Stage hierarchy:**

```javascript
var stageGroups = {
  'scout':    { label: 'Scout',    children: [] },
  'coder':    { label: 'Coder',    children: ['build_gate'] },
  'security': { label: 'Security', children: ['security_rework'] },
  'reviewer': { label: 'Review',   children: [] },  // cycles shown via (×N) indicator
  'tester':   { label: 'Test',     children: ['test_audit'] },
  'post_pipeline': { label: 'Post-Pipeline', children: ['cleanup', 'analyze_cleanup'] }
};
```

**Default (collapsed) view:**

```
Stage            | Avg Turns | Last Run     | Avg Time | Distribution
Scout            | 9         | 9/20 (45%)   | 0m 48s   | [==]
Coder            | 52        | 52/40 (130%) | 13m 51s  | [=============]
Security         | 9         | 9/15 (60%)   | 1m 00s   | [==]
Review (×1)      | 14        | 14/28 (50%)  | 1m 30s   | [===]
Test             | 26        | 26/40 (65%)  | 16m 26s  | [================]
Post-Pipeline    | 1         | -            | 7m 16s   | [=======]
```

- Parent rows show **aggregated** turns and duration (sum of sub-steps)
- Review shows cycle count as `(×N)` suffix when cycles > 1
- Post-Pipeline only appears when cleanup or analyze ran
- Expandable indicator (▸/▾) on rows with sub-steps

**Expanded view (user clicks row):**

```
▾ Test           | 26        | 26/40 (65%)  | 16m 26s  | [================]
  └ Test Writing | 1         | 1/40         | 13m 02s  | [=============]
  └ Test Audit   | 25        | 25/15 (167%) | 3m 24s   | [===]
```

Sub-step rows use indented styling with `└` prefix, lighter text color, and
narrower bars. Sub-step bars scale relative to the parent, not the global max.

### 5. Frontend: Cycle Indicators

**File:** `templates/watchtower/app.js`

When `review_cycles > 1` or `security_rework_cycles > 0`, show the cycle count
as a badge next to the stage label:

```html
<td>Review <span class="cycle-badge">×2</span></td>
```

CSS: `.cycle-badge` uses subtle background color (amber for 2 cycles, red for 3+).

### 6. Frontend: Expand/Collapse Interaction

**File:** `templates/watchtower/app.js`, `templates/watchtower/style.css`

- Parent rows with sub-steps get `cursor: pointer` and `▸` indicator
- Click toggles visibility of child `<tr>` elements
- State persists via `localStorage` key `tk_expanded_stages`
- Default: all collapsed
- Keyboard accessible: Enter/Space toggles expansion

### 7. Backward Compatibility

**File:** `lib/dashboard_parsers_runs.sh`

Historical metrics.jsonl records won't have the new fields. The parser must:
- Handle missing fields gracefully (default to 0 / empty sub_steps)
- Continue to produce valid output for old records
- The frontend shows "no data" for sub-steps on historical runs

## Migration Impact

No new config keys. All changes are additive to existing data formats:
- metrics.jsonl gains optional new fields (sparse — absent when stage didn't run)
- Frontend adds expandable rows (collapsed by default — identical visual for
  users who don't interact)
- No breaking changes to existing Watchtower features

## Acceptance Criteria

- metrics.jsonl records security, test_audit, cleanup, analyze_cleanup, and
  specialist turns + durations when those stages run
- metrics.jsonl records review_cycles and security_rework_cycles counts
- Watchtower Per-Stage Breakdown shows all active stages (not just 4)
- Collapsed view groups sub-steps under parent stages
- Expanded view shows sub-step breakdown with correct turn/time attribution
- Review cycle count shown as badge when > 1
- Post-Pipeline group only appears when cleanup or analyze ran
- Sub-step turns and durations sum to parent totals (accounting for overlap)
- Historical runs without new fields display gracefully (no errors, no data)
- Expand/collapse state persists across page refreshes
- All existing Watchtower tests pass
- New tests for expanded metrics parsing and hierarchical rendering

Tests:
- Parser extracts security/test_audit/cleanup from metrics.jsonl
- Parser handles missing fields in historical records (no crash, sane defaults)
- Frontend renders hierarchical view with correct grouping
- Expand/collapse toggles child row visibility
- Cycle badge appears when review_cycles > 1
- Post-Pipeline group hidden when no cleanup stages ran
- Sub-step duration sum matches parent duration
- Bash fallback parser extracts new fields (mirrors Python parser)
- Distribution bars scale correctly with sub-steps (parent vs global max)

Watch For:
- **Sub-step timing overlap:** Some sub-steps run sequentially within a parent
  stage, so their durations should sum to approximately the parent duration.
  However, if there's overhead between sub-steps (state persistence, context
  assembly), the sub-step sum may be less than the parent. Show both — don't
  try to force them to match.
- **Specialist stages are rare:** Most runs don't enable specialists. The
  frontend should handle 0-specialist runs gracefully (no empty group).
  Consider grouping specialists under a "Specialist Reviews" parent only when
  at least one ran.
- **JSONL backward compatibility:** The bash sed-based parser in the fallback
  path is fragile with many fields. Consider whether the new fields justify
  making Python a soft requirement for dashboard parsing (with bash as a
  degraded-but-functional fallback that only extracts the original 4 stages).
- **Mobile rendering:** The expanded sub-step rows need to work on narrow
  screens. Use responsive hiding of the Distribution column (already done in
  existing CSS) and ensure sub-step labels don't wrap awkwardly.
- **Post-Pipeline naming:** "Post-Pipeline" is a functional label. Consider
  whether "Finalization" or "Cleanup" is clearer for users who haven't read
  the pipeline internals.

Seeds Forward:
- Full-stage metrics enable M62 (Tester Timing Instrumentation) sub-phase data
  to flow directly into the hierarchical view
- Cycle count data supports future "churn detection" — alerting when review
  cycles trend upward across runs
- Specialist timing data enables cost/benefit analysis of specialist reviews
