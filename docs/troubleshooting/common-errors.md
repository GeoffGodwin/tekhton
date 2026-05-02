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

### "UI tests timed out with interactive report serving"

**Symptom.** The UI test phase of the build gate fails after `UI_TEST_TIMEOUT`
seconds and the captured output contains:

```
Serving HTML report at http://localhost:9323
Press Ctrl+C to quit.
```

The exit code is `124`. This means the command finished its tests but stayed
alive serving the HTML report — Playwright's default behavior when run outside
CI mode.

**Automatic recovery.** Tekhton classifies this as the `interactive_report`
timeout class. M54 registry remediation and the generic flakiness retry are
both skipped (they would just hang again). A single hardened rerun is performed
with `PLAYWRIGHT_HTML_OPEN=never` and `CI=1` injected via `env(1)` at a reduced
timeout (`UI_GATE_ENV_RETRY_TIMEOUT_FACTOR`, default `0.5 × UI_TEST_TIMEOUT`).
On success, the gate logs `UI tests passed after deterministic reporter
hardening.` and clears the error files.

**Permanent fix.** When the hardened rerun also fails, both `BUILD_ERRORS.md`
and `UI_TEST_ERRORS.md` contain a `## UI Gate Diagnosis` section pointing here.
Configure the gate to disable report serving by either:

- Adding `--reporter=line` (or another non-HTML reporter) to `UI_TEST_CMD` in
  `pipeline.conf`.
- Setting `reporter: [['html', { open: 'never' }]]` in your project's
  `playwright.config.{ts,js}`.
- Exporting `PLAYWRIGHT_HTML_OPEN=never` in the CI environment.

To suppress the hardened rerun entirely, set `UI_GATE_ENV_RETRY_ENABLED=false`
in `pipeline.conf`; the gate will still classify the failure and emit
diagnosis, but it will not perform the rerun.

### "Build errors classified as unknown_only"

**Symptom.** The build gate fails and the run log shows
`Build-fix routing decision: unknown_only`. `BUILD_ERRORS.md` contains output
that did not match any signature in the M53 error-pattern registry — usually a
new tool, a custom error format, or output that was scrambled by ANSI/progress
artifacts.

**Automatic recovery.** The pipeline still runs the bounded build-fix coder
once on the unknown_only path (this preserves the pre-M127 fallback). If that
attempt fails, the gate exits with `build_failure` state saved.

**Manual triage.** Open `BUILD_ERRORS.md` and look at `## Full Analyze Output`
or `## Full Compile Output`. If the failure root cause is a recognizable
pattern (missing dependency, environment problem, service down) that the
registry doesn't yet know about, add it to
`lib/error_patterns_registry.sh` so future runs route correctly. Otherwise,
fix the underlying issue manually and re-run.

If the run log shows `Build-fix routing decision: noncode_dominant` instead,
the gate skipped build-fix entirely because the signal was pure environment.
Check `HUMAN_ACTION_REQUIRED.md` for the diagnosis and remediate the
environment before re-running.

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
