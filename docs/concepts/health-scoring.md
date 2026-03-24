# Health Scoring

Tekhton can assess your project's health across five categories, producing a
composite score and actionable recommendations.

## Running a Health Check

```bash
tekhton --health
```

This produces `HEALTH_REPORT.md` with scores and recommendations.

## Scoring Categories

| Category | Default Weight | What It Measures |
|----------|---------------|-----------------|
| Tests | 30% | Test command availability, test file coverage, test patterns |
| Quality | 25% | Linter configuration, code patterns, static analysis |
| Dependencies | 15% | Dependency freshness, known vulnerabilities, lock file presence |
| Documentation | 15% | README quality, inline documentation, architecture docs |
| Hygiene | 15% | Git hygiene, file organization, configuration completeness |

### Adjusting Weights

Customize weights in `pipeline.conf` to match your priorities:

```bash
HEALTH_WEIGHT_TESTS=40      # Emphasize test coverage
HEALTH_WEIGHT_QUALITY=25
HEALTH_WEIGHT_DEPS=10
HEALTH_WEIGHT_DOCS=15
HEALTH_WEIGHT_HYGIENE=10
```

Weights must sum to 100.

## Belt Ratings

Health scores map to belt ratings for quick visual assessment:

| Score | Belt |
|-------|------|
| 90-100 | Black Belt |
| 80-89 | Brown Belt |
| 70-79 | Purple Belt |
| 60-69 | Blue Belt |
| 50-59 | Green Belt |
| 40-49 | Yellow Belt |
| 0-39 | White Belt |

Toggle belt display: `HEALTH_SHOW_BELT=true` (default).

## Health Baseline

On first assessment, Tekhton saves a baseline to `.claude/HEALTH_BASELINE.json`.
Future assessments compare against this baseline to show trends.

## Configuration

| Key | Default | Description |
|-----|---------|-------------|
| `HEALTH_ENABLED` | `true` | Toggle health scoring |
| `HEALTH_REASSESS_ON_COMPLETE` | `false` | Re-assess after milestone completion |
| `HEALTH_RUN_TESTS` | `false` | Run tests as part of assessment |
| `HEALTH_SAMPLE_SIZE` | `20` | Files to sample for quality checks |

## What's Next?

- [Watchtower Dashboard](../guides/watchtower.md) — Visual health display
- [Configuration Reference](../reference/configuration.md) — All health config keys
