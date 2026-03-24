# Planning Phase

The planning phase (`--plan`) is an interactive process that produces a design
document and a milestone plan before any code is written. It's the recommended
way to start any project larger than a single feature.

## Running the Planner

```bash
tekhton --plan
```

### Step 1: Project Type Selection

Tekhton asks you to choose a project type:

1. Web Application
2. Web Game
3. CLI Tool
4. API Service
5. Mobile App
6. Library/Package
7. Custom

Each type has a tailored template that guides the interview toward the right
design questions.

### Step 2: Design Interview

Claude walks you through the design template section by section. For each
section, it asks targeted questions about your requirements, constraints, and
design decisions.

The interview writes to `DESIGN.md` progressively — you can see sections
filling in as you answer questions.

!!! tip "Getting Better Results"
    - Be concrete about what users will do, not how the system should work
    - Mention specific technologies you want to use (or want to avoid)
    - Share constraints: hosting platform, budget, team size, timeline
    - If you're unsure about something, say so — it's better to leave a question
      open than to guess

### Step 3: Completeness Check

After the interview, Tekhton validates the design document against the template's
required sections. If any sections are too shallow (placeholder content, missing
details), it flags them.

### Step 4: Follow-Up Interview

For incomplete sections, Claude runs a focused follow-up interview. This probes
for the specific depth that's missing: sub-sections, tables, configuration
examples, edge cases, and interaction rules between systems.

### Step 5: CLAUDE.md Generation

With a complete design document, Tekhton generates `CLAUDE.md` — the project
rules and milestone plan that the pipeline agents follow.

The generated `CLAUDE.md` includes:

- Project identity and description
- Architecture philosophy and patterns
- Non-negotiable rules
- Full project structure tree
- Milestone plan with acceptance criteria, dependencies, and test requirements
- Code conventions

### Step 6: Review

Before writing files, Tekhton shows the generated content and offers options:

- **[y]** Write the files to your project
- **[e]** Open in your editor for manual tweaks
- **[r]** Re-run the generation with different parameters
- **[n]** Abort without writing

## Resuming an Interrupted Session

If the planning session is interrupted (Ctrl+C, lost connection), Tekhton saves
state automatically. Next time you run `--plan`, it offers to resume:

```
Interrupted planning session found (stage: interview).
[r] Resume from where you left off
[s] Start fresh
```

## Updating an Existing Plan

After initial planning, use `--replan` to update:

```bash
tekhton --replan
```

This is a delta-based update: it reads the current codebase state, compares it
to the existing plan, and produces targeted changes to `DESIGN.md` and
`CLAUDE.md`. It doesn't start from scratch.

## Configuration

Planning-related settings in `pipeline.conf`:

```bash
PLAN_INTERVIEW_MODEL="opus"        # Model for the interview (default: opus)
PLAN_INTERVIEW_MAX_TURNS=50        # Turn limit for interview
PLAN_GENERATION_MODEL="opus"       # Model for CLAUDE.md generation
PLAN_GENERATION_MAX_TURNS=50       # Turn limit for generation
```

!!! note "Planning Uses Opus by Default"
    Planning is a one-time cost per project. Using Opus (the most capable model)
    produces significantly better milestone plans and architecture guidelines.

## What's Next?

- [Greenfield Projects](greenfield.md) — Full greenfield workflow
- [Brownfield Projects](brownfield.md) — Planning for existing codebases
- [Milestone DAG](../concepts/milestone-dag.md) — How milestones are organized
