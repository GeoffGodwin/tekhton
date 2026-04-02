# Milestone 56: Service Readiness Probing & Enhanced Diagnosis
<!-- milestone-meta
id: "56"
status: "pending"
-->

## Overview

When a project's tests require a database, cache, or queue, the most common
failure mode is "service not running." These failures manifest as cryptic
`ECONNREFUSED` errors deep in test output — often after minutes of agent work.
Milestone 55's pre-flight validates tool availability but doesn't probe network
services. This milestone adds service readiness probing: detect what services
the project depends on, check if they're accessible, and provide actionable
startup instructions rather than raw connection errors.

Depends on Milestone 55 (pre-flight framework).

## Scope

### 1. Service Dependency Inference (`lib/preflight.sh` — extend)

**Function:** `_preflight_check_services()`

Cross-reference multiple signals to build a list of required services:

**Signal sources:**
1. **Docker Compose** — Parse `docker-compose.yml` / `compose.yml` for service
   names. Map common images to service types:
   - `postgres` / `postgis` → PostgreSQL (port 5432)
   - `mysql` / `mariadb` → MySQL (port 3306)
   - `mongo` → MongoDB (port 27017)
   - `redis` → Redis (port 6379)
   - `rabbitmq` → RabbitMQ (port 5672)
   - `kafka` / `confluentinc/cp-kafka` → Kafka (port 9092)
   - `elasticsearch` / `opensearch` → Elasticsearch (port 9200)
   - `minio` → MinIO/S3 (port 9000)
   - `mailhog` / `mailpit` → Mail (port 1025)

2. **Package dependencies** — Check manifest files for database client libraries:
   - `pg` / `prisma` / `typeorm` / `sequelize` / `knex` → PostgreSQL/MySQL (check config)
   - `redis` / `ioredis` / `bull` / `bullmq` → Redis
   - `mongoose` / `mongodb` → MongoDB
   - `amqplib` / `amqp-connection-manager` → RabbitMQ
   - `kafkajs` → Kafka
   - Python: `psycopg2` / `asyncpg` / `sqlalchemy` / `django.db` → PostgreSQL
   - Python: `redis` / `celery` → Redis
   - Go: `pgx` / `go-redis` / `mongo-driver` → respective services

3. **Environment variable names** — Scan `.env.example` for patterns:
   - `DATABASE_URL` / `DB_HOST` / `POSTGRES_*` → PostgreSQL
   - `REDIS_URL` / `REDIS_HOST` → Redis
   - `MONGO_URI` / `MONGODB_URI` → MongoDB
   - `RABBITMQ_URL` / `AMQP_URL` → RabbitMQ

4. **Existing detection** — Reuse `detect_services` output (already parsed
   docker-compose, Procfile, k8s manifests).

### 2. Port Probing (`lib/preflight.sh` — extend)

**Function:** `_probe_service_port()`

For each inferred service, probe its expected port:

```bash
_probe_service_port() {
    local host="${1:-127.0.0.1}"
    local port="$2"
    local timeout_s="${3:-2}"

    # Method 1: bash /dev/tcp (most portable, no extra deps)
    if (echo >/dev/tcp/"$host"/"$port") 2>/dev/null; then
        return 0
    fi

    # Method 2: nc/ncat fallback
    if command -v nc &>/dev/null; then
        nc -z -w "$timeout_s" "$host" "$port" 2>/dev/null && return 0
    fi

    return 1
}
```

**Timeout:** 2 seconds per probe. With max ~8 services, total probe time
stays under the 5-second pre-flight budget.

### 3. Service Status Reporting

For each required service, report one of:
- **Running** — Port is open, service is presumably healthy
- **Not running** — Port is closed, include startup instructions
- **Unknown** — Cannot determine (port probe failed for non-network reason)

**Startup instructions** are context-aware based on what's available:

```
PostgreSQL is not running on port 5432.

Start it with one of:
  • docker-compose up -d postgres    (docker-compose.yml detected)
  • brew services start postgresql   (macOS)
  • sudo systemctl start postgresql  (Linux systemd)
  • pg_ctl start                     (manual)
```

Instruction selection:
- If `docker-compose.yml` exists with the service → recommend `docker-compose up -d <name>`
- If on macOS (detect via `uname`) → recommend `brew services start`
- If on Linux with systemd (`systemctl` available) → recommend `systemctl start`
- Always include the generic manual command as fallback

### 4. Docker Daemon Check

**Function:** `_preflight_check_docker()`

If docker-compose.yml exists OR any service is expected via Docker:
- Check if Docker daemon is running: `docker info &>/dev/null`
- If not: warn with instructions (`sudo systemctl start docker` / open Docker Desktop)
- If running but compose services not up: suggest `docker-compose up -d`

This check runs BEFORE individual service port probes (no point probing
ports if Docker isn't running).

### 5. Dev Server Readiness for E2E

**Function:** `_preflight_check_dev_server()`

Many E2E test frameworks need a dev server running. Detect this from:
- Playwright config (`webServer` field in `playwright.config.ts`)
- `UI_TEST_CMD` that references a URL
- Common patterns: `start-server-and-test`, `concurrently`

If a dev server dependency is detected, check if the expected port is already
serving. If not, this is a **warning** (not failure) — many test frameworks
handle server startup internally.

### 6. Enhanced Error Pattern Diagnosis (`lib/error_patterns.sh` — extend)

Add service-specific patterns with richer diagnosis that references the
pre-flight service detection:

```
ECONNREFUSED.*:5432 | service_dep | manual | | PostgreSQL not running on port 5432
ECONNREFUSED.*:3306 | service_dep | manual | | MySQL not running on port 3306
connection.*timed out.*:6379 | service_dep | manual | | Redis not reachable on port 6379
```

When the build gate hits these patterns AND pre-flight has already probed the
service, include the pre-flight diagnosis (startup instructions) in
BUILD_ERRORS.md rather than just the raw `ECONNREFUSED` message.

### 7. PREFLIGHT_REPORT.md Service Section

Extend the pre-flight report with a services section:

```markdown
### Services

| Service | Port | Status | Source |
|---------|------|--------|--------|
| PostgreSQL | 5432 | ✓ Running | docker-compose.yml |
| Redis | 6379 | ✗ Not running | package.json (ioredis) |
| MongoDB | 27017 | — Skipped | not detected |

#### ✗ Redis (port 6379)
Redis is required (detected via `ioredis` in package.json) but not running.
Start it with:
  docker-compose up -d redis
```

## Acceptance Criteria

- Detects required services from docker-compose, package dependencies, and env vars
- Probes service ports with 2-second timeout per service
- Total pre-flight time remains under 5 seconds (including service probes)
- Reports running/not-running status for each detected service
- Provides context-aware startup instructions (docker-compose vs systemd vs brew)
- Docker daemon availability is checked before service probes
- Dev server dependency detected from Playwright config or UI_TEST_CMD
- PREFLIGHT_REPORT.md includes service status table
- Build gate error patterns reference pre-flight diagnosis for ECONNREFUSED errors
- Service probing does NOT fail the pipeline (warning only) — services may be
  optional or test-only, and the pipeline should attempt execution
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n` and `shellcheck` pass on all modified files
- Tests in `tests/test_preflight.sh` (extend from M55):
  - Service inference from mock docker-compose.yml
  - Service inference from mock package.json dependencies
  - Port probe mock (using a temporary listener)
  - Docker daemon check with mock `docker` command
  - Report includes service status table

Watch For:
- Port probing via `/dev/tcp` is a bashism that may not work in all bash
  builds (some distros compile bash without `/dev/tcp` support). The `nc`
  fallback is essential. Test on both paths.
- Docker Compose v1 (`docker-compose`) vs v2 (`docker compose`) — check both.
  The compose file may be `docker-compose.yml`, `docker-compose.yaml`, or
  `compose.yml`.
- Service port mapping in docker-compose may differ from default: `ports: "5433:5432"`
  means the HOST port is 5433, not 5432. Parse the port mapping, don't assume
  defaults when compose config is available.
- Package dependency detection must be lightweight: `grep` the manifest file,
  don't parse JSON. Check `dependencies` and `devDependencies` sections for
  Node.js (both can contain database clients).
- On CI environments, services are often provided by the CI platform (GitHub
  Actions services, GitLab services). Pre-flight should not fail on CI when
  services are managed externally. Detect CI environment via `CI=true` env
  var and downgrade service failures from warning to info.
- Rate the entire service check as `manual` safety — never auto-start services.
  Starting a database is a side-effect-heavy operation that should always
  require explicit human action.

Seeds Forward:
- Service health data feeds into project health scoring (health_checks_infra.sh)
- Future: service auto-start via docker-compose for projects that opt in
- Future: CI-specific service configuration detection (GitHub Actions, GitLab CI)
- Pre-flight service data enables future "test isolation" features (skip tests
  that require unavailable services rather than failing the entire suite)
