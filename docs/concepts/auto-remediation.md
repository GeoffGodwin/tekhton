# Auto-Remediation

Tekhton's auto-remediation system catches the boring, repeatable build and test
failures — the ones that have nothing to do with your code — and fixes them
before they waste agent turns. When the build gate hits a known pattern like
"Playwright browsers not installed" or "stale `node_modules`", Tekhton runs the
fix and retries the failed phase automatically.

This is what powers the difference between "the coder spent 40 turns trying to
debug a phantom error" and "the pipeline ran a one-line fix and moved on."

## The Three Pillars

Auto-remediation is built from three complementary systems delivered in
milestones M53–M56:

| System | Milestone | What It Does |
|--------|-----------|--------------|
| **Error pattern registry** | M53 | Classifies build/test output into six categories |
| **Auto-remediation engine** | M54 | Runs safe fixes automatically and retries the failed phase |
| **Pre-flight validation** | M55 | Checks the environment before any agent runs |
| **Service readiness probing** | M56 | Detects required services and verifies they're reachable |

## Error Categories

When the build gate captures error output, every line is matched against a
declarative regex registry. Each match produces a category, a safety rating, an
optional remediation command, and a human-readable diagnosis.

| Category | Examples | Who Owns It |
|----------|----------|-------------|
| `env_setup` | Missing Playwright browsers, missing Cypress binary, missing virtualenv | Auto-remediation engine |
| `service_dep` | PostgreSQL/Redis/MySQL/Mongo/RabbitMQ/Kafka not reachable | User (services are external) |
| `toolchain` | Missing `node_modules`, missing Python packages, missing Go modules | Auto-remediation engine |
| `resource` | Port already in use, out of memory, no disk space, permission denied | User (often) |
| `test_infra` | Obsolete snapshots, missing fixtures, test timeouts | Mixed |
| `code` | TypeScript errors, syntax errors, unresolved imports, type errors | Build-fix agent |

Only `code` failures escalate to the build-fix agent. Everything else gets
routed to the remediation engine first.

## Safety Levels

Not every fix is safe to run unattended. Each pattern in the registry carries
one of four safety ratings:

| Safety | What Happens |
|--------|-------------|
| `safe` | Run automatically. Most `env_setup` and `toolchain` issues. |
| `prompt` | Logged to `HUMAN_ACTION_REQUIRED.md` with the suggested fix — not executed automatically. |
| `manual` | Diagnosed clearly but no command is run. The user has to act. |
| `code` | Routed to the build-fix agent. The error is in the code, not the environment. |

For example: `npx playwright install` is `safe` (it's idempotent and only
downloads browser binaries). `EADDRINUSE` is `manual` (Tekhton won't kill an
unknown process holding your port). `Cannot find module` is `safe` (run `npm
install`). `error TS2345` is `code` (the agent has to fix it).

## How It Flows

Here's the actual sequence when the build gate hits a failure:

```
1. ANALYZE_CMD / BUILD_CHECK_CMD runs
2. Output captured to BUILD_ERRORS.md
3. classify_build_error() walks each line, returns:
     CATEGORY|SAFETY|REMEDIATION_CMD|DIAGNOSIS
4. If category != code:
     a. If safety == safe → run REMEDIATION_CMD, re-run failed phase
     b. If safety == prompt → write to HUMAN_ACTION_REQUIRED.md, halt or skip
     c. If safety == manual → log diagnosis, halt with actionable error
5. If category == code → escalate to build-fix agent
6. Cap: max 2 remediation attempts per gate (REMEDIATION_MAX_ATTEMPTS)
7. Each attempt logged to the causal event log
```

The cap is intentional. If `npm install` failed twice in a row, automation
isn't going to fix it on the third try — something deeper is wrong and the
human should look.

## Pre-flight Validation (M55)

The build gate is reactive: it sees errors only after the coder has spent turns
producing them. Pre-flight is proactive: it runs after config loading but
**before any agent invocation**.

Pre-flight checks:

- **Toolchain availability** — Are `node`, `npm`, `python`, `cargo`, and
  language servers installed?
- **Dependency freshness** — Are `node_modules` and virtualenvs present and in
  sync with lockfiles?
- **Browser binaries** — If Playwright or Cypress is detected, are the browsers
  installed?
- **Service readiness** (M56) — Are required services reachable?

Each check produces `pass`, `warn`, or `fail` and is written to
`PREFLIGHT_REPORT.md`. Failures classified as `safe` by the M53 registry are
auto-fixed by the M54 engine, then re-checked.

The point of pre-flight is simple: if you're missing Playwright browsers, the
coder shouldn't waste 20 turns running tests, hitting `Executable doesn't
exist`, attempting random debugging, and finally surfacing the real issue. The
fix takes 90 seconds. Pre-flight runs it before the run starts.

## Service Readiness Probing (M56)

Pre-flight cross-references three sources to figure out which services your
project needs:

1. **`docker-compose.yml`** — Service definitions
2. **Test framework configs** — `vitest.config.ts`, `jest.config.js`,
   `pytest.ini`, etc.
3. **Code imports** — `import Redis`, `from psycopg2`, etc.

For each detected service, Tekhton attempts a 1-second TCP connect on the
expected port. If the connection fails, you get an actionable error like:

```
[FAIL] PostgreSQL not reachable (port 5432)
       Detected from: docker-compose.yml, src/db/connection.py
       Try: docker compose up -d postgres
```

Instead of:

```
[ERROR] connect ECONNREFUSED 127.0.0.1:5432
   at TCPConnectWrap.afterConnect (...stack trace, 40 lines deep...)
```

The supported service catalog includes PostgreSQL, MySQL, MongoDB, Redis,
RabbitMQ, Kafka, Elasticsearch, and Docker.

## Configuration

```bash
# Pre-flight stage
PREFLIGHT_ENABLED=true              # Toggle the entire pre-flight stage
PREFLIGHT_AUTO_FIX=true             # Run safe remediations automatically
PREFLIGHT_FAIL_ON_WARN=false        # Treat warnings as failures

# Auto-remediation engine
REMEDIATION_MAX_ATTEMPTS=2          # Max remediation attempts per gate
REMEDIATION_TIMEOUT=60              # Per-attempt timeout in seconds
```

You can disable everything by setting `PREFLIGHT_ENABLED=false` and letting the
build gate fall back to the build-fix agent for all errors. This isn't
recommended — you'll spend more turns and hit more confusing errors — but it's
supported for parity with pre-M53 behavior.

## What Gets Logged

Every remediation attempt is recorded in the causal event log
(`.claude/logs/CAUSAL_LOG.jsonl`):

- The captured error pattern
- The category and safety classification
- The remediation command (if any)
- The exit code and duration
- Whether the retry succeeded

This makes auto-remediation observable: if the same pattern keeps firing across
runs, you can see it in the metrics dashboard and address the root cause.

## When Auto-Remediation Falls Short

Auto-remediation is deliberately conservative. It won't:

- Modify your code
- Touch git state
- Restart system services or containers
- Run anything classified as `manual`
- Retry forever (capped at 2 attempts per gate)

If your error doesn't match any registry pattern, it's classified as `code` and
the build-fix agent takes over. If it matches but the safety is `prompt` or
`manual`, you'll see a clear diagnosis in `HUMAN_ACTION_REQUIRED.md` with the
suggested fix — Tekhton just won't run it for you.

## What's Next?

- [Pipeline Flow](pipeline-flow.md) — Where auto-remediation sits in the pipeline
- [Pipeline Stages](../reference/stages.md#pre-flight-stage) — Pre-flight stage reference
- [Configuration Reference](../reference/configuration.md) — All M53–M56 config keys
- [Causal Event Log](causal-log.md) — Where remediation events are recorded
