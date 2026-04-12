# Design Document — Web Application

<!-- Generated from sections below -->

## Developer Philosophy & Constraints
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What are your non-negotiable architectural rules? Examples: -->
<!-- - Server-side first: prefer SSR/SSG over client-side rendering where possible -->
<!-- - Type safety end-to-end: shared types between API and frontend, no `any` -->
<!-- - Convention over configuration: follow framework defaults unless there's a measured reason not to -->
<!-- - Accessibility-first: every component must be keyboard-navigable and screen-reader compatible -->
<!-- - Infrastructure as code: all deployment config is version-controlled, no manual setup -->
<!-- What patterns must every contributor follow from day one? What anti-patterns are banned? -->

## Project Overview
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What does this application do? Who is it for? What problem does it solve? -->
<!-- Is this a greenfield build or a rewrite/migration? -->
<!-- What is the business model? (SaaS, internal tool, marketplace, content platform) -->
<!-- What existing tools or manual processes does this replace? -->
<!-- What is the expected user base size at launch? At scale? -->

## Tech Stack
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Frontend framework: React, Next.js, Vue, Nuxt, Svelte, Angular? Why? -->
<!-- Backend framework: Express, Fastify, Django, Rails, .NET, Go? Why? -->
<!-- Database: PostgreSQL, MySQL, MongoDB, SQLite? Why? -->
<!-- ORM/query builder: Prisma, Drizzle, TypeORM, SQLAlchemy, ActiveRecord? -->
<!-- Hosting/deployment: Vercel, AWS, GCP, Railway, Docker, bare metal? -->
<!-- CSS approach: Tailwind, CSS Modules, styled-components, vanilla CSS? -->
<!-- Package manager: npm, pnpm, yarn? Monorepo tool (Turborepo, Nx)? -->
<!-- Testing: Vitest/Jest for unit, Playwright/Cypress for E2E? -->

## User Roles & Permissions
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Who uses this system? List each role. -->
<!-- For each role: what can they see? What can they create/edit/delete? -->
<!-- How are roles assigned? (self-registration, admin invitation, org-based) -->
<!-- Are permissions role-based (RBAC) or attribute-based (ABAC)? -->
<!-- What is the permission escalation path? (member → admin → super-admin) -->
<!-- What actions require explicit permission checks vs. implicit from role? -->
<!-- Edge cases: what happens when a user's role changes mid-session? -->

## Data Model & Entities
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- List each major entity as a ### sub-section. For each entity: -->
<!-- - Key fields with types (string, integer, enum, UUID, timestamp) -->
<!-- - Relationships to other entities (one-to-many, many-to-many, belongs-to) -->
<!-- - Constraints: uniqueness, required fields, default values, soft-delete -->
<!-- - Indexes needed for query performance -->
<!-- - What is the primary key strategy? (auto-increment, UUID, ULID, CUID) -->
<!-- Example sub-sections: ### User, ### Organization, ### Project, ### Invoice -->
<!-- Include an entity relationship summary: "User belongs-to Organization, Project belongs-to User" -->

## Core Features
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- List each major feature as a ### sub-section. For each feature: -->
<!-- - User story: "As a [role], I want to [action] so that [benefit]" -->
<!-- - Behavior: step-by-step description of what happens -->
<!-- - Edge cases: what happens when input is invalid, network fails, or data is missing? -->
<!-- - Dependencies: what other features or entities does this depend on? -->
<!-- - Configurable values: what should be tunable? (limits, thresholds, feature flags) -->

## Key User Flows
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- Walk through 3-5 critical paths step by step. For each flow: -->
<!-- - Starting state: what does the user see? -->
<!-- - Actions: what does the user click/type/do? -->
<!-- - System response: what happens in the backend? What does the UI show? -->
<!-- - Happy path AND failure cases -->
<!-- Example: "Sign up → verify email → create first project → invite team member" -->
<!-- Example: "Search for item → add to cart → checkout → payment → confirmation" -->

## Pages, Routes & Navigation
<!-- PHASE:2 -->
<!-- List every page/route in the application. Group by area: -->
<!-- - Public pages (landing, pricing, docs, login, signup) -->
<!-- - Authenticated pages (dashboard, settings, profile) -->
<!-- - Admin pages (user management, analytics, config) -->
<!-- For each page: URL pattern, what data it needs, who can access it -->
<!-- Navigation structure: sidebar, top nav, breadcrumbs, tabs? -->
<!-- How does the URL structure support deep linking and bookmarking? -->

## Authentication & Session Management
<!-- PHASE:2 -->
<!-- How do users log in? (email/password, OAuth providers, magic link, SSO, passkeys) -->
<!-- Session strategy: JWT, server-side sessions, or hybrid? -->
<!-- Token storage: httpOnly cookie, localStorage, or in-memory? -->
<!-- Session lifetime: how long until expiry? Refresh token strategy? -->
<!-- Multi-device: can users be logged in on multiple devices? -->
<!-- Account recovery: password reset flow, account lockout policy? -->
<!-- MFA: is it supported? Required for certain roles? -->

## API Design
<!-- PHASE:2 -->
<!-- API style: REST, GraphQL, tRPC, or hybrid? -->
<!-- Naming conventions: `/api/v1/users`, camelCase vs snake_case in payloads -->
<!-- Pagination: cursor-based, offset-based, or keyset? Default page size? -->
<!-- Filtering and sorting: query parameter patterns -->
<!-- Rate limiting: per-user, per-IP, per-endpoint? Limits and headers? -->
<!-- Versioning strategy: URL path, header, or query parameter? -->
<!-- Error response format: standard structure with error codes? -->

## State Management
<!-- PHASE:2 -->
<!-- Frontend state strategy: server state (React Query, SWR) vs client state (Zustand, Redux) -->
<!-- What data is cached client-side? Cache invalidation strategy? -->
<!-- Optimistic updates: which actions use them? Rollback on failure? -->
<!-- URL state: what filters/views are reflected in the URL? -->
<!-- Form state: controlled vs uncontrolled? Validation library? (Zod, Yup, native) -->

## Error Handling & Resilience
<!-- PHASE:2 -->
<!-- Frontend error handling: error boundaries, toast notifications, inline errors -->
<!-- Backend error handling: structured error responses, error codes, logging -->
<!-- What happens when the API is down? Retry strategy? Offline support? -->
<!-- Validation: where is input validated? (client, server, or both) -->
<!-- What errors should the user never see? (500s, stack traces, raw DB errors) -->
<!-- Monitoring: how are errors tracked? (Sentry, LogRocket, CloudWatch) -->

## External Integrations
<!-- PHASE:2 -->
<!-- Third-party APIs: payment (Stripe, PayPal), email (SendGrid, Resend), -->
<!-- storage (S3, Cloudflare R2), auth (Auth0, Clerk), analytics (PostHog, Mixpanel) -->
<!-- For each integration: what it does, API key management, failure behavior -->
<!-- Webhook handling: inbound webhooks from third parties? Validation and retry? -->
<!-- What happens if a third-party service is down? Graceful degradation? -->

## Background Jobs & Async Processing
<!-- PHASE:2 -->
<!-- What work happens outside the request/response cycle? -->
<!-- Job queue: BullMQ, Celery, SQS, or cron-based? -->
<!-- Examples: email sending, report generation, data imports, cleanup tasks -->
<!-- Retry strategy: how many retries? Exponential backoff? Dead letter queue? -->
<!-- Scheduled jobs: what runs on a schedule? (daily reports, expired session cleanup) -->

## Observability & Monitoring
<!-- PHASE:2 -->
<!-- Logging: structured (JSON) or plain text? Log levels? What gets logged? -->
<!-- Metrics: request latency, error rate, active users, queue depth -->
<!-- Alerting: what triggers an alert? Who gets notified? (PagerDuty, Slack, email) -->
<!-- Health checks: what does the /health endpoint verify? -->
<!-- Tracing: distributed tracing for request flow? (OpenTelemetry, Datadog) -->

## Deployment & Infrastructure
<!-- PHASE:2 -->
<!-- Deployment target: Vercel, AWS, GCP, Railway, Docker, Kubernetes? -->
<!-- CI/CD: GitHub Actions, GitLab CI, CircleCI? Pipeline stages? -->
<!-- Environments: local, staging, production? How do they differ? -->
<!-- Database migrations: tool and strategy (up/down, forward-only) -->
<!-- Secrets management: how are API keys and credentials handled? -->
<!-- CDN: static assets served from CDN? Which one? -->

## Config Architecture
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- What values MUST live in config/environment rather than hardcoded? -->
<!-- Config sources: .env files, environment variables, config service, feature flags -->
<!-- Show example config structures with actual keys and default values. Example: -->
<!-- ```env -->
<!-- DATABASE_URL=postgresql://localhost:5432/myapp -->
<!-- SESSION_SECRET=<random-string> -->
<!-- SMTP_HOST=smtp.sendgrid.net -->
<!-- FEATURE_FLAG_NEW_DASHBOARD=false -->
<!-- RATE_LIMIT_PER_MINUTE=60 -->
<!-- MAX_UPLOAD_SIZE_MB=10 -->
<!-- ``` -->
<!-- What is the config hierarchy? (defaults → .env → environment → runtime) -->
<!-- How are feature flags managed? (config file, LaunchDarkly, database) -->
<!-- What config changes require a restart vs. are hot-reloaded? -->

## Documentation Strategy
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- What documentation does this project ship? (README only, README + docs/ site, API reference) -->
<!-- Where is documentation hosted? (GitHub, GitHub Pages, ReadTheDocs, Storybook) -->
<!-- What surfaces must be documented? (REST endpoints, UI routes, config keys, environment variables) -->
<!-- On every feature change, which docs must be updated in the same commit? -->
<!-- Is doc freshness strict (block the merge) or warn-only? -->
<!-- Any auto-generation tooling? (typedoc, Storybook, OpenAPI/Swagger) -->

## Testing Strategy
<!-- PHASE:3 -->
<!-- Unit tests: what gets unit tested? (business logic, utilities, validators) -->
<!-- Integration tests: API endpoint tests, database tests? -->
<!-- E2E tests: which user flows have automated browser tests? -->
<!-- Test data: fixtures, factories, or seeded database? -->
<!-- Coverage targets: what percentage? What is NOT worth testing? -->
<!-- CI integration: do tests run on every PR? What blocks merge? -->

## Non-Functional Requirements
<!-- PHASE:3 -->
<!-- Performance: page load time targets, API response time targets -->
<!-- Accessibility: WCAG level (A, AA, AAA)? Audit plan? -->
<!-- Internationalization: multi-language support? RTL? Number/date formatting? -->
<!-- SEO: server-side rendering needs? Meta tags? Sitemap? -->
<!-- Security: OWASP top 10 mitigations, CSP headers, CORS policy -->
<!-- Data privacy: GDPR, CCPA, data retention policy, data export -->

## Naming Conventions
<!-- PHASE:3 -->
<!-- Code naming: camelCase, PascalCase, snake_case — per language convention -->
<!-- File naming: kebab-case for files, PascalCase for components? -->
<!-- Database naming: snake_case tables and columns? Plural or singular table names? -->
<!-- API naming: endpoint paths, query params, response field names -->
<!-- CSS naming: BEM, utility-first, or component-scoped? -->
<!-- Domain vocabulary: what business terms map to what code concepts? -->

## Open Design Questions
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- What decisions are you deliberately deferring? Why? -->
<!-- What needs user testing or data before you can decide? -->
<!-- What trade-offs have you identified but not resolved? -->
<!-- Example: "Unsure if we need real-time updates or polling is sufficient" -->
<!-- Example: "Multi-tenancy model TBD — single DB with tenant column vs separate schemas" -->
<!-- List each open question with the information needed to resolve it. -->

## What Not to Build Yet
<!-- PHASE:3 -->
<!-- What features are explicitly deferred to avoid scope creep? -->
<!-- For each deferred feature: what it is, why it's deferred, what milestone might add it -->
<!-- Example: "Admin analytics dashboard — deferred until we have real usage data" -->
<!-- Example: "Mobile app — web-first, evaluate native app need after launch" -->
