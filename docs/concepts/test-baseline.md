# Test Baseline

The test baseline system detects pre-existing test failures so agents aren't
blamed for inherited test debt. When your project already has failing tests
before Tekhton runs, the baseline ensures those failures don't block the
pipeline.

## How It Works

1. **Capture** — At the start of every run, Tekhton runs `TEST_CMD` and
   records which tests fail. This is the baseline. Baselines are captured
   fresh per run — no cross-run pollution.
2. **Inject** — The tester agent receives the baseline as context, so it can
   distinguish failures it caused from failures that were already there before
   the run started.
3. **Compare** — After the coder and tester stages, when acceptance criteria
   are checked, test failures are compared against the baseline.
4. **Filter** — Failures that match the baseline are classified as pre-existing
   and excluded from acceptance evaluation.
5. **Verify at completion** — The completion gate runs `TEST_CMD` itself rather
   than trusting the coder's "COMPLETE" claim. Test enforcement at the gate is
   on by default; toggle with `COMPLETION_GATE_TEST_ENABLED`.

## Hardening Notes (M63)

Earlier versions had three rough edges that M63 fixed:

- **Cross-run baseline pollution** — Stale baselines from previous runs could
  mark genuinely-new regressions as pre-existing. Baselines are now captured
  fresh per run.
- **Trusted "COMPLETE" claims** — The completion gate used to take the coder's
  word that everything passed. It now runs `TEST_CMD` directly via the
  `COMPLETION_GATE_TEST_ENABLED` switch (default: `true`).
- **Tester baseline awareness** — The tester now receives baseline context, so
  it can write "this failure was already failing before I started" in its
  report instead of trying to fix tests it didn't break.
- **`TEST_BASELINE_PASS_ON_STUCK` is now off by default** — The escape hatch
  that auto-passed stuck runs hid more bugs than it helped. You can re-enable
  it explicitly if your project genuinely needs it.

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

# Run TEST_CMD at the completion gate (instead of trusting "COMPLETE")
COMPLETION_GATE_TEST_ENABLED=true
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

## Surgical Tester Fix Mode (M64)

When the tester finds genuine new failures (not pre-existing), Tekhton can
fix them inline rather than spawning a full recursive pipeline run. Set
`TESTER_FIX_ENABLED=true` to enable.

Before M64, a tester failure recursively re-ran the entire pipeline (coder →
reviewer → tester), which added 40+ minutes per failing test. The surgical fix
agent now operates within the tester stage itself, mirroring the coder's
build-fix retry pattern. It receives baseline context so it knows which
failures it actually needs to fix.

```bash
TESTER_FIX_ENABLED=false        # Toggle inline fix on tester failures
TESTER_FIX_MAX_DEPTH=1          # Max inline fix attempts per stage
```

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
