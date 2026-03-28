# Milestone 37: Watchtower V4 Parallel Teams Readiness

## Overview

Tekhton V4 will introduce parallel work teams — multiple agent pipelines executing
independent milestones concurrently. Watchtower must evolve from tracking a single
linear pipeline to visualizing multiple concurrent execution streams. This milestone
builds the data model, UI components, and display infrastructure for parallel team
monitoring, even before V4's execution engine exists.

## Motivation

The existing Watchtower was designed for a single serial pipeline:
- **Live Run** shows one timeline, one stage progress bar, one active milestone
- **Milestone Map** shows lanes by status (done/active/ready/pending) but doesn't
  visualize parallel execution groups
- **Reports** shows one set of stage reports
- **Trends** aggregates all runs into one flat list

V4 parallel execution will run 2-4 independent pipelines simultaneously (one per
`parallel_group` in MANIFEST.cfg). Each team has its own coder, reviewer, and
tester operating on a different milestone. Watchtower needs to show all teams at
once without losing the ability to drill into individual team details.

## Scope

### 1. Team-Aware Run State

Extend `emit_dashboard_run_state()` to emit per-team state when parallel execution
is active.

**New data structure in `run_state.js`:**
```javascript
window.TK_RUN_STATE = {
  pipeline_status: "running",
  parallel_mode: true,       // NEW: true when multiple teams active
  teams: {                   // NEW: per-team state
    "team_quality": {
      milestone: { id: "m20", title: "Test Integrity Audit" },
      current_stage: "coder",
      stages: { intake: {...}, scout: {...}, coder: {...}, ... },
      status: "running",
      started_at: "2025-01-15T10:00:00Z"
    },
    "team_brownfield": {
      milestone: { id: "m15", title: "Project Health Scoring" },
      current_stage: "reviewer",
      stages: { ... },
      status: "running",
      started_at: "2025-01-15T10:00:00Z"
    }
  },
  // Existing fields for backward compat (reflect "lead" team or aggregate)
  current_stage: "coder",
  active_milestone: { id: "m20", title: "Test Integrity Audit" },
  stages: { ... }
};
```

When `parallel_mode` is false (current behavior), `teams` is empty/absent and
existing single-pipeline fields are used. UI auto-detects which mode to render.

**Files:** `lib/dashboard.sh`, `lib/dashboard_emitters.sh`

### 2. Multi-Team Live Run View

When `parallel_mode` is true, the Live Run tab switches from single-pipeline view
to a multi-team layout.

**Layout:**
```
┌─────────────────────────────────────────────┐
│ Pipeline RUNNING — 3 teams active           │
├──────────────┬──────────────┬───────────────┤
│ Team Quality │ Team Brown   │ Team DevX     │
│ ● m20: Test  │ ✓ m15: Hea  │ ● m22: Init   │
│ [I][S][C]... │ [I][S][C]... │ [I][S][C]...  │
│ Coder: 12/50 │ Review: 5/15 │ Scout: 3/15   │
├──────────────┴──────────────┴───────────────┤
│ Unified Timeline (color-coded by team)      │
│ 10:05 [quality] stage_start: coder          │
│ 10:04 [brownfield] verdict: approved        │
│ 10:03 [devx] stage_start: scout             │
└─────────────────────────────────────────────┘
```

Each team card shows:
- Team name (derived from parallel_group or auto-generated)
- Active milestone ID and title
- Compact stage progress chips (same as current, but smaller)
- Current stage detail (turns/budget, duration)
- Status badge (running/waiting/complete/failed)

Below the team cards: unified timeline with team-colored event markers.
Click a team card to filter the timeline to that team's events only.

**Single-team mode:** When only one team is active (or `parallel_mode` is false),
render the existing single-pipeline view unchanged.

**Files:** `templates/watchtower/app.js`, `templates/watchtower/style.css`

### 3. Enhanced Milestone Map with Parallel Groups

The Milestone Map currently uses swimlanes by status (Done/Active/Ready/Pending).
Enhance it to optionally view by parallel group, showing which milestones can
execute concurrently.

**New view toggle:** "View by: Status | Parallel Group" buttons above the swimlanes.

**Parallel Group view:**
```
┌─────────────────────────────────────────────┐
│ View by: [Status] [Parallel Group]          │
├──────────────┬──────────────┬───────────────┤
│ quality      │ brownfield   │ devx          │
│ ┌──────────┐ │ ┌──────────┐ │ ┌──────────┐  │
│ │ m09 ✓    │ │ │ m11 ✓    │ │ │ m18 ✓    │  │
│ │ m10 ✓    │ │ │ m12 ✓    │ │ │ m19 ✓    │  │
│ │ m20 ●    │ │ │ m15 ●    │ │ │ m22 ●    │  │
│ └──────────┘ │ └──────────┘ │ └──────────┘  │
│              │              │               │
│ Cross-group dependency arrows (CSS lines)   │
└─────────────────────────────────────────────┘
```

Dependency arrows between groups show cross-group constraints. Within a group,
milestones are ordered by dependency chain (topological sort).

**Files:** `templates/watchtower/app.js`, `templates/watchtower/style.css`

### 4. Per-Team Reports

When parallel teams are active, the Reports tab needs to scope reports to a
selected team. Add a team selector dropdown/tabs at the top of the Reports tab.

Each team has its own set of reports (intake, coder, security, reviewer) because
each runs its own pipeline stages independently.

**Data model extension:**
```javascript
window.TK_REPORTS = {
  // Existing fields (for single-pipeline compat)
  intake: { verdict: "pass", confidence: 85 },
  coder: { ... },
  // New: per-team reports
  teams: {
    "team_quality": {
      intake: { ... },
      coder: { ... },
      security: { ... },
      reviewer: { ... }
    },
    "team_brownfield": { ... }
  }
};
```

**Files:** `lib/dashboard_emitters.sh`, `templates/watchtower/app.js`

### 5. Team-Aware Trends

Extend Trends to break down metrics by team in addition to by stage.

**New section:** "Per-Team Performance" table showing:
- Team name
- Total runs
- Avg turns per milestone
- Avg duration per milestone
- Success rate
- Distribution bar chart

**Filter integration:** Existing run type filters (from M35) gain a team filter:
"All Teams | Quality | Brownfield | DevX"

**Files:** `templates/watchtower/app.js`

### 6. Data Layer Preparation

The parallel team data model must be defined now so M34-M36 can build on it,
even though V4's execution engine doesn't exist yet.

**New fields in RUN_SUMMARY.json:**
```json
{
  "team": "quality",
  "parallel_group": "quality",
  "concurrent_teams": 3
}
```

**New emitter hook:** `emit_dashboard_team_state(team_id)` — called per team in
parallel mode. Writes team-specific state into the `teams` object of `run_state.js`.

**Backward compat:** When `parallel_mode` is absent or false, all existing views
render identically to pre-M37 behavior. No feature flags needed — auto-detect
from data shape.

**Files:** `lib/dashboard.sh`, `lib/dashboard_emitters.sh`,
`lib/finalize_summary.sh`

## Acceptance Criteria

- `TK_RUN_STATE` supports `parallel_mode` and `teams` fields
- Live Run tab renders multi-team card layout when `parallel_mode` is true
- Live Run tab renders existing single-pipeline view when `parallel_mode` is false
- Timeline events are color-coded by team with click-to-filter
- Milestone Map supports "View by Parallel Group" toggle
- Cross-group dependency arrows render correctly
- Reports tab shows team selector when multiple teams have reports
- Trends tab shows per-team performance breakdown
- RUN_SUMMARY.json includes `team` and `parallel_group` fields
- All views degrade gracefully to single-pipeline display for pre-M37 data
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n` passes for any modified `.sh` files
- `shellcheck` passes for any modified `.sh` files

## Watch For

- **Team naming:** Parallel groups in MANIFEST.cfg are optional and may be empty.
  When no group is assigned, milestones default to a "default" team. The UI must
  handle mixed grouped/ungrouped milestones.
- **Team count explosion:** V4 will likely cap at 4 concurrent teams. The UI layout
  should work for 1-6 teams but optimize for 2-4. Beyond 4, use a scrollable
  horizontal layout instead of fixed columns.
- **Timeline interleaving:** Events from different teams arrive in temporal order,
  not grouped by team. The unified timeline must handle interleaved events.
  Team filtering must not re-order events.
- **Report scoping:** In parallel mode, each team writes its own report files with
  team-prefixed names (e.g., `CODER_SUMMARY_quality.md`). The parser must handle
  both prefixed and unprefixed filenames.
- **Data file size:** With 4 teams, `run_state.js` grows ~4x. Ensure the file
  stays under 50KB even with verbose stage data.

## Seeds Forward

- V4 execution engine will call `emit_dashboard_team_state()` per team
- The team data model enables future features: team-level retry, team reassignment,
  cross-team artifact sharing visualization
- The HTTP server from M36 could be extended for real-time team status WebSocket push
