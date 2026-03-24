# Tekhton

**One intent. Many hands.**

Tekhton is a multi-agent development pipeline built on the [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli).
You describe what you want built. Tekhton orchestrates a team of AI agents — scout,
coder, security reviewer, code reviewer, and tester — to implement it, review it,
and test it, with automatic rework when things don't pass muster.

Think of it as a senior engineering team that works from a single task description
and delivers reviewed, tested code.

## Quick Start

```bash
# 1. Clone Tekhton
git clone https://github.com/GeoffGodwin/tekhton.git ~/.tekhton

# 2. Add to PATH
echo 'export PATH="$HOME/.tekhton:$PATH"' >> ~/.bashrc && source ~/.bashrc

# 3. Set up your project
cd your-project
tekhton --init

# 4. Run your first task
tekhton "Add a health check endpoint to the API"
```

That's it. Tekhton reads your project configuration, scouts the codebase, writes
code, runs a security review, sends it through code review, fixes any issues, and
writes tests.

## What Tekhton Does

- **Scout** — Analyzes your codebase to understand what exists before writing anything
- **Code** — Implements your task with a senior-level AI agent
- **Security Review** — Checks for vulnerabilities (OWASP top 10, dependency issues, secrets)
- **Code Review** — A separate agent reviews the implementation for quality, correctness, and style
- **Rework** — If the reviewer finds issues, a coder agent fixes them automatically
- **Test** — Writes and runs tests for the new code
- **Commit** — Produces a clean commit with a descriptive message

## Who Is This For?

**Solo developers** who want the benefits of a code review process without a team.
You write a task, Tekhton delivers reviewed code.

**Small teams** who want to move faster. Use Tekhton for well-defined implementation
tasks and free your team for architecture, design, and the hard problems.

**People with ideas** who aren't senior engineers. If you can describe what you want
in plain language, Tekhton can implement it. You don't need to know the right
function names or framework patterns — the agents figure that out.

## Key Features

| Feature | What It Does |
|---------|-------------|
| **Milestone Mode** | Break large projects into milestones. Tekhton works through them one at a time with acceptance criteria. |
| **Security Agent** | Dedicated security review stage catches vulnerabilities before they ship. |
| **Watchtower Dashboard** | Browser-based dashboard shows pipeline progress, health scores, and run history. |
| **Health Scoring** | Automated project health assessment covering tests, quality, dependencies, and documentation. |
| **Resume Support** | Pipeline saves state on interruption. Re-run to pick up where you left off. |
| **Planning Phase** | Interactive `--plan` mode designs your project with a design doc and milestone plan before any code is written. |

## Next Steps

New to Tekhton? Start with the [Installation Guide](getting-started/installation.md).

Already installed? Jump to [Your First Project](getting-started/first-project.md).

Want to understand how it works under the hood? Read [Pipeline Flow](concepts/pipeline-flow.md).
