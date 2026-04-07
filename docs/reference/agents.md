# Agent Roles

Each pipeline stage uses a specialized AI agent. The agent's behavior is defined
by a role file in `.claude/agents/`.

## Default Agents

| Agent | Role File | Purpose |
|-------|-----------|---------|
| Intake | `.claude/agents/intake.md` | Task evaluation and scoping |
| Scout | *(built-in)* | Codebase analysis and effort estimation |
| Coder | `.claude/agents/coder.md` | Implementation |
| Security | `.claude/agents/security.md` | Vulnerability review |
| Reviewer | `.claude/agents/reviewer.md` | Code quality review |
| Tester | `.claude/agents/tester.md` | Test writing and validation |
| Junior Coder | `.claude/agents/jr-coder.md` | Simple fixes and rework |
| Architect | `.claude/agents/architect.md` | Architecture audit and drift resolution |

## Customizing Agent Roles

Role files are Markdown documents that define:

- **Personality** — How the agent approaches its work
- **Rules** — What the agent must and must not do
- **Output format** — The structure of the agent's report

### Example: Customizing the Reviewer

To make the reviewer stricter about test coverage:

```markdown
# Agent Role: Reviewer

You are a strict code reviewer. You MUST flag any code change that:
- Adds functionality without corresponding tests
- Reduces existing test coverage
- Skips error handling for external calls

## Verdict Criteria
- APPROVED: All acceptance criteria met AND tests cover new code paths
- CHANGES_REQUIRED: Any of the above rules violated
```

### Tips for Good Role Definitions

1. **Be specific about output format.** Agents follow the format you specify.
   If you want structured sections, define them explicitly.
2. **State non-negotiable rules clearly.** Use "MUST", "NEVER", "ALWAYS" for
   hard rules.
3. **Keep it focused.** Each agent has one job. Don't ask the reviewer to also
   write tests.
4. **Include examples** of what good output looks like.

## How Agents Interact

Agents don't talk to each other directly. The pipeline shell orchestrates the flow:

1. Each agent writes a report file (e.g., `REVIEWER_REPORT.md`)
2. The shell reads the report and makes routing decisions
3. The next agent receives relevant context from prior reports

This means agents are independently replaceable — you can change one role file
without affecting the others.

## Model Selection

Each agent can use a different Claude model. In general:

- **Opus** — Best for complex reasoning (planning, architecture)
- **Sonnet** — Good balance of speed and quality (coding, reviewing)
- **Haiku** — Fast for simple tasks (junior coder, quick fixes)

Configure per-agent models in `pipeline.conf`:

```bash
CLAUDE_CODER_MODEL="claude-sonnet-4-6"
CLAUDE_REVIEWER_MODEL="claude-sonnet-4-6"
CLAUDE_TESTER_MODEL="claude-sonnet-4-6"
```

## What's Next?

- [Pipeline Stages](stages.md) — What each stage does
- [Configuration Reference](configuration.md) — All agent config keys
- [Template Variables](template-variables.md) — Variables available in prompts
