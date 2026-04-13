# Usage

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.

## How the Pipeline Works

```
tekhton "Implement feature X"
        |
        +- Pre-flight: env validation, service readiness, optional auto-remediation
        +- Task Intake: clarity scoring, scope assessment, task tweaking
        +- Architect audit (conditional -- drift thresholds)
        |
        +- Scout + Coder
        |    +- Scout -> estimates complexity, adjusts turn limits, leverages repo map + Serena
        |    +- Coder -> writes code + CODER_SUMMARY.md
        |    +- Turn continuation -> auto-resume if coder hits turn limit with progress
        |    +- Build gate -> error pattern classification -> auto-fix (Jr -> Sr escalation)
        |
        +- Security Review
        |    +- OWASP-aware vulnerability scan -> SECURITY_REPORT.md
        |    +- High/Critical findings -> auto-remediation rework loop
        |
        +- Code Review
        |    +- Reviewer -> REVIEWER_REPORT.md
        |    +- Complex blockers -> Senior coder rework
        |    +- Simple blockers -> Jr coder fix
        |    +- Build gate after fixes
        |    +- Specialist reviews (UI/UX auto on UI projects; performance, API, custom -- opt-in)
        |    +- (repeats up to MAX_REVIEW_CYCLES)
        |
        +- Tester
        |    +- Writes tests for coverage gaps -> TESTER_REPORT.md
        |    +- Test baseline check -> ignore pre-existing failures
        |    +- Surgical fix mode -> scoped fix agent on test failures
        |
        +- Cleanup (opt-in -- autonomous debt sweep)
        |
        +- Drift processing (observations, ACPs, non-blocking notes)
        +- Milestone acceptance check (in --milestone / --complete mode)
        +- Commit with auto-generated message
```

With `--complete`, the entire pipeline loops until acceptance criteria pass or
resource bounds are exhausted — retrying transient API errors, continuing on
turn exhaustion, and splitting oversized milestones automatically.

### Agent Models

Each agent runs on its own configurable model. Defaults:

| Agent | Default Model | Purpose |
|-------|--------------|---------|
| Coder | Opus | Primary implementation |
| Jr Coder | Haiku | Simple fixes, build repairs, debt sweeps, test fixes |
| Scout | Haiku | File discovery, complexity estimation |
| Reviewer | Sonnet | Code review, drift observation |
| Architect | Sonnet | Drift audit, remediation planning |
| Tester | Haiku (Sonnet in `--milestone`) | Test writing, validation, surgical fix mode |
| Intake / PM | Sonnet | Task clarity scoring, scope assessment, decomposition |
| Security | Sonnet | OWASP-aware vulnerability review (built-in stage) |
| UI/UX Specialist | Sonnet | Component, accessibility, design-system review (auto on UI projects) |
| Other Specialists | Sonnet | Performance, API, custom focused reviews (opt-in) |

### Dynamic Turn Limits

When `DYNAMIC_TURNS_ENABLED=true` (the default), the Scout agent estimates task
complexity before the Coder runs. The pipeline parses the estimate and adjusts
turn limits for Coder, Reviewer, and Tester — clamped to configured min/max bounds.

A simple bug fix might get 15 coder turns. A cross-cutting milestone might get 120.
This prevents wasting tokens on trivial tasks and running out of turns on large ones.

After the coder completes, reviewer and tester turn limits are **recalibrated** using
actual coder data (turns used, files modified, diff size) — replacing the scout's
pre-coder guesses with a deterministic formula.

With `METRICS_ADAPTIVE_TURNS=true` and enough run history, turn estimates are further
refined by adaptive calibration based on your project's actual performance data.

### Resume Support

Pipeline state is saved automatically on interruption. Running `tekhton` with no
arguments detects saved state and offers to resume, start fresh, or abort.
`--start-at` lets you jump to a specific stage if reports from earlier stages exist.

## Autonomous Modes

### Complete Mode (`--complete`)

Wraps the entire pipeline in an outer loop that re-runs until the task passes
acceptance or all recovery options are exhausted:

```bash
tekhton --complete "Resolve all NON_BLOCKING_LOG observations"
```

Safety bounds prevent runaway execution:
- `MAX_PIPELINE_ATTEMPTS=5` — max full pipeline cycles
- `AUTONOMOUS_TIMEOUT=7200` — wall-clock limit (2 hours)
- `MAX_AUTONOMOUS_AGENT_CALLS=20` — cumulative agent invocations
- `AUTONOMOUS_PROGRESS_CHECK=true` — detects stuck loops (no diff between iterations)

### Milestone Mode (`--milestone`)

Doubles turn limits, adds an extra review cycle, upgrades the tester model, and
runs milestone acceptance checking. Implies `--complete` — the pipeline retries
until acceptance criteria pass.

```bash
tekhton --milestone "Implement Milestone 3: API layer"
```

If a milestone is too large for the turn budget, the pipeline automatically splits
it into sub-milestones (3.1, 3.2, ...) and retries with narrower scope. If a coder
run produces no output (null run), the milestone is split and retried without human
intervention.

Completed milestones are automatically archived from CLAUDE.md to
`MILESTONE_ARCHIVE.md`, keeping CLAUDE.md under context window limits.

### Auto-Advance (`--auto-advance`)

Chains milestone-to-milestone execution. After each milestone passes acceptance, the
pipeline advances to the next and continues:

```bash
tekhton --auto-advance "Start with Milestone 1"
```

- `AUTO_ADVANCE_LIMIT=3` — max milestones per invocation
- `AUTO_ADVANCE_CONFIRM=true` — prompt between milestones (set `false` for unattended)

### Human Notes Mode (`--human`)

Pick the next unchecked item from `HUMAN_NOTES.md` as the task. Combine with
`--complete` to process all notes in batch:

```bash
tekhton --human              # Process next note
tekhton --human BUG          # Process next [BUG] note
tekhton --human --complete   # Process all notes until done
```

## Human Notes

Write `HUMAN_NOTES.md` between runs to inject bug reports, feature requests, or polish
items into the next pipeline run. Use `--init-notes` to create a blank template.

```markdown
## Bugs
- [ ] [BUG] Login page crashes when email field is empty
- [ ] [BUG] Dark mode toggle doesn't persist

## Features
- [ ] [FEAT] Add CSV export to the reports page
```

Notes are categorized with `[BUG]`, `[FEAT]`, `[POLISH]` tags. Use `--notes-filter BUG`
to inject only bugs on a given run. Use `--human --complete` to process all notes
automatically. Completed items are automatically archived.
