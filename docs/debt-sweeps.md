# Autonomous Debt Sweeps

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.

After a successful pipeline run, an optional cleanup stage addresses accumulated
technical debt from `NON_BLOCKING_LOG.md` using the jr coder model (low cost):

```bash
CLEANUP_ENABLED=true
CLEANUP_BATCH_SIZE=5          # Items per sweep
CLEANUP_TRIGGER_THRESHOLD=5   # Min items before triggering
```

Items requiring architectural changes are tagged `[DEFERRED]` and skipped. Build gate
failure in cleanup logs a warning but doesn't fail the overall run.
