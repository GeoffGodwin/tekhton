# Design Document

<!-- Generated from sections below -->

## Developer Philosophy & Constraints
<!-- REQUIRED -->
<!-- What are your non-negotiable architectural rules? Examples: -->
<!-- - What design patterns must be followed? (composition over inheritance, etc.) -->
<!-- - What coding standards are mandatory? (type safety, error handling, testing) -->
<!-- - What anti-patterns are banned? -->
<!-- - What principles guide trade-off decisions? (simplicity vs performance, etc.) -->
<!-- These constraints apply to every contributor from day one. -->

## Project Overview
<!-- REQUIRED -->
<!-- What are you building? Who is it for? What problem does it solve? -->
<!-- Is this greenfield, a rewrite, or an extension of an existing system? -->
<!-- What is the expected scale? (users, data volume, request rate) -->
<!-- What existing tools or systems does this replace or integrate with? -->

## Tech Stack
<!-- REQUIRED -->
<!-- Language(s) and why -->
<!-- Framework(s) and why -->
<!-- Key dependencies and why -->
<!-- Build tool and package manager -->
<!-- Testing framework -->
<!-- Deployment target (cloud, on-prem, desktop, embedded, etc.) -->

## Architecture Overview
<!-- REQUIRED -->
<!-- How is the system structured at a high level? -->
<!-- What are the main components/modules and their responsibilities? -->
<!-- How do components communicate? (function calls, events, messages, RPC) -->
<!-- What are the system boundaries? (process, network, trust) -->
<!-- Include a component diagram description or ASCII diagram. -->
<!-- What architectural pattern? (layered, hexagonal, event-driven, microservices, monolith) -->

## Core Features & Systems
<!-- REQUIRED -->
<!-- List each major feature or system as a ### sub-section. For each: -->
<!-- - Description: what it does from the user's/consumer's perspective -->
<!-- - Behavior: step-by-step processing or interaction flow -->
<!-- - Edge cases: what happens at boundaries? Invalid input? Missing data? -->
<!-- - Dependencies: what other systems does this interact with? -->
<!-- - Configurable values: what should be tunable? -->

## Data Model
<!-- REQUIRED -->
<!-- What data does the system manage? For each entity or data structure: -->
<!-- - Fields/properties with types -->
<!-- - Relationships to other entities -->
<!-- - Constraints: uniqueness, required fields, valid ranges -->
<!-- - Storage: where and how is this data persisted? -->
<!-- - Lifecycle: how is data created, updated, and deleted? -->

## Key User/Consumer Flows
<!-- Walk through 2-4 critical paths step by step. -->
<!-- For each flow: starting state, actions, system response, outcomes -->
<!-- Include both happy path and key failure cases. -->

## Error Handling Strategy
<!-- How does the system report and handle errors? -->
<!-- Error categories: user errors, system errors, transient failures -->
<!-- Error propagation: how do errors flow between components? -->
<!-- Recovery: automatic retry, manual intervention, or fail-fast? -->
<!-- What errors should the user/consumer never see raw? -->

## External Integrations
<!-- Third-party services, APIs, or systems this project interacts with -->
<!-- For each: what it does, failure behavior, authentication method -->
<!-- What happens if an external dependency is down? -->

## Security Considerations
<!-- Authentication and authorization approach -->
<!-- Input validation strategy -->
<!-- Sensitive data handling (encryption, masking, retention) -->
<!-- Known attack vectors and mitigations relevant to this system -->

## Config Architecture
<!-- REQUIRED -->
<!-- What values MUST live in config rather than hardcoded? -->
<!-- Config format: environment variables, files, remote config? -->
<!-- Show example config with actual keys and default values -->
<!-- What is the config override hierarchy? -->
<!-- What changes require restart vs are hot-reloaded? -->

## Performance & Scalability
<!-- Performance targets: latency, throughput, resource usage -->
<!-- Bottleneck analysis: what are the expected hot spots? -->
<!-- Scaling strategy: horizontal, vertical, or both? -->
<!-- Resource budgets: memory, CPU, storage, network -->

## Testing Strategy
<!-- What gets tested? Unit, integration, E2E, property-based? -->
<!-- Test data: fixtures, factories, generated? -->
<!-- Coverage targets and what is NOT worth testing -->
<!-- CI integration: what runs on every PR? What blocks merge? -->

## Naming Conventions
<!-- Code naming per-language conventions -->
<!-- File and directory naming patterns -->
<!-- Domain vocabulary: what business/domain terms map to what code concepts? -->

## Open Design Questions
<!-- REQUIRED -->
<!-- What decisions are you deliberately deferring? Why? -->
<!-- What needs more data or experimentation before you can decide? -->
<!-- List each open question with the information needed to resolve it. -->

## What Not to Build Yet
<!-- What features are explicitly deferred to avoid scope creep? -->
<!-- For each: what it is, why it's deferred, what milestone might add it -->
