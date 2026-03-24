# Using --diagnose

When a pipeline run fails, `--diagnose` analyzes the failure and suggests
recovery steps.

## Running Diagnostics

```bash
tekhton --diagnose
```

This reads the last run's logs, reports, and state files to determine:

- **What failed** — Which stage, which agent, what error
- **Why it failed** — Error classification (transient, configuration, code, quota)
- **How to fix it** — Specific recovery steps

## Diagnostic Rules

### Build Gate Failure

**Symptom:** Pipeline stops after coder stage with build errors.

**Recovery:**

1. Check `BUILD_ERRORS.md` for the specific errors
2. Verify `BUILD_CHECK_CMD` in `pipeline.conf` is correct
3. If the build-fix agent couldn't resolve it, fix manually and resume:
   ```bash
   tekhton --start-at review "Your task"
   ```

### Review Cycle Exhaustion

**Symptom:** Pipeline stops after max review cycles with unresolved issues.

**Recovery:**

1. Read `REVIEWER_REPORT.md` for the remaining issues
2. Fix the issues manually
3. Resume from the tester stage:
   ```bash
   tekhton --start-at tester "Your task"
   ```

### Turn Exhaustion

**Symptom:** Agent runs out of turns mid-task.

**Recovery:**

- If `CONTINUATION_ENABLED=true` (default), Tekhton auto-continues
- If continuation also exhausted, increase turn limits:
  ```bash
  # In pipeline.conf
  CODER_MAX_TURNS=80    # Up from default 50
  ```
- For milestone mode, use `MILESTONE_CODER_MAX_TURNS`

### Quota / API Errors

**Symptom:** Agent fails with API rate limit or quota errors.

**Recovery:**

- Wait for quota to refresh (Tekhton auto-pauses if configured)
- Set `USAGE_THRESHOLD_PCT` to pause proactively before hitting limits
- Resume: `tekhton` (with no arguments, it offers to resume)

### Null Run

**Symptom:** Agent completes but produces no meaningful changes.

**Recovery:**

- The task may be too vague — make it more specific
- Check if `INTAKE_REPORT.md` flagged clarity issues
- For milestones, check if acceptance criteria are clear enough

### Security Block

**Symptom:** Pipeline blocks on security findings.

**Recovery:**

1. Read `SECURITY_REPORT.md` for the findings
2. Fix the issues manually, or:
3. Add waivers to `SECURITY_WAIVER_FILE` for accepted risks
4. Resume: `tekhton --start-at review "Your task"`

## When to Ask for Help

If `--diagnose` doesn't resolve the issue:

- Check the full agent log in `.claude/logs/` for the raw output
- File an issue at the [Tekhton repository](https://github.com/GeoffGodwin/tekhton/issues)
  with the diagnostic output

## What's Next?

- [Common Errors](common-errors.md) — Specific error messages and fixes
- [FAQ](faq.md) — Frequently asked questions
