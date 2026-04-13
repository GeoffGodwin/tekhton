# Watchtower Dashboard

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.

Tekhton includes a browser-based dashboard for real-time pipeline monitoring:

```bash
open .claude/dashboard/index.html    # macOS
xdg-open .claude/dashboard/index.html  # Linux
```

The dashboard provides:
- **Live Run** — current stage, agent, turn count, and elapsed time
- **Milestone Map** — dependency graph visualization with status indicators
- **Reports** — run history with stage breakdowns and outcomes
- **Trends** — success rates, timing patterns, and health score trends
- **Security Summary** — open findings by severity, remediation rate
- **Action Items** — non-blocking notes, drift observations, and human actions with severity colors

The dashboard is created automatically by `--init` and updated at the end of each pipeline stage.
