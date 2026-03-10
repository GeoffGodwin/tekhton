# Tekhton Planning Phase — Design Document

## Problem Statement

Tekhton's execution pipeline (Coder → Reviewer → Tester) is feature-complete, but
it assumes the user arrives with a fully-formed CLAUDE.md, a milestone plan, and
correct pipeline configuration. In practice, junior developers (1–2 years experience)
struggle with this cold start: they have a project idea but don't know how to
decompose it into milestones, write effective project rules, or structure a design
doc that will guide an AI coding pipeline.

The planning phase bridges this gap. It takes a developer from "I want to build X"
to a production-ready CLAUDE.md and DESIGN.md that the execution pipeline can
consume immediately.

## Target User

Developers with 1–2+ years of experience. They can:
- Use a terminal and git
- Understand basic architecture concepts (frontend/backend, APIs, databases)
- Read and write code in at least one language
- Describe what they want to build, but may struggle to decompose it

They cannot necessarily:
- Write a comprehensive design document from scratch
- Decompose a project into correctly-ordered milestones
- Anticipate all the architectural decisions upfront
- Configure a build pipeline without guidance

## User Flow

```
tekhton --plan
    │
    ├─ 1. Project Type Selection
    │    "What kind of project?" → selects a design doc template
    │
    ├─ 2. Template Fill (guided, interactive)
    │    Claude walks through each section, asking plain-language
    │    questions. User answers in the terminal. Claude writes
    │    the DESIGN.md sections based on their answers.
    │
    ├─ 3. Completeness Check
    │    Structural validation: are all required sections filled?
    │    Claude asks targeted follow-ups for gaps.
    │
    ├─ 4. Design Doc Review
    │    Show the completed DESIGN.md, let user approve or edit.
    │
    ├─ 5. CLAUDE.md Generation
    │    Claude reads DESIGN.md and generates:
    │    - Project rules (non-negotiable constraints)
    │    - Milestone breakdown (ordered, scoped, dependency-aware)
    │    - Architecture guidelines
    │    - Testing strategy
    │
    ├─ 6. Milestone Review
    │    Display milestone plan. User can approve, edit, or re-generate.
    │
    └─ 7. Output
         Writes DESIGN.md and CLAUDE.md to the project directory.
         User runs `tekhton --init` next, then starts executing milestones.
```

## Architecture

### Separation of Concerns

`--plan` is a pre-pipeline phase. It runs *before* `--init` and produces files
that `--init` and the execution pipeline consume. It does NOT modify any existing
pipeline stages, libraries, or prompt templates used by the execution pipeline.

```
New files (planning phase only):
  tekhton/
  ├── lib/plan.sh                  # Planning phase orchestration
  ├── stages/plan_interview.sh     # Interactive interview logic
  ├── stages/plan_generate.sh      # CLAUDE.md generation from DESIGN.md
  ├── prompts/
  │   ├── plan_interview.prompt.md # Interview agent prompt
  │   └── plan_generate.prompt.md  # CLAUDE.md generation prompt
  └── templates/plans/             # Design doc templates by project type
      ├── web-app.md
      ├── web-game.md
      ├── cli-tool.md
      ├── api-service.md
      ├── mobile-app.md
      ├── library.md
      └── custom.md               # Minimal template for anything else
```

### Design Doc Templates

Each template in `templates/plans/` is a markdown file with:
- Section headings appropriate to the project type
- Guidance comments under each heading (what to cover, examples)
- Placeholder text that Claude replaces during the interview

Templates are intentionally concise — they define *structure*, not content.
Claude generates the content during the interactive interview.

Example sections for a `web-app.md` template:

```markdown
## Project Overview
<!-- What does this application do? Who is it for? -->

## Tech Stack
<!-- Language, framework, database, deployment target -->

## User Roles
<!-- Who uses this? What can each role do? -->

## Core Features
<!-- List the main features. Be specific about behavior, not vague. -->

## Data Model
<!-- What are the main entities? How do they relate? -->

## Key User Flows
<!-- Walk through 2-3 critical paths: what does the user do step by step? -->

## External Integrations
<!-- Third-party APIs, auth providers, payment processors, etc. -->

## Non-Functional Requirements
<!-- Performance targets, accessibility, i18n, offline support, etc. -->
```

### Interactive Interview

The interview uses Claude in conversational mode (not `-p` batch mode).
Claude reads the selected template, then walks the user through each section
one at a time:

1. Claude asks a plain-language question based on the current section
2. User types their answer in the terminal
3. Claude synthesizes the answer into proper design doc prose
4. Claude moves to the next section (or asks follow-ups if the answer was vague)

The interview agent has a system prompt that instructs it to:
- Ask one question at a time (not dump a wall of questions)
- Use terminology appropriate for junior developers
- Provide examples when a user seems stuck ("For example, in a todo app...")
- Flag when an answer is too vague and ask for specifics
- Track which sections are complete vs. pending

**Key constraint:** The interview must produce a standalone DESIGN.md that makes
sense without the conversation history. Every answer gets incorporated into the
document, not left as chat ephemera.

### Completeness Criteria

Instead of Claude subjectively deciding when the design is "done," we define
structural completeness per template. Each template declares its required
sections. A section is complete when it has:

- At least one concrete, non-placeholder statement
- No remaining guidance comments (<!-- ... -->)
- For list-type sections: at least 2 items

The planning phase checks these programmatically (grep/awk, not LLM judgment)
before proceeding to CLAUDE.md generation. Missing sections trigger targeted
follow-up questions.

### CLAUDE.md Generation

After the design doc is complete, a second agent pass reads DESIGN.md and
generates CLAUDE.md with:

1. **Project identity** — name, description, tech stack
2. **Non-negotiable rules** — derived from tech stack and architectural choices
3. **Milestone plan** — ordered sequence of implementation milestones where:
   - Milestone 1 is always project scaffold + foundational infrastructure
   - Each milestone builds on the previous (no forward dependencies)
   - Each milestone is scoped to what one pipeline run can accomplish
   - Milestones have clear acceptance criteria
4. **Architecture guidelines** — layer boundaries, naming conventions, patterns
5. **Testing strategy** — what to test, coverage expectations, test patterns

The generation agent uses a dedicated prompt template that enforces the
milestone structure the execution pipeline expects.

### Milestone Review

Before writing files, the planning phase displays the milestone plan:

```
══════════════════════════════════════
  Tekhton Plan — Milestone Summary
══════════════════════════════════════

  Project: My App
  Milestones: 6

  1. Project scaffold + data models
  2. Core engine: deck management
  3. User authentication + permissions
  4. Search and filtering system
  5. UI polish + error handling
  6. Testing hardening + deployment config

  [y] Accept and write files
  [e] Edit milestone plan in $EDITOR
  [r] Re-generate with different priorities
  [n] Abort
```

This gives the user a last chance to reorder or reshape before committing.

## Integration Points

### With --init

`--plan` does NOT run `--init`. It produces DESIGN.md and CLAUDE.md only.
The user runs `--init` separately afterward. This keeps concerns clean:
- `--plan` = creative (what to build)
- `--init` = mechanical (scaffold config files)

`--init` should detect when CLAUDE.md already exists (it does today) and
skip overwriting it, so running `--plan` then `--init` works naturally.

### With DESIGN_FILE

The planning phase writes DESIGN.md to the project root. The user can then
set `DESIGN_FILE="DESIGN.md"` in pipeline.conf (or we auto-set it during
`--init` if DESIGN.md exists). This enables the execution pipeline's existing
drift cross-referencing to use the design doc as its source of truth.

### With --milestone mode

The generated CLAUDE.md should use a milestone format that maps naturally to
`tekhton --milestone "Implement Milestone N: <description>"` invocations.
Each milestone description should be self-contained enough to serve as the
task argument.

## Pipeline Configuration for Planning

The planning phase needs its own config knobs:

```bash
# Agent model for the interview (conversational, needs good reasoning)
CLAUDE_PLAN_MODEL="${CLAUDE_STANDARD_MODEL}"

# Agent model for CLAUDE.md generation (needs strong structure + reasoning)
CLAUDE_PLAN_GENERATE_MODEL="${CLAUDE_CODER_MODEL}"

# Max turns for the interview conversation
PLAN_INTERVIEW_MAX_TURNS=50

# Max turns for CLAUDE.md generation
PLAN_GENERATE_MAX_TURNS=30
```

These are optional keys with sensible defaults — users don't need to configure
them unless they want to customize the planning experience.

## Scope Boundaries

### In scope for v1.0
- `tekhton --plan` interactive flow
- 7 project type templates (web-app, web-game, cli-tool, api-service, mobile-app, library, custom)
- Interactive interview with one-question-at-a-time flow
- Structural completeness checking
- CLAUDE.md generation with milestone plan
- Milestone review/approval before writing files
- `--plan` state persistence (resume interrupted planning sessions)

### Out of scope for v1.0
- Non-developer users (no "explain what an API is" hand-holding)
- Automatic `--init` after planning (keep them separate)
- Visual/GUI interview (terminal only)
- Multi-language template variants
- Re-planning existing projects (only greenfield)
- Iterating on CLAUDE.md after the first generation (user edits manually)

### Stretch (post-v1.0)
- Non-developer mode with simplified vocabulary
- `tekhton --replan` to update DESIGN.md and re-derive milestones
- Template marketplace (community-contributed project type templates)
- Web-based interview interface
