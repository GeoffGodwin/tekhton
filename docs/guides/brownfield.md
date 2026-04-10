# Brownfield Projects

Tekhton works with existing codebases, not just new projects. Here's how to set
it up in a repo that already has code.

## Initialize in an Existing Project

```bash
cd /path/to/existing-project
tekhton --init
```

### What `--init` Does Differently

When Tekhton detects an existing codebase, initialization includes extra steps:

1. **Tech stack detection** — Identifies languages, frameworks, build tools, and
   test commands from your project files
2. **Workspace detection** — Finds monorepo workspaces, service boundaries, and
   sub-projects
3. **CI/CD detection** — Reads existing CI configuration (GitHub Actions, GitLab CI,
   etc.)
4. **AI artifact detection** — Finds existing AI-generated configuration files
   (`.cursorrules`, `.github/copilot-instructions.md`, etc.) and offers to
   archive or merge them
5. **Project crawl** — Indexes the codebase into `.claude/index/` (structured data:
   file inventory, dependency graph, config list, test infrastructure, content samples)
   and generates a human-readable `PROJECT_INDEX.md` summary. Used by subsequent
   pipeline stages for context-aware operations.
6. **Health baseline** — Runs an initial health assessment to establish a baseline
   score

### AI Artifact Handling

If Tekhton finds existing AI configuration files, it asks how to handle them:

- **Archive** — Move them to `.claude/archived-ai-config/` (preserves them but
  keeps your project clean)
- **Tidy** — Merge useful content into `CLAUDE.md` and archive the originals
- **Ignore** — Leave them in place

## Review Auto-Detected Configuration

Open `.claude/pipeline.conf` and verify the detected values:

```bash
# Auto-detected values — verify these are correct
PROJECT_NAME="my-existing-app"
TEST_CMD="npm test"                    # Is this right?
BUILD_CHECK_CMD="npm run build"        # Is this right?
ANALYZE_CMD="npx eslint src/"          # Is this right?
```

Pay special attention to:

- **`TEST_CMD`** — If detection got this wrong, tests won't run during the
  pipeline
- **`BUILD_CHECK_CMD`** — If this fails, the build gate blocks the pipeline
- **`ANALYZE_CMD`** — Your linter. Leave empty if you don't have one.

!!! tip "Low-Confidence Detections"
    Values marked with `# VERIFY` in `pipeline.conf` are low-confidence
    detections. Always check these.

## Health Baseline

After init, check your project's health score:

```bash
tekhton --health
```

This produces `HEALTH_REPORT.md` with scores across five categories:

| Category | What It Measures |
|----------|-----------------|
| Tests | Test coverage and test command availability |
| Quality | Linter configuration and code patterns |
| Dependencies | Dependency freshness and known vulnerabilities |
| Documentation | README, inline docs, architecture docs |
| Hygiene | Git hygiene, file organization, configuration |

The baseline score is saved so future runs can show improvement.

## Running Tasks

Once configured, run tasks the same way as a greenfield project:

```bash
tekhton "Fix the race condition in the session middleware"
```

Or use `--plan` to create a milestone plan for a larger initiative:

```bash
tekhton --plan
```

## What's Next?

- [Monorepo Setup](monorepo.md) — Additional setup for monorepos
- [Configuration Reference](../reference/configuration.md) — All config options
- [Health Scoring](../concepts/health-scoring.md) — How health scores work
