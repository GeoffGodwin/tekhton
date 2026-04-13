# Milestones

> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md) · [M80](../.claude/milestones/m80-draft-milestones-interactive-flow.md)

Tekhton uses **milestones** to break large features into pipeline-sized tasks.
Each milestone is a standalone markdown file in `.claude/milestones/` with a
structured format that the pipeline understands.

## Authoring Milestones

### Interactive Flow (`--draft-milestones`)

The recommended way to create milestones is the interactive authoring flow:

```bash
# Start with an idea
tekhton --draft-milestones "add a metrics dashboard for test flake rate"

# Or start without a seed — the agent analyzes your project state
tekhton --draft-milestones
```

The flow runs in four phases:

1. **Clarify** — The agent analyzes your seed description and the codebase to
   understand scope, constraints, and dependencies.
2. **Analyze** — Uses the repo map (if enabled) and file reads to survey
   existing code in the relevant area.
3. **Propose** — Proposes a milestone split: how many milestones, what each
   covers, and why they are separate. Milestones are chained linearly
   (each depends on the previous).
4. **Generate** — Writes milestone files to `.claude/milestones/` with the
   standard structure (Overview, Design Decisions, Scope Summary,
   Implementation Plan, Files Touched, Acceptance Criteria).

After generation, the pipeline validates each file and asks for confirmation
before updating `MANIFEST.cfg`.

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DRAFT_MILESTONES_MODEL` | `$CLAUDE_STANDARD_MODEL` | Model for the authoring agent |
| `DRAFT_MILESTONES_MAX_TURNS` | `40` | Turn budget for the agent |
| `DRAFT_MILESTONES_AUTO_WRITE` | `false` | Skip confirmation prompt |
| `DRAFT_MILESTONES_SEED_EXEMPLARS` | `3` | Recent milestones shown as format examples |

### Scripting / CI

Set `DRAFT_MILESTONES_AUTO_WRITE=true` to bypass the confirmation prompt:

```bash
DRAFT_MILESTONES_AUTO_WRITE=true tekhton --draft-milestones "my feature"
```

### Manual Testing

Since the flow is interactive and invokes an LLM agent, automated end-to-end
testing is impractical. To verify manually:

1. Run `tekhton --draft-milestones "add foo feature"` in a test project
2. Verify the agent asks clarifying questions (Phase 1)
3. Verify it reads relevant code (Phase 2)
4. Verify it proposes a split with rationale (Phase 3)
5. Verify it generates well-formed milestone files (Phase 4)
6. Check the generated files have all required sections
7. Confirm → verify MANIFEST.cfg rows were added

### Deprecated: `--add-milestone`

The older `--add-milestone` flag still works but prints a deprecation warning
and forwards to `--draft-milestones`. It will be removed in a future release.

## Milestone File Format

Each milestone file follows this structure:

```markdown
# Milestone <ID>: <Title>
<!-- milestone-meta
id: "<ID>"
status: "pending"
-->

## Overview
(motivation and goal)

## Design Decisions
(numbered subsections with trade-off analysis)

## Scope Summary
(table: Area | Count | Notes)

## Implementation Plan
(numbered steps)

## Files Touched
(### Added and ### Modified subsections)

## Acceptance Criteria
(minimum 5 testable items as `- [ ] criterion`)
```

## Milestone Lifecycle

1. **pending** — Not yet started
2. **in_progress** — Currently being implemented
3. **done** — Completed and archived to `MILESTONE_ARCHIVE.md`

Milestones are tracked in `MANIFEST.cfg` with dependency ordering.
The pipeline runs them in dependency order via `--auto-advance`.

See also: [Configuration](configuration.md), [CLI Reference](cli-reference.md)
