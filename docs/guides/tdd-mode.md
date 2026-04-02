# TDD Mode

Tekhton supports test-driven development by running the tester before the coder.
The tester writes a failing test spec, and the coder implements code to make it
pass.

## Enabling TDD Mode

Set the pipeline order in your `pipeline.conf`:

```bash
PIPELINE_ORDER=test_first
```

## How It Works

In standard mode, the pipeline runs: Intake → Scout → Coder → Security → Reviewer → Tester.

In `test_first` mode, the order changes:

1. **Intake** — evaluates task clarity and scope
2. **Scout** — analyzes the codebase
3. **Tester (preflight)** — writes a failing test spec → `TESTER_PREFLIGHT.md`
4. **Coder** — implements code to make the tests pass (receives the test spec as context)
5. **Security Review** — vulnerability scan
6. **Code Review** — quality review with rework loop
7. **Tester (validation)** — verifies the tests pass and adds coverage

## Configuration

```bash
# Pipeline order: standard (default) or test_first
PIPELINE_ORDER=test_first

# Output file for the preflight test spec
TDD_PREFLIGHT_FILE=TESTER_PREFLIGHT.md

# Turn limit for the preflight (write-failing) tester
TESTER_WRITE_FAILING_MAX_TURNS=15

# Coder turn multiplier in test_first mode (tests add context)
CODER_TDD_TURN_MULTIPLIER=1.2
```

The `TESTER_WRITE_FAILING_MAX_TURNS` controls the turn budget for the preflight
tester that writes failing tests. It defaults to 15, which is lower than a full
tester run since the preflight only writes specs without running validation.

The `CODER_TDD_TURN_MULTIPLIER` gives the coder slightly more turns in TDD mode,
since it needs to read and satisfy the test spec in addition to the task itself.

## When to Use TDD Mode

- When you want tests written before implementation
- For tasks with clear, testable acceptance criteria
- When working on critical code paths where test coverage is essential

## Limitations

- TDD mode works best for well-defined tasks. Vague tasks may produce test specs
  that are hard to satisfy.
- The tester preflight runs with the same turn budget as a normal tester stage.
  Complex test suites may need higher `TESTER_MAX_TURNS`.

## What's Next?

- [Pipeline Stages](../reference/stages.md) — Stage order details
- [Configuration Reference](../reference/configuration.md) — Pipeline order config
- [Your First Milestone](../getting-started/first-milestone.md) — Milestone mode
