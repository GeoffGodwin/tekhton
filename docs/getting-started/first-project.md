# Your First Project

This guide walks you through setting up Tekhton in a project directory for the
first time.

## Initialize Your Project

Navigate to your project's root directory and run:

```bash
cd /path/to/your-project
tekhton --init
```

Tekhton scans your project, detects your tech stack, and creates the configuration
files it needs.

## What `--init` Creates

After initialization, you'll find these new files in your project:

```
your-project/
├── .claude/
│   ├── pipeline.conf          # Pipeline configuration
│   ├── agents/                # Agent role definitions
│   │   ├── coder.md           # Senior coder personality and rules
│   │   ├── reviewer.md        # Code reviewer personality and rules
│   │   ├── tester.md          # Test writer personality and rules
│   │   ├── jr-coder.md        # Junior coder for simple fixes
│   │   ├── architect.md       # Architecture auditor
│   │   ├── security.md        # Security reviewer
│   │   └── intake.md          # Task intake / PM agent
│   ├── dashboard/             # Watchtower dashboard (browser-based UI)
│   │   ├── index.html
│   │   ├── style.css
│   │   └── app.js
│   └── milestones/            # Milestone files (if using milestone mode)
├── CLAUDE.md                  # Project rules and milestone plan
└── HUMAN_NOTES.md             # Your notes for the next pipeline run
```

### Key Files

**`.claude/pipeline.conf`** — This is the main configuration file. Tekhton
auto-detects your build command, test command, language, and framework. Review
the detected values and correct anything that looks wrong.

```bash
# Example pipeline.conf (auto-detected for a Node.js project)
PROJECT_NAME="my-app"
TEST_CMD="npm test"
BUILD_CHECK_CMD="npm run build"
ANALYZE_CMD="npx eslint src/"
```

**`CLAUDE.md`** — Project rules, architecture guidelines, and milestone definitions.
This is the "brain" of your project as far as Tekhton is concerned. The more detail
you put here, the better the agents perform.

**`.claude/agents/*.md`** — Each agent has a role file defining its personality,
rules, and output format. The defaults work well, but you can customize these to
match your team's standards.

## Review the Configuration

Open `.claude/pipeline.conf` and verify:

1. **`TEST_CMD`** — Does this actually run your tests? If you don't have tests yet,
   leave it as `true` (the default no-op).
2. **`BUILD_CHECK_CMD`** — Does this compile/build your project? Leave empty if
   your project doesn't have a build step.
3. **`ANALYZE_CMD`** — Your linter command. Leave empty if you don't use a linter.

## Run Your First Task

Pick something small for your first run — a simple feature or a bug fix:

```bash
tekhton "Add a /health endpoint that returns { status: 'ok' }"
```

Tekhton will:

1. **Intake** — Evaluate your task for clarity and scope
2. **Scout** — Scan the codebase to understand the project structure
3. **Code** — Implement the feature
4. **Security Review** — Check for vulnerabilities
5. **Code Review** — Review the implementation for quality
6. **Test** — Write tests for the new code
7. **Commit** — Offer to create a commit with a descriptive message

## Open the Watchtower

If the Watchtower dashboard was created during init, you can view your project's
status in a browser:

```bash
open .claude/dashboard/index.html        # macOS
xdg-open .claude/dashboard/index.html    # Linux
```

The dashboard shows pipeline progress, run history, milestone status, and health
scores.

## What's Next?

- [Your First Milestone](first-milestone.md) — Learn how to break large work
  into milestones
- [Understanding Output](understanding-output.md) — Learn to read the reports
  Tekhton generates
- [Configuration Reference](../reference/configuration.md) — All config options
  explained
