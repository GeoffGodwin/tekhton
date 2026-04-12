# Common Errors

Quick reference for error messages you might encounter and how to fix them.

## Installation & Setup

### "bash: tekhton: command not found"

Tekhton isn't on your PATH.

```bash
echo 'export PATH="$HOME/.tekhton:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### "Tekhton requires bash 4.3+. Current: 3.2.57"

Your bash version is too old. This is common on macOS.

**macOS fix:**
```bash
brew install bash
```

Make sure the Homebrew bash is on your PATH before `/bin/bash`.

### "Required tool not found: claude"

The Claude CLI isn't installed or isn't on your PATH.

Install it following [Anthropic's instructions](https://docs.anthropic.com/en/docs/claude-cli),
then verify: `claude --version`.

## Pipeline Errors

### "No pipeline.conf found"

You haven't initialized Tekhton in this project:

```bash
tekhton --init
```

### "BUILD_CHECK_CMD failed"

Your build command returned a non-zero exit code. Check:

1. Does the command in `pipeline.conf` actually work?
   ```bash
   # Run it manually
   eval "$(grep BUILD_CHECK_CMD .claude/pipeline.conf | cut -d= -f2-)"
   ```
2. Did the coder introduce a syntax error? Check `BUILD_ERRORS.md`.

### "ANALYZE_CMD failed"

Your linter found errors. Check:

1. `BUILD_ERRORS.md` for the specific lint errors
2. Whether `ANALYZE_ERROR_PATTERN` in `pipeline.conf` matches your linter's
   error format

### "Max review cycles exhausted"

The reviewer and rework agents couldn't resolve all issues in the allowed number
of iterations.

Options:
- Increase `MAX_REVIEW_CYCLES` in `pipeline.conf`
- Fix remaining issues manually and resume: `tekhton --start-at tester "..."`
- Check if the reviewer's role definition is too strict for the task

### "Agent null run detected"

The agent used very few turns and produced no meaningful output. Common causes:

- Task description is too vague
- The codebase doesn't match what the task expects
- Agent role definition is misconfigured

Fix: Make the task more specific, or check `INTAKE_REPORT.md` for clarity feedback.

## Quota & API

### "API quota exceeded"

You've hit the Claude API rate limit. Options:

- Wait for the quota to refresh (usually resets hourly)
- Set `USAGE_THRESHOLD_PCT=80` to pause proactively
- Resume when ready: `tekhton` (offers to resume from saved state)

### "Transient error: connection timeout"

Network issue connecting to the Claude API. Tekhton retries automatically
(up to `MAX_TRANSIENT_RETRIES` times with exponential backoff).

If retries are exhausted, check your network connection and try again.

## Milestone Errors

### "Circular dependency detected"

Your milestone manifest has circular dependencies (A depends on B, B depends on A).

Fix the `MANIFEST.cfg` in `.claude/milestones/` to remove the cycle.

### "No frontier milestones found"

All milestones either have unsatisfied dependencies or are already done.

Check `MANIFEST.cfg` — you may need to mark a prerequisite milestone as `done`,
or there may be no more work to do.

## What's Next?

- [Using --diagnose](diagnose.md) — Automated failure analysis
- [FAQ](faq.md) — General questions
