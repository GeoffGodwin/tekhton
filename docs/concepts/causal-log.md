# Causal Event Log

The causal event log is a structured JSONL file that records pipeline events for
debugging and cross-run learning. It provides a timeline of what happened, why,
and what the outcome was.

## Purpose

When something goes wrong in a pipeline run, the causal log tells you:

- What events led to the failure
- Which agent made which decisions
- What the pipeline state was at each point
- How previous runs handled similar situations

## Log Format

Events are stored in `.claude/logs/CAUSAL_LOG.jsonl` (configurable via
`CAUSAL_LOG_FILE`). Each line is a JSON object:

```json
{
  "timestamp": "2026-03-15T14:32:01Z",
  "run_id": "run_abc123",
  "event": "agent_complete",
  "stage": "coder",
  "data": {
    "turns_used": 42,
    "exit_code": 0,
    "files_modified": 7
  }
}
```

## Event Types

The log captures events across the pipeline lifecycle:

- **Pipeline events** — run start, stage transitions, completion, failure
- **Agent events** — invocation, completion, retry, turn exhaustion
- **Decision events** — milestone selection, split triggers, rework routing
- **Gate events** — build gate pass/fail, acceptance check results
- **Error events** — transient errors, classification, recovery actions

## Retention

The log is rotated per run. Completed runs are archived, and the
`CAUSAL_LOG_RETENTION_RUNS` setting (default: 50) controls how many archived
logs are kept.

Events within a single run are capped at `CAUSAL_LOG_MAX_EVENTS` (default: 2000)
to prevent unbounded growth. Oldest events are evicted when the cap is reached.

## Configuration

```bash
CAUSAL_LOG_ENABLED=true                        # Toggle event logging
CAUSAL_LOG_FILE=.claude/logs/CAUSAL_LOG.jsonl  # Log file path
CAUSAL_LOG_RETENTION_RUNS=50                   # Archived logs to keep
CAUSAL_LOG_MAX_EVENTS=2000                     # Max events per run
```

## Usage with --diagnose

The `--diagnose` command reads the causal log to provide structured failure
analysis and recovery suggestions. It traces the event timeline backward from
the failure point to identify root causes.

## What's Next?

- [Test Baseline](test-baseline.md) — Pre-existing failure detection
- [Pipeline Flow](pipeline-flow.md) — How the pipeline works
- [Using --diagnose](../troubleshooting/diagnose.md) — Failure diagnosis
