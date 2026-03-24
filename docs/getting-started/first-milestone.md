# Your First Milestone

Milestones are how Tekhton handles large work. Instead of trying to build an
entire feature in one pass, you break it into milestones — each with clear
acceptance criteria — and Tekhton works through them one at a time.

## What Is a Milestone?

A milestone is a scoped unit of work defined in `CLAUDE.md` (or as individual
files in `.claude/milestones/`). Each milestone has:

- **A description** of what to build
- **Acceptance criteria** that define "done"
- **Dependencies** on other milestones (optional)

Example milestone:

```markdown
#### Milestone 1: User Authentication
Add email/password authentication with JWT tokens.

Acceptance criteria:
- POST /auth/register creates a new user
- POST /auth/login returns a JWT token
- Protected routes reject requests without valid tokens
- Passwords are hashed with bcrypt (never stored in plain text)
- All existing tests pass
```

## Running a Milestone

To run the next pending milestone:

```bash
tekhton --milestone
```

Tekhton reads your milestone plan, picks the next one whose dependencies are
satisfied, and runs the full pipeline (scout, coder, security, reviewer, tester)
with higher turn limits and more review cycles than a regular task.

### What Happens During a Milestone Run

1. **Intake** — The PM agent evaluates the milestone scope
2. **Scout** — Analyzes the codebase and estimates effort
3. **Coder** — Implements the milestone (with more turns than a regular task)
4. **Security Review** — Checks for vulnerabilities in the new code
5. **Code Review** — Reviews against the acceptance criteria
6. **Rework** — If the reviewer finds issues, they're fixed automatically
7. **Test** — Writes tests covering the acceptance criteria
8. **Acceptance Check** — Verifies all acceptance criteria are met
9. **Commit** — Creates a commit with a milestone completion message

## Auto-Advance

To work through multiple milestones in sequence:

```bash
tekhton --milestone --auto-advance
```

Tekhton will complete one milestone, check if the next one's dependencies are
satisfied, and continue. By default it pauses between milestones for confirmation.

Control auto-advance behavior in `pipeline.conf`:

```bash
AUTO_ADVANCE_LIMIT=3           # Max milestones per invocation
AUTO_ADVANCE_CONFIRM=true      # Pause between milestones for confirmation
```

## Creating Milestones

### Using `--plan`

The easiest way to create milestones is through the planning phase:

```bash
tekhton --plan
```

This runs an interactive interview that produces a `DESIGN.md` (design document)
and `CLAUDE.md` with a full milestone plan. See the [Planning Guide](../guides/planning.md)
for details.

### Manually

Add milestones directly to `CLAUDE.md` or create individual files in
`.claude/milestones/`. See [Milestone DAG](../concepts/milestone-dag.md) for
the file-based format.

### Using `--add-milestone`

Add a single milestone without editing files:

```bash
tekhton --add-milestone "Add rate limiting to all API endpoints"
```

The intake agent scopes and writes the milestone file automatically.

## When Things Go Wrong

If a milestone fails:

1. **Check the output** — `CODER_SUMMARY.md` and `REVIEWER_REPORT.md` explain
   what happened
2. **Use `--diagnose`** — `tekhton --diagnose` analyzes the last failure and
   suggests recovery steps
3. **Resume** — Just run `tekhton --milestone` again. Tekhton resumes from where
   it left off.

## What's Next?

- [Understanding Output](understanding-output.md) — Learn to read the reports
- [Milestone DAG](../concepts/milestone-dag.md) — How milestone dependencies work
- [Commands Reference](../reference/commands.md) — All milestone-related flags
