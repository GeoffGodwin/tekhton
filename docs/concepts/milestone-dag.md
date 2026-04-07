# Milestone DAG

Tekhton organizes milestones as a Directed Acyclic Graph (DAG) — milestones
can depend on other milestones, and Tekhton automatically determines which
milestone to work on next based on dependency satisfaction.

## File-Based Milestones

Milestones are stored as individual Markdown files in `.claude/milestones/`,
with a manifest file (`MANIFEST.cfg`) tracking their status and dependencies.

### MANIFEST.cfg Format

```
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|User Authentication|done||m01-user-auth.md|foundation
m02|Database Schema|done||m02-database.md|foundation
m03|API Endpoints|pending|m01,m02|m03-api-endpoints.md|core
m04|Frontend Forms|pending|m03|m04-frontend.md|ui
m05|Email Notifications|pending|m03|m05-email.md|services
```

Fields:

| Field | Description |
|-------|-------------|
| `id` | Unique identifier (e.g., `m01`) |
| `title` | Human-readable name |
| `status` | `pending`, `in_progress`, `done`, `failed` |
| `depends_on` | Comma-separated list of prerequisite milestone IDs |
| `file` | Milestone definition filename |
| `parallel_group` | Grouping for future parallel execution |

### Milestone File Format

Each milestone file is a Markdown document:

```markdown
#### Milestone 3: API Endpoints

Implement REST API endpoints for user management.

Acceptance criteria:
- GET /api/users returns paginated user list
- POST /api/users creates a new user
- PUT /api/users/:id updates user fields
- DELETE /api/users/:id soft-deletes a user
- All endpoints require authentication
- All existing tests pass

Watch For:
- Pagination must use cursor-based pagination, not offset
- Soft delete sets deleted_at timestamp, doesn't remove rows

Seeds Forward:
- Milestone 4 builds frontend forms against these endpoints
- Milestone 5 sends emails on user creation
```

## How the DAG Works

### Frontier Detection

When you run `tekhton --milestone`, Tekhton:

1. Loads the manifest
2. Finds all milestones whose dependencies are satisfied (all deps are `done`)
3. Picks the first one — this is the "frontier"

In the example above, if m01 and m02 are done, the frontier is `{m03}`. Once
m03 is done, the frontier becomes `{m04, m05}` (both depend only on m03).

### Dependency Validation

The manifest is validated at load time:

- **Missing references** — If a milestone depends on an ID that doesn't exist
- **Circular dependencies** — If A depends on B and B depends on A
- **Missing files** — If a milestone file referenced in the manifest doesn't exist

### Status Updates

When a milestone completes:

1. Status is set to `done` in `MANIFEST.cfg`
2. The milestone is archived to `MILESTONE_ARCHIVE.md`
3. If `MILESTONE_TAG_ON_COMPLETE` is `true`, a git tag is created

## Sliding Window

Not all milestones are injected into agent prompts — that would waste context.
Tekhton uses a sliding window that includes:

1. **Active milestone** — The one currently being worked on (full content)
2. **Frontier milestones** — Next up after the active one (summary only)
3. **On-deck milestones** — One level beyond the frontier (title only)

The window fits within `MILESTONE_WINDOW_MAX_CHARS` (default: 20,000 characters).

## Milestone Splitting

If the scout estimates that a milestone is too large for a single pipeline run:

1. A splitting agent breaks it into sub-milestones
2. Sub-milestones inherit the parent's dependencies
3. The manifest is updated atomically

Control splitting behavior:

```bash
MILESTONE_SPLIT_ENABLED=true           # Toggle splitting
MILESTONE_SPLIT_THRESHOLD_PCT=120      # Split when estimate exceeds cap by 120%
MILESTONE_MAX_SPLIT_DEPTH=6            # Max recursive split depth
```

## Migration from Inline Milestones

If your milestones are defined inline in `CLAUDE.md` (the older format):

```bash
tekhton --migrate-dag
```

This extracts milestones from `CLAUDE.md` into individual files and generates
a `MANIFEST.cfg`. The inline definitions are preserved in `CLAUDE.md` as a
backup.

## What's Next?

- [Your First Milestone](../getting-started/first-milestone.md) — Running milestones
- [Configuration Reference](../reference/configuration.md) — Milestone config keys
- [Pipeline Flow](pipeline-flow.md) — How the pipeline works
