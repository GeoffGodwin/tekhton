# Greenfield Projects

Starting a new project from scratch? Tekhton's planning phase designs your
project before any code is written.

## Step 1: Plan Your Project

Run the interactive planning phase:

```bash
mkdir my-new-project && cd my-new-project
git init
tekhton --plan
```

### What Happens

1. **Project type selection** — Choose from: web app, web game, CLI tool, API
   service, mobile app, library, or custom
2. **Design interview** — Claude walks you through your project's requirements,
   architecture, and design decisions section by section
3. **Completeness check** — Tekhton validates that all required sections have
   sufficient depth
4. **Follow-up interview** — If sections are too shallow, Claude probes for more
   detail
5. **Document generation** — Produces `DESIGN.md` (design document) and `CLAUDE.md`
   (project rules + milestone plan)

### Tips for the Interview

- **Be specific about what you want**, not how to build it. "Users should be able
  to upload photos and apply filters" is better than "Use multer for file uploads."
- **Mention constraints early.** If you need to deploy on Vercel, or your API must
  be REST (not GraphQL), say so upfront.
- **Don't worry about getting it perfect.** You can always run `--replan` later to
  update the design.

## Step 2: Review the Output

After planning, review two files:

**`DESIGN.md`** — Your project's design document. This captures every design
decision made during the interview. Think of it as the "what and why."

**`CLAUDE.md`** — Project rules, architecture guidelines, and the milestone plan.
This is the "how" — what the agents follow when implementing.

Review the milestone plan carefully:

- Are milestones ordered correctly?
- Does each milestone have clear acceptance criteria?
- Are the dependencies between milestones right?

## Step 3: Initialize the Pipeline

```bash
tekhton --init
```

This creates the pipeline configuration and agent role files. Review
`.claude/pipeline.conf` and update any values that don't match your setup.

## Step 4: Start Building

Run the first milestone:

```bash
tekhton --milestone
```

Or let Tekhton work through multiple milestones:

```bash
tekhton --milestone --auto-advance
```

## Updating the Plan

If your requirements change mid-project:

```bash
tekhton --replan
```

This runs a delta-based update to your `DESIGN.md` and `CLAUDE.md` without
starting from scratch. It reads the current codebase state and adjusts the
plan accordingly.

## What's Next?

- [Your First Milestone](../getting-started/first-milestone.md) — Detailed
  walkthrough of a milestone run
- [Planning Phase](planning.md) — Deep dive into the planning process
- [Configuration](../reference/configuration.md) — Customize pipeline behavior
