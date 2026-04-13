# Context Management

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.

The pipeline tracks how much context is injected into each agent call and enforces
a configurable budget to prevent context window overflow:

- `CONTEXT_BUDGET_PCT=50` — max percentage of the model's context window to use
- `CONTEXT_COMPILER_ENABLED=true` — task-scoped context assembly, injecting only
  relevant sections of large artifacts instead of full files

When context exceeds the budget, compression strategies are applied in priority order:
prior tester context -> non-blocking notes -> prior progress context. A note is injected
when compression occurs so agents are aware of the reduction.

## Clarification Protocol

Agents can surface blocking questions mid-run. The pipeline pauses, prompts you for
an answer, and resumes with the clarification injected into subsequent agent prompts:

```
+-------------------------------------+
| CLARIFICATION REQUIRED              |
|                                     |
| [BLOCKING] Should the API use JWT   |
| or session-based auth?              |
+-------------------------------------+
Your answer:
```

Non-blocking clarifications are logged without pausing. Disable with
`CLARIFICATION_ENABLED=false`.
