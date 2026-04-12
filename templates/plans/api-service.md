# Design Document — API Service

<!-- Generated from sections below -->

## Developer Philosophy & Constraints
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What are your non-negotiable architectural rules? Examples: -->
<!-- - Contract-first: OpenAPI/protobuf spec is written before implementation -->
<!-- - Idempotency by default: every mutating endpoint must be safely retryable -->
<!-- - Defense in depth: validate at every boundary (API gateway, controller, service, repository) -->
<!-- - Observable from day one: every request gets a trace ID, every error gets structured context -->
<!-- - Schema-driven: database schema is the source of truth, types are generated from it -->
<!-- What patterns must every contributor follow from day one? What anti-patterns are banned? -->

## Project Overview
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What does this service do? What system or product does it support? -->
<!-- Is this a standalone service or part of a larger architecture? -->
<!-- What is the expected request volume? (requests/second at launch, at scale) -->
<!-- What SLA is expected? (uptime percentage, response time P99) -->
<!-- What existing system does this replace or extend? -->

## Tech Stack
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Language: Node.js/TypeScript, Python, Go, Rust, Java, C#? Why? -->
<!-- Framework: Express, Fastify, Django REST, Flask, Gin, Actix, Spring Boot? -->
<!-- Database: PostgreSQL, MySQL, MongoDB, DynamoDB, Redis? Why? -->
<!-- ORM/query layer: Prisma, SQLAlchemy, GORM, Diesel, raw SQL? -->
<!-- Message queue (if any): RabbitMQ, Kafka, SQS, Redis Streams? -->
<!-- Cache layer: Redis, Memcached, in-memory, or none? -->
<!-- Deployment: Docker, Kubernetes, serverless (Lambda/Cloud Functions), VM? -->
<!-- Testing: framework for unit, integration, and contract tests -->

## API Style & Conventions
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Style: REST, GraphQL, gRPC, or hybrid? Why? -->
<!-- Naming: URL path conventions (/api/v1/users, kebab-case vs camelCase) -->
<!-- Payload format: JSON, Protocol Buffers, or both? -->
<!-- Date format: ISO 8601, Unix timestamp, or configurable? -->
<!-- Null handling: omit null fields, include as null, or use sentinel values? -->
<!-- Versioning strategy: URL path (/v1/), header (Accept-Version), or query param? -->
<!-- What happens when a client sends an unknown field? (ignore, reject, warn) -->

## Endpoints & Operations
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- List each endpoint/resource as a ### sub-section. For each: -->
<!-- - Method and path: GET /api/v1/users -->
<!-- - Description: what it does -->
<!-- - Request: path params, query params, body schema with types -->
<!-- - Response: status codes, body schema, headers -->
<!-- - Authentication: which auth scheme? Which roles can access? -->
<!-- - Rate limit: if different from global default -->
<!-- - Idempotency: how is this endpoint made safely retryable? -->
<!-- - Example request and response -->
<!-- Example sub-sections: ### POST /users, ### GET /users/:id, ### PATCH /users/:id -->

## Data Model & Schema
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- List each entity as a ### sub-section. For each: -->
<!-- - Table/collection name -->
<!-- - Fields: name, type, constraints (NOT NULL, UNIQUE, DEFAULT, CHECK) -->
<!-- - Indexes: which columns, covering indexes, partial indexes -->
<!-- - Relationships: foreign keys, join tables, denormalized fields -->
<!-- - Soft delete strategy: deleted_at timestamp, is_deleted flag, or hard delete? -->
<!-- Migration strategy: how are schema changes applied? (Prisma migrate, Alembic, Flyway) -->
<!-- What is the primary key strategy? (auto-increment, UUID v4, ULID, CUID) -->
<!-- What fields are system-managed vs user-provided? (created_at, updated_at, version) -->

## Authentication & Authorization
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- Authentication methods: API key, JWT, OAuth2, mTLS, or combination? -->
<!-- Token format: JWT claims, API key format, session ID structure -->
<!-- Token lifecycle: issuance, validation, refresh, revocation -->
<!-- Authorization model: RBAC, ABAC, resource ownership, or custom? -->
<!-- Permission checks: where in the request pipeline? Middleware or per-handler? -->
<!-- Service-to-service auth: how do internal services authenticate? -->
<!-- What happens on: expired token, revoked token, insufficient permissions? -->
<!-- Audit trail: are auth decisions logged? What is captured? -->

## Error Handling & Response Format
<!-- PHASE:2 -->
<!-- Standard error response structure: -->
<!-- ```json -->
<!-- { "error": { "code": "VALIDATION_ERROR", "message": "...", "details": [...] } } -->
<!-- ``` -->
<!-- Error codes: list all application-specific error codes and their HTTP status -->
<!-- Validation errors: how are multiple field errors returned? -->
<!-- What information is NEVER exposed? (stack traces, SQL queries, internal paths) -->
<!-- Retry guidance: which errors are retryable? Retry-After header? -->
<!-- Error monitoring: how are errors aggregated and alerted on? -->

## Rate Limiting & Throttling
<!-- PHASE:2 -->
<!-- Rate limit strategy: fixed window, sliding window, token bucket, or leaky bucket? -->
<!-- Limits: per client, per IP, per endpoint, or global? Default limits? -->
<!-- Headers: X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset -->
<!-- What happens when limit is exceeded? (429 status, response body, Retry-After) -->
<!-- Rate limit storage: Redis, in-memory, or distributed? -->
<!-- Different tiers: free vs paid API keys with different limits? -->

## Pagination, Filtering & Sorting
<!-- PHASE:2 -->
<!-- Pagination style: cursor-based, offset-based, or keyset? Why? -->
<!-- Default and maximum page sizes -->
<!-- Cursor format: opaque token, or structured (e.g., base64-encoded ID)? -->
<!-- Filtering: query parameter patterns (e.g., ?status=active&created_after=2024-01-01) -->
<!-- Sorting: query parameter pattern (e.g., ?sort=created_at:desc) -->
<!-- What happens with invalid filter/sort values? -->

## Background Jobs & Async Processing
<!-- PHASE:2 -->
<!-- What work happens outside the request/response cycle? -->
<!-- Job queue: BullMQ, Celery, SQS, Sidekiq, or custom? -->
<!-- Job types: list each background job with trigger, frequency, and timeout -->
<!-- Retry policy: max retries, backoff strategy, dead letter queue -->
<!-- Scheduled jobs: cron-style tasks (cleanup, reports, sync) -->
<!-- How are long-running requests handled? (webhooks, polling, SSE) -->

## Caching Strategy
<!-- PHASE:2 -->
<!-- What data is cached? At what layer? (application, CDN, database query cache) -->
<!-- Cache keys: naming pattern, versioning, TTL per key type -->
<!-- Invalidation: event-driven, TTL-based, or manual purge? -->
<!-- Cache warming: is the cache pre-populated on deploy? -->
<!-- What happens on cache miss? Cold start performance? -->
<!-- Cache storage: Redis, Memcached, in-memory (per-instance), or CDN? -->

## External Dependencies & Integrations
<!-- PHASE:2 -->
<!-- Other services this API calls: list each with purpose, latency expectation, failure behavior -->
<!-- Third-party APIs: payment, email, SMS, storage, auth providers -->
<!-- Circuit breaker: which calls use circuit breakers? Thresholds? -->
<!-- Timeout policy: per-dependency timeout values -->
<!-- Fallback behavior: what happens when a dependency is down? -->
<!-- Webhook delivery: outbound webhooks? Retry policy, signature verification? -->

## Observability & Monitoring
<!-- PHASE:2 -->
<!-- Logging: structured (JSON), log levels, what gets logged per request -->
<!-- Metrics: latency histograms, error rate, throughput, queue depth, DB pool usage -->
<!-- Tracing: distributed tracing (OpenTelemetry)? Trace ID propagation? -->
<!-- Health checks: /health and /ready endpoints — what do they verify? -->
<!-- Alerting: what triggers alerts? Thresholds? Notification channels? -->
<!-- Dashboards: what does the primary operational dashboard show? -->

## Deployment & Infrastructure
<!-- PHASE:2 -->
<!-- Deployment: Docker, Kubernetes, serverless, or VM-based? -->
<!-- CI/CD pipeline: build → test → lint → deploy stages -->
<!-- Environments: local, staging, production — how do they differ? -->
<!-- Zero-downtime deployment: rolling update, blue-green, or canary? -->
<!-- Database migrations: applied during deploy? Before or after code deploy? -->
<!-- Secrets management: Vault, AWS Secrets Manager, env vars, or .env files? -->
<!-- Infrastructure as code: Terraform, Pulumi, CDK, or manual? -->

## Security
<!-- PHASE:2 -->
<!-- Input validation: where and how? (schema validation, parameterized queries) -->
<!-- CORS policy: allowed origins, methods, headers -->
<!-- Content Security Policy: applicable headers for API responses -->
<!-- SQL injection prevention: parameterized queries, ORM usage -->
<!-- Dependency scanning: automated vulnerability scanning in CI? -->
<!-- Penetration testing: planned? Frequency? -->
<!-- Secrets rotation: how often? Automated or manual? -->

## Config Architecture
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- What values MUST live in config/environment rather than hardcoded? -->
<!-- Config format: environment variables, .env files, config service? -->
<!-- Show example config with actual keys and default values: -->
<!-- ```env -->
<!-- DATABASE_URL=postgresql://localhost:5432/myservice -->
<!-- REDIS_URL=redis://localhost:6379 -->
<!-- JWT_SECRET=<random-256-bit> -->
<!-- JWT_EXPIRY_SECONDS=3600 -->
<!-- RATE_LIMIT_PER_MINUTE=100 -->
<!-- LOG_LEVEL=info -->
<!-- CORS_ALLOWED_ORIGINS=http://localhost:3000 -->
<!-- ``` -->
<!-- What is the config override hierarchy? -->
<!-- What config changes require a restart vs are hot-reloaded? -->

## Documentation Strategy
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- What documentation does this project ship? (README only, README + docs/ site, API reference) -->
<!-- Where is documentation hosted? (GitHub, GitHub Pages, ReadTheDocs, Swagger UI) -->
<!-- What surfaces must be documented? (REST/gRPC endpoints, auth flows, error codes, config keys) -->
<!-- On every feature change, which docs must be updated in the same commit? -->
<!-- Is doc freshness strict (block the merge) or warn-only? -->
<!-- Any auto-generation tooling? (OpenAPI/Swagger, protoc-gen-doc, Redoc) -->

## Testing Strategy
<!-- PHASE:3 -->
<!-- Unit tests: business logic, validators, utility functions -->
<!-- Integration tests: database operations, API endpoints end-to-end -->
<!-- Contract tests: consumer-driven contracts (Pact) or schema validation? -->
<!-- Load tests: tool (k6, Artillery, locust), target metrics, when to run -->
<!-- Test data: fixtures, factories, database seeding? -->
<!-- CI integration: test matrix, parallelization, what blocks deploy? -->

## Naming Conventions
<!-- PHASE:3 -->
<!-- Code naming: per-language conventions -->
<!-- API naming: endpoint paths, query params, response fields -->
<!-- Database naming: table and column naming (snake_case, plural?) -->
<!-- Environment variables: SERVICE_UPPER_SNAKE prefix? -->
<!-- Error codes: UPPER_SNAKE with category prefix? (AUTH_TOKEN_EXPIRED, VALIDATION_FIELD_REQUIRED) -->
<!-- What domain terms map to what code concepts? -->

## Open Design Questions
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- What decisions are you deliberately deferring? -->
<!-- What needs load testing or user data before you can decide? -->
<!-- Example: "Unsure if we need event sourcing or simple CRUD is sufficient" -->
<!-- Example: "Cache strategy TBD — measure actual DB load first" -->
<!-- List each open question with the information needed to resolve it. -->

## What Not to Build Yet
<!-- PHASE:3 -->
<!-- What features are explicitly deferred? -->
<!-- For each: what it is, why it's deferred, what milestone might add it -->
<!-- Example: "GraphQL API — REST first, evaluate GraphQL need based on client patterns" -->
<!-- Example: "Multi-region deployment — single region until traffic justifies the complexity" -->
