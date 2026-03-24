# Pipeline Flow

This page explains how Tekhton orchestrates the full pipeline from task input
to committed code.

## Overview

```
┌──────────┐    ┌───────┐    ┌───────┐    ┌──────────┐    ┌──────────┐    ┌────────┐    ┌────────┐
│  Intake  │───▶│ Scout │───▶│ Coder │───▶│ Security │───▶│ Reviewer │───▶│ Tester │───▶│ Commit │
└──────────┘    └───────┘    └───────┘    └──────────┘    └──────────┘    └────────┘    └────────┘
                                               │               │
                                               ▼               ▼
                                          ┌─────────┐    ┌──────────┐
                                          │ Sec Fix  │    │  Rework  │
                                          └─────────┘    └──────────┘
```

## Two-Directory Model

Tekhton operates across two directories:

- **`TEKHTON_HOME`** — Where `tekhton.sh` and all pipeline logic lives (this repo)
- **`PROJECT_DIR`** — Your project directory (where you run Tekhton from)

All pipeline logic, prompt templates, and libraries live in `TEKHTON_HOME`.
Project-specific configuration, agent roles, and output files live in
`PROJECT_DIR`. Nothing is copied from your project into Tekhton or vice versa
(except during `--init`).

## Shell Controls Flow

A key design principle: **the shell decides, agents advise.**

Agents produce reports and recommendations, but the bash shell makes all routing
decisions. No agent autonomously modifies pipeline control flow. This means:

- The reviewer's verdict determines whether rework happens, but the shell reads
  the verdict and invokes the rework agent
- The security agent flags issues, but the shell decides whether to block
- The scout recommends turn limits, but the shell clamps them within configured bounds

## Stage Interactions

### Build Gate

After the coder finishes, a build gate runs:

1. `ANALYZE_CMD` (linter)
2. `BUILD_CHECK_CMD` (compile/build)
3. Dependency constraint validation (if configured)

If any step fails, errors are captured in `BUILD_ERRORS.md` and a build-fix
agent attempts repairs. The gate runs again after fixes.

### Review-Rework Loop

The reviewer produces a verdict. If `CHANGES_REQUIRED`:

1. Issues are categorized by complexity
2. Complex issues → senior coder rework
3. Simple issues → junior coder
4. Build gate runs after rework
5. Reviewer runs again
6. Loop repeats up to `MAX_REVIEW_CYCLES` times

### Turn Exhaustion Continuation

If an agent runs out of turns mid-task:

1. Tekhton checks if substantive work was done (files changed, code written)
2. If yes, it builds continuation context from the agent's partial output
3. A new agent invocation picks up where the previous one left off
4. This repeats up to `MAX_CONTINUATION_ATTEMPTS` times

### Transient Error Retry

If an agent call fails due to a transient error (network timeout, API error):

1. Tekhton classifies the error
2. If transient, it waits with exponential backoff
3. Retries the same agent call
4. Up to `MAX_TRANSIENT_RETRIES` attempts

## Complete Mode (`--complete`)

The `--complete` flag wraps the entire pipeline in an outer loop:

```
while not done and attempts < MAX_PIPELINE_ATTEMPTS:
    run full pipeline (intake → ... → tester)
    if task complete:
        break
    if no progress detected:
        break (stuck detection)
```

Safety limits prevent infinite loops:

- `MAX_PIPELINE_ATTEMPTS` — Max full pipeline cycles (default: 5)
- `AUTONOMOUS_TIMEOUT` — Wall-clock timeout (default: 2 hours)
- `MAX_AUTONOMOUS_AGENT_CALLS` — Total agent invocations (default: 200)

## State Persistence

Pipeline state is saved automatically on interruption:

- Current stage
- Task description
- Resume point
- Partial results

Re-running `tekhton` (with no arguments) detects saved state and offers to resume.

## What's Next?

- [Pipeline Stages](../reference/stages.md) — Detailed stage reference
- [Context Budget](context-budget.md) — How prompts are sized
- [Milestone DAG](milestone-dag.md) — Milestone dependency management
