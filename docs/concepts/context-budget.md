# Context Budget

Claude has a finite context window. Tekhton manages how much of that window is
consumed by prompt content (project rules, architecture docs, milestone
definitions, repo maps) to leave room for the agent's actual work.

## How It Works

Before invoking an agent, Tekhton measures the total prompt size and checks it
against a configurable budget:

```
prompt_size_chars / CHARS_PER_TOKEN ≤ context_window * CONTEXT_BUDGET_PCT / 100
```

If the prompt exceeds the budget, Tekhton compresses or trims content to fit.

## Configuration

| Key | Default | Description |
|-----|---------|-------------|
| `CONTEXT_BUDGET_PCT` | `50` | Max % of context window for the prompt |
| `CONTEXT_BUDGET_ENABLED` | `true` | Toggle budget enforcement |
| `CHARS_PER_TOKEN` | `4` | Characters-per-token ratio (conservative) |

## What Gets Budgeted

Content is prioritized in this order (highest to lowest):

1. **Task description** — Always included in full
2. **Agent role definition** — Always included in full
3. **Active milestone** — Full content for the current milestone
4. **Project rules** — `CLAUDE.md` content
5. **Architecture documentation** — If configured
6. **Repo map** — Task-relevant file signatures (if indexer is enabled)
7. **Human notes** — If present
8. **Frontier milestones** — Summary of upcoming milestones
9. **Drift/history context** — Past observations and decisions

When the budget is tight, lower-priority items are trimmed or excluded.

## Milestone Window

The milestone sliding window has its own sub-budget:

```bash
MILESTONE_WINDOW_PCT=30            # 30% of the context budget goes to milestones
MILESTONE_WINDOW_MAX_CHARS=20000   # Hard cap regardless of budget %
```

This prevents large milestone plans from crowding out other context.

## Task-Scoped Context Assembly

When `CONTEXT_COMPILER_ENABLED=true`, Tekhton uses keyword-based section
filtering to include only the parts of your documentation that are relevant to
the current task. This is more aggressive than the default approach and can
significantly reduce prompt size for large projects.

## Repo Map Budget

The tree-sitter repo map (when `REPO_MAP_ENABLED=true`) has its own token budget:

```bash
REPO_MAP_TOKEN_BUDGET=2048    # Max tokens for repo map output
```

The repo map generator uses PageRank to prioritize files relevant to the current
task, then truncates to fit the budget.

## What's Next?

- [Pipeline Flow](pipeline-flow.md) — How stages use context
- [Configuration Reference](../reference/configuration.md) — All context config keys
