# Monorepo Setup

Tekhton can work with monorepo projects. Here's how to configure it for
multi-package or multi-service repositories.

## Detection

When you run `tekhton --init` in a monorepo, Tekhton automatically detects:

- **npm/yarn/pnpm workspaces** (from `package.json`)
- **Cargo workspaces** (from `Cargo.toml`)
- **Go modules** (from `go.work`)
- **Python namespace packages** (from `pyproject.toml` or `setup.cfg`)

The detected workspace structure is included in your project configuration.

## Configuration

Set the project structure type in `pipeline.conf`:

```bash
PROJECT_STRUCTURE="mono"     # Options: single, mono, multi
```

### Scoping Tasks

When working in a monorepo, be specific about which package or service your task
targets:

```bash
# Good — scoped to a specific package
tekhton "Add input validation to the @myapp/api package"

# Less ideal — ambiguous scope
tekhton "Add input validation"
```

The scout agent reads the full repo structure, but giving it a clear target
reduces wasted exploration time.

### Build and Test Commands

Configure build and test commands for the specific package you're working on:

```bash
TEST_CMD="cd packages/api && npm test"
BUILD_CHECK_CMD="cd packages/api && npm run build"
ANALYZE_CMD="cd packages/api && npx eslint src/"
```

!!! tip
    If your monorepo has a root-level test command that covers everything
    (e.g., `npm test` with workspaces), you can use that instead.

## Milestone Scoping

When creating milestones for a monorepo project, include the target package
or service in each milestone's description:

```markdown
#### Milestone 1: API Authentication (packages/api)
Add JWT authentication to the API service.

#### Milestone 2: Auth UI Components (packages/web)
Add login and registration forms to the web frontend.
```

## What's Next?

- [Configuration Reference](../reference/configuration.md) — All config options
- [Your First Milestone](../getting-started/first-milestone.md) — Running milestones
