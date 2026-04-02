# Express Mode

Express mode lets you use Tekhton without any project configuration. When no
`pipeline.conf` exists, Tekhton auto-detects your tech stack and runs with
sensible defaults.

## When to Use Express Mode

- Quick one-off tasks on a project you haven't configured for Tekhton
- Trying Tekhton for the first time without committing to full setup
- Small fixes where full pipeline configuration isn't worth the overhead

## How It Works

When you run Tekhton in a directory without `.claude/pipeline.conf`, it:

1. Detects your programming language(s) from manifest files and source extensions
2. Identifies your framework from dependency declarations
3. Infers build, test, and lint commands from your tooling
4. Creates a temporary in-memory configuration and runs the pipeline

```bash
cd /path/to/any/project
tekhton "Fix the login redirect bug"
# No --init, no pipeline.conf needed
```

## Express vs Full Pipeline

| Aspect | Express Mode | Full Pipeline |
|--------|-------------|---------------|
| Configuration | Auto-detected | `.claude/pipeline.conf` |
| Agent roles | Default templates | Customizable per project |
| Milestones | Not available | Full DAG support |
| Dashboard | Not available | Watchtower with history |
| Persistence | Minimal | Full state, metrics, history |
| Best for | Quick tasks | Ongoing project work |

## Disabling Express Mode

If you don't want Tekhton to auto-detect when `pipeline.conf` is missing:

```bash
export TEKHTON_EXPRESS_ENABLED=false
```

With this set, Tekhton will show an error and prompt you to run `--init` instead.

## Moving to Full Configuration

When you're ready for the full pipeline experience:

```bash
tekhton --init
```

This runs the smart init process: detects your stack, generates `pipeline.conf`
with accurate defaults, creates agent role files, and sets up the Watchtower
dashboard.

## What's Next?

- [Your First Project](../getting-started/first-project.md) — Full project setup
- [Configuration Reference](../reference/configuration.md) — All config options
- [Brownfield Projects](brownfield.md) — Initializing existing codebases
