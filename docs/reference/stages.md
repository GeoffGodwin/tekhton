# Pipeline Stages

Tekhton runs your task through a sequence of stages. Each stage uses a specialized
AI agent with a specific role.

## Stage Order

```
Intake → Scout → Coder → Security → Reviewer → [Rework] → Tester → Commit
```

In milestone mode, an acceptance check runs after the tester stage.

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
and any dependency constraint validation. If the build fails, a build-fix agent
attempts repairs.

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
Output goes to `TESTER_REPORT.md`.

If the tester runs out of turns with partial tests written, Tekhton auto-continues
with a resume prompt that carries forward the test plan.

**Configuration:**

- `TESTER_MAX_TURNS` — Turn budget (default: `30`)
- `TEST_CMD` — Command to run tests (default: `true` / no-op)

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
