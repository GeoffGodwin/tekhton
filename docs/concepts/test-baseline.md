# Test Baseline

The test baseline system detects pre-existing test failures so agents aren't
blamed for inherited test debt. When your project already has failing tests
before Tekhton runs, the baseline ensures those failures don't block the
pipeline.

## How It Works

1. **Capture** — Before the pipeline modifies any code, Tekhton runs `TEST_CMD`
   and records which tests fail. This is the baseline.
2. **Compare** — After the coder and tester stages, when acceptance criteria are
   checked, test failures are compared against the baseline.
3. **Filter** — Failures that match the baseline are classified as pre-existing
   and excluded from acceptance evaluation.

## Configuration

```bash
# Toggle test baseline detection
TEST_BASELINE_ENABLED=true

# Auto-pass acceptance when ALL failures are pre-existing
TEST_BASELINE_PASS_ON_PREEXISTING=true

# Consecutive identical acceptance failures before stuck detection
TEST_BASELINE_STUCK_THRESHOLD=2

# What to do when stuck: auto-pass (true) or exit with diagnosis (false)
TEST_BASELINE_PASS_ON_STUCK=false
```

## Stuck Detection

If the same set of test failures appears across multiple consecutive pipeline
attempts (controlled by `TEST_BASELINE_STUCK_THRESHOLD`), the system detects
a "stuck" condition. This typically means:

- The failures are genuinely pre-existing and can't be fixed by the current task
- The coder is repeatedly attempting and failing to fix the same tests

When stuck is detected:
- If `TEST_BASELINE_PASS_ON_STUCK=true`, the pipeline auto-passes acceptance
- If `TEST_BASELINE_PASS_ON_STUCK=false` (default), the pipeline exits with a
  diagnostic message explaining which tests are stuck

## When to Use

- Projects with known test debt that you haven't fixed yet
- Brownfield projects where some tests may be flaky or outdated
- Multi-milestone projects where earlier milestones may have left test gaps

## Limitations

- The baseline is captured once per pipeline run. If your tests are flaky
  (intermittently passing/failing), a flaky test might not be in the baseline
  and could block acceptance.
- The baseline compares test failure output textually. Changes to test output
  formatting between runs may cause mismatches.

## What's Next?

- [Causal Log](causal-log.md) — Event logging for debugging
- [Health Scoring](health-scoring.md) — Project health assessment
- [Configuration Reference](../reference/configuration.md) — Test baseline config keys
