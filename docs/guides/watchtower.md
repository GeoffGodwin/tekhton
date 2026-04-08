# Watchtower Dashboard

The Watchtower is a browser-based dashboard that shows pipeline progress, run
history, milestone status, and project health — all from a single HTML page.

## Opening the Dashboard

```bash
# macOS
open .claude/dashboard/index.html

# Linux
xdg-open .claude/dashboard/index.html

# Or just open the file path in any browser
```

!!! note "Safari and file:// URLs"
    Safari may restrict JavaScript on `file://` URLs. If the dashboard doesn't
    load properly in Safari, try Chrome or Firefox, or start a local server:
    `python3 -m http.server 8080 -d .claude/dashboard` and open
    `http://localhost:8080`.

## Dashboard Tabs

### Live Run

Shows the currently running pipeline stage with real-time updates:

- Current agent name and stage
- Turn count and elapsed time
- Stage timeline showing progression through the pipeline
- Activity indicator (active, idle, waiting)

Updates automatically during a pipeline run via data file polling.

### Milestone Map

Visualizes your milestone plan as a dependency graph:

- Status indicators: pending, in progress, done, failed
- Dependency edges between milestones
- Parallel group visualization
- Acceptance criteria progress for the active milestone

### Reports

Run history with detailed breakdowns:

- Task description and outcome (success, failure, partial)
- Duration and agent call count per run
- Stage-by-stage breakdown with turn counts
- Error classification for failed runs

#### Hierarchical Per-Stage Breakdown (M66)

The Per-Stage Breakdown surfaces every timed step in the pipeline, not just
the top-level stages. Security review, architect audits, cleanup sweeps,
specialist reviews, rework cycles, and individual build-fix attempts all show
up as expandable sub-rows. Sub-rows are collapsed by default — click a stage
to drill down. This makes optimization concrete: you can see exactly which
sub-step is eating wall-clock time instead of guessing.

### Trends

Performance trends across your run history:

- Success rate over time
- Average duration by task type
- Turn consumption patterns
- Health score trend (improving or declining)

### Health Score

Displays your project's health assessment:

- Five-category breakdown: Tests, Quality, Dependencies, Documentation, Hygiene
- Weighted overall score
- Belt rating for quick visual feedback
- Comparison against baseline (if set)

### Security Summary

Overview of security findings across runs:

- Open findings grouped by severity (Critical, High, Medium, Low)
- Remediation rate and trend
- Waived issues count

### Action Items

Aggregated view of items needing attention:

- Non-blocking notes from `NON_BLOCKING_LOG.md` with severity colors
- Drift observations from `DRIFT_LOG.md`
- Human action items from `HUMAN_ACTION_REQUIRED.md`
- Count badges and priority indicators

## Configuration

Control dashboard behavior in `pipeline.conf`:

```bash
DASHBOARD_ENABLED=true               # Toggle dashboard (default: true)
DASHBOARD_VERBOSITY="normal"         # minimal, normal, or verbose
DASHBOARD_HISTORY_DEPTH=50           # How many past runs to show
DASHBOARD_REFRESH_INTERVAL=10        # Seconds between data refreshes during a run
DASHBOARD_MAX_TIMELINE_EVENTS=500    # Max events in the timeline
```

### Verbosity Levels

| Level | What It Shows |
|-------|--------------|
| `minimal` | Current status and outcome only |
| `normal` | Status, run history, milestone map, health (default) |
| `verbose` | Everything, including detailed agent logs and metrics |

## Smart Refresh

The dashboard uses smart refresh to minimize unnecessary reloads:

- Data files are only re-read when their modification time changes
- During active pipeline runs, the refresh interval is `DASHBOARD_REFRESH_INTERVAL` seconds
- Between runs, refresh is less frequent to reduce resource usage
- Layout adapts based on available data (e.g., hides milestone map when no milestones exist)

## Troubleshooting

**Dashboard is blank or shows errors:**

- Check that `.claude/dashboard/data/` directory exists and contains `.js` files
- Verify your browser allows JavaScript on `file://` URLs
- Try a local HTTP server: `python3 -m http.server 8080 -d .claude/dashboard`

**Data isn't updating:**

- The dashboard reads from `.claude/dashboard/data/*.js` files
- These are updated at the end of each pipeline stage
- If running in `--complete` mode, data updates between pipeline iterations

## What's Next?

- [Understanding Output](../getting-started/understanding-output.md) — Report file details
- [Health Scoring](../concepts/health-scoring.md) — How scores are calculated
- [Configuration Reference](../reference/configuration.md) — All dashboard config keys
