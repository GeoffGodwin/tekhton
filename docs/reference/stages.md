# Pipeline Stages

Tekhton runs your task through a sequence of stages. Each stage uses a specialized
AI agent with a specific role.

## Stage Order

```
Pre-flight → Intake → Scout → Coder → Security → Reviewer → [Rework] → Tester → Commit
```

In milestone mode, an acceptance check runs after the tester stage. The pre-flight
stage was added in v3.66 (M55) and is enabled by default.

## Pre-flight Stage

**Agent:** *(none — pure shell)*
**Purpose:** Validate the environment is ready BEFORE any agent runs

Pre-flight runs immediately after config loading and detection. It checks:

- **Toolchain availability** — Required binaries from the detected stack are
  installed (e.g., `node`, `npm`, `python`, `cargo`, language servers).
- **Dependency freshness** — `node_modules`, virtualenvs, lockfiles are present
  and up-to-date.
- **Browser binaries** — Playwright/Cypress browsers are installed if a UI
  testing framework is detected.
- **Service readiness (M56)** — Cross-references `docker-compose.yml`, test
  configs, and code imports to infer required services (PostgreSQL, Redis,
  MySQL, MongoDB, RabbitMQ, Kafka), then probes them with a 1-second TCP
  connect. Down services produce actionable startup instructions instead of
  cryptic `ECONNREFUSED` errors deep in test output.

Each check produces `pass`, `warn`, or `fail` and is written to
`PREFLIGHT_REPORT.md`. When `PREFLIGHT_AUTO_FIX=true` (the default), `safe`-rated
remediations from the M53 error pattern registry are executed automatically and
the failed check is re-run.

This stage exists to catch environment problems that would otherwise waste 20-70
turns of the coder before the build gate finally surfaces them.

**Configuration:**

- `PREFLIGHT_ENABLED` — Toggle (default: `true`)
- `PREFLIGHT_AUTO_FIX` — Auto-remediate safe issues (default: `true`)
- `PREFLIGHT_FAIL_ON_WARN` — Treat warnings as failures (default: `false`)

## Intake Stage

**Agent:** Intake / PM agent
**Purpose:** Evaluate the task for clarity, scope, and actionability

The intake agent reads your task description and produces an `INTAKE_REPORT.md`
with:

- **Clarity score** (0-100) — How clear and unambiguous the task is
- **Scope assessment** — Whether the task is appropriately sized
- **Recommended tweaks** — Suggestions for making the task more precise

If the clarity score falls below `INTAKE_CLARITY_THRESHOLD` (default: 40), the
pipeline pauses for clarification.

**Configuration:**

- `INTAKE_AGENT_ENABLED` — Toggle this stage (default: `true`)
- `INTAKE_CLARITY_THRESHOLD` — Minimum clarity score (default: `40`)
- `INTAKE_MAX_TURNS` — Turn budget (default: `10`)

## Scout Stage

**Agent:** Scout
**Purpose:** Analyze the codebase and estimate effort

The scout scans the project structure, identifies relevant files, and recommends
turn limits for downstream agents based on task complexity.

When `DYNAMIC_TURNS_ENABLED` is `true` (default), the scout's recommendations
adjust the coder, reviewer, and tester turn limits dynamically.

**Configuration:**

- `SCOUT_MAX_TURNS` — Turn budget (default: `20`)
- `DYNAMIC_TURNS_ENABLED` — Use scout's turn recommendations (default: `true`)

## Coder Stage

**Agent:** Senior Coder
**Purpose:** Implement the task

The coder receives:

- The task description
- Project rules from `CLAUDE.md`
- Architecture documentation
- The active milestone (if in milestone mode)
- Human notes (if any)
- Repo map (if indexer is enabled)

It writes code, produces `CODER_SUMMARY.md`, and may propose architecture
changes.

**Turn exhaustion:** If the coder runs out of turns mid-task with substantive
work completed, Tekhton auto-continues (up to `MAX_CONTINUATION_ATTEMPTS` times).

**Build gate:** After coding, Tekhton runs `ANALYZE_CMD`, `BUILD_CHECK_CMD`,
and any dependency constraint validation. Failures are first classified by the
M53 error pattern registry — environment, service, toolchain, resource, or
test-infrastructure issues are auto-remediated by the M54 engine (e.g.,
`npx playwright install`, `npm install`, port cleanup). Only true code errors
escalate to a build-fix agent.

**Configuration:**

- `CODER_MAX_TURNS` — Turn budget (default: `50`)
- `CONTINUATION_ENABLED` — Auto-continue on turn exhaustion (default: `true`)
- `MAX_CONTINUATION_ATTEMPTS` — Max continuations (default: `3`)

## Security Stage

**Agent:** Security Reviewer
**Purpose:** Check for vulnerabilities

The security agent reviews the coder's changes for:

- OWASP Top 10 vulnerabilities
- Hardcoded secrets
- Dependency vulnerabilities
- Insecure patterns

Findings are written to `SECURITY_REPORT.md`. Issues at or above
`SECURITY_BLOCK_SEVERITY` trigger automatic rework.

**Configuration:**

- `SECURITY_AGENT_ENABLED` — Toggle this stage (default: `true`)
- `SECURITY_MAX_TURNS` — Turn budget (default: `15`)
- `SECURITY_BLOCK_SEVERITY` — Block threshold (default: `HIGH`)
- See [Security Configuration](../guides/security-config.md) for full details

## Review Stage

**Agent:** Code Reviewer
**Purpose:** Review the implementation for quality and correctness

The reviewer produces `REVIEWER_REPORT.md` with one of three verdicts:

| Verdict | Meaning | Action |
|---------|---------|--------|
| `APPROVED` | Code meets standards | Pipeline continues to tester |
| `CHANGES_REQUIRED` | Issues found | Rework agent fixes them |
| `REPLAN_REQUIRED` | Fundamental approach is wrong | Triggers replanning |

### Rework Routing

- **Complex blockers** → Senior coder rework
- **Simple issues** (naming, formatting, minor fixes) → Junior coder
- After rework, the build gate runs again
- The cycle repeats up to `MAX_REVIEW_CYCLES` times

**Configuration:**

- `REVIEWER_MAX_TURNS` — Turn budget (default: `15`)
- `MAX_REVIEW_CYCLES` — Max review-rework iterations (default: `3`)

## Tester Stage

**Agent:** Tester
**Purpose:** Write and run tests

The tester writes tests for the new code and validates them against `TEST_CMD`.
Output goes to `TESTER_REPORT.md`. The tester self-reports `TEST_CMD` timing in
a structured section that the pipeline parses for `TIMING_REPORT.md` (M62).

If the tester runs out of turns with partial tests written, Tekhton auto-continues
with a resume prompt that carries forward the test plan.

**Surgical fix mode (M64):** When `TESTER_FIX_ENABLED=true` and tests fail, an
inline fix agent operates within the tester stage instead of spawning a full
recursive pipeline run (which previously added 40+ minutes per failing test).
The fix agent receives baseline context so it can distinguish pre-existing
failures from new regressions.

**Test baseline (M63):** A fresh baseline is captured per run (no cross-run
pollution), and the completion gate runs `TEST_CMD` itself instead of trusting
the coder's "COMPLETE" claim. Toggle the latter with `COMPLETION_GATE_TEST_ENABLED`.

**Configuration:**

- `TESTER_MAX_TURNS` — Turn budget (default: `30`)
- `TEST_CMD` — Command to run tests (default: `true` / no-op)
- `TESTER_FIX_ENABLED` — Inline fix on test failure (default: `false`)
- `TESTER_FIX_MAX_DEPTH` — Inline fix attempts per stage (default: `1`)
- `COMPLETION_GATE_TEST_ENABLED` — Run tests in the completion gate (default: `true`)

## Cleanup Stage (Optional)

**Agent:** Junior Coder
**Purpose:** Address non-blocking tech debt

Runs after successful pipeline completion when `CLEANUP_ENABLED` is `true` and
enough items have accumulated in `NON_BLOCKING_LOG.md`.

**Configuration:**

- `CLEANUP_ENABLED` — Toggle (default: `false`)
- `CLEANUP_BATCH_SIZE` — Items per sweep (default: `5`)
- `CLEANUP_TRIGGER_THRESHOLD` — Min items to trigger (default: `5`)

## Architect Stage (Conditional)

**Agent:** Architect
**Purpose:** Audit and resolve architectural drift

Runs before the main pipeline when drift thresholds are exceeded or
`--force-audit` is passed. The architect produces `ARCHITECT_PLAN.md` with
remediation steps, then routes fixes to coder agents.

**Configuration:**

- `DRIFT_OBSERVATION_THRESHOLD` — Observations before auto-audit (default: `8`)
- `DRIFT_RUNS_SINCE_AUDIT_THRESHOLD` — Runs between audits (default: `5`)
- `ARCHITECT_MAX_TURNS` — Turn budget (default: `25`)
