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

## Dashboard Sections

### Live Run Status

Shows the currently running pipeline stage, agent name, turn count, and elapsed
time. Updates automatically during a pipeline run.

### Milestone Map

Visualizes your milestone plan as a dependency graph. Each milestone shows:

- Status (pending, in progress, done, failed)
- Acceptance criteria progress
- Dependencies on other milestones

### Run History

A timeline of past pipeline runs showing:

- Task description
- Duration and agent call count
- Outcome (success, failure, partial)
- Stage-by-stage breakdown

### Health Score

Displays your project's health score with category breakdowns:

- Tests, Quality, Dependencies, Documentation, Hygiene
- Trend over time (improving or declining)
- Belt rating (visual indicator)

### Security Summary

Overview of security findings across runs:

- Open findings by severity
- Remediation rate
- Waived issues

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
