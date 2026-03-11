# Tekhton — Project Configuration

## What This Is

Tekhton is a standalone, project-agnostic multi-agent development pipeline built on
the Claude CLI. It orchestrates a Coder → Reviewer → Tester cycle with automatic
rework routing, build gates, state persistence, and resume support.

**One intent. Many hands.**

## Repository Layout

```
tekhton/
├── tekhton.sh              # Main entry point
├── lib/                    # Shared libraries (sourced by tekhton.sh)
│   ├── common.sh           # Colors, logging, prerequisite checks
│   ├── config.sh           # Config loader + validation
│   ├── agent.sh            # Agent wrapper, metrics, run_agent()
│   ├── gates.sh            # Build gate + completion gate
│   ├── hooks.sh            # Archive, commit message, final checks
│   ├── notes.sh            # Human notes management
│   ├── prompts.sh          # Template engine for .prompt.md files
│   ├── state.sh            # Pipeline state persistence + resume
│   ├── drift.sh            # Drift log, ADL, human action management
│   ├── plan.sh             # Planning phase orchestration + config
│   ├── plan_completeness.sh # Design doc structural validation
│   └── plan_state.sh       # Planning state persistence + resume
├── stages/                 # Stage implementations (sourced by tekhton.sh)
│   ├── architect.sh        # Stage 0: Architect audit (conditional)
│   ├── coder.sh            # Stage 1: Scout + Coder + build gate
│   ├── review.sh           # Stage 2: Review loop + rework routing
│   ├── tester.sh           # Stage 3: Test writing + validation
│   ├── plan_interview.sh   # Planning: interactive interview agent
│   └── plan_generate.sh    # Planning: CLAUDE.md generation agent
├── prompts/                # Prompt templates with {{VAR}} substitution
│   ├── architect.prompt.md
│   ├── architect_sr_rework.prompt.md
│   ├── architect_jr_rework.prompt.md
│   ├── architect_review.prompt.md
│   ├── coder.prompt.md
│   ├── coder_rework.prompt.md
│   ├── jr_coder.prompt.md
│   ├── reviewer.prompt.md
│   ├── scout.prompt.md
│   ├── tester.prompt.md
│   ├── tester_resume.prompt.md
│   ├── build_fix.prompt.md
│   ├── build_fix_minimal.prompt.md
│   ├── analyze_cleanup.prompt.md
│   ├── seed_contracts.prompt.md
│   ├── plan_interview.prompt.md          # Planning interview system prompt
│   ├── plan_interview_followup.prompt.md # Planning follow-up interview prompt
│   └── plan_generate.prompt.md           # CLAUDE.md generation prompt
├── templates/              # Templates copied into target projects by --init
│   ├── pipeline.conf.example
│   ├── coder.md
│   ├── reviewer.md
│   ├── tester.md
│   ├── jr-coder.md
│   └── architect.md
├── templates/plans/        # Design doc templates by project type
│   ├── web-app.md
│   ├── web-game.md
│   ├── cli-tool.md
│   ├── api-service.md
│   ├── mobile-app.md
│   ├── library.md
│   └── custom.md
├── tests/                  # Self-tests
└── examples/               # Sample dependency constraint validation scripts
    ├── architecture_constraints.yaml  # Sample constraint manifest
    ├── check_imports_dart.sh          # Dart/Flutter import validator
    ├── check_imports_python.sh        # Python import validator
    └── check_imports_typescript.sh    # TypeScript/JS import validator
```

## How It Works

Tekhton is invoked from a target project's root directory. It reads configuration
from `<project>/.claude/pipeline.conf` and agent role definitions from
`<project>/.claude/agents/*.md`. All pipeline logic (lib, stages, prompts) lives
in the Tekhton repo — nothing is copied into target projects except config and
agent roles.

### Two-directory model:
- `TEKHTON_HOME` — where `tekhton.sh` lives (this repo)
- `PROJECT_DIR` — the target project (caller's CWD)

## Non-Negotiable Rules

1. **Project-agnostic.** Tekhton must never contain project-specific logic.
   All project configuration is in `pipeline.conf` and agent role files.
2. **Bash 4+.** All scripts use `set -euo pipefail`. No bashisms beyond bash 4.
3. **Shellcheck clean.** All `.sh` files pass `shellcheck` with zero warnings.
4. **Deterministic.** Given the same config.conf and task, pipeline behavior is identical.
5. **Resumable.** Pipeline state is saved on interruption. Re-running resumes.
6. **Template engine.** Prompts use `{{VAR}}` substitution and `{{IF:VAR}}...{{ENDIF:VAR}}`
   conditionals. No other templating system.

## Template Variables (Prompt Engine)

Available variables in prompt templates — set by the pipeline before rendering:

| Variable | Source |
|----------|--------|
| `PROJECT_DIR` | `pwd` at tekhton.sh startup |
| `PROJECT_NAME` | pipeline.conf |
| `TASK` | CLI argument |
| `CODER_ROLE_FILE` | pipeline.conf |
| `REVIEWER_ROLE_FILE` | pipeline.conf |
| `TESTER_ROLE_FILE` | pipeline.conf |
| `JR_CODER_ROLE_FILE` | pipeline.conf |
| `PROJECT_RULES_FILE` | pipeline.conf |
| `ARCHITECTURE_FILE` | pipeline.conf |
| `ARCHITECTURE_CONTENT` | File contents of ARCHITECTURE_FILE |
| `ANALYZE_CMD` | pipeline.conf |
| `TEST_CMD` | pipeline.conf |
| `REVIEW_CYCLE` | Current review iteration |
| `MAX_REVIEW_CYCLES` | pipeline.conf |
| `HUMAN_NOTES_BLOCK` | Extracted unchecked items from HUMAN_NOTES.md |
| `HUMAN_NOTES_CONTENT` | Raw filtered notes content |
| `INLINE_CONTRACT_PATTERN` | pipeline.conf (optional) |
| `BUILD_ERRORS_CONTENT` | Contents of BUILD_ERRORS.md |
| `ANALYZE_ISSUES` | Output of ANALYZE_CMD |
| `DESIGN_FILE` | pipeline.conf (optional — design doc path) |
| `ARCHITECTURE_LOG_FILE` | pipeline.conf (default: ARCHITECTURE_LOG.md) |
| `DRIFT_LOG_FILE` | pipeline.conf (default: DRIFT_LOG.md) |
| `HUMAN_ACTION_FILE` | pipeline.conf (default: HUMAN_ACTION_REQUIRED.md) |
| `DRIFT_OBSERVATION_THRESHOLD` | pipeline.conf (default: 8) |
| `DRIFT_RUNS_SINCE_AUDIT_THRESHOLD` | pipeline.conf (default: 5) |
| `ARCHITECT_ROLE_FILE` | pipeline.conf (default: .claude/agents/architect.md) |
| `ARCHITECT_MAX_TURNS` | pipeline.conf (default: 25) |
| `CLAUDE_ARCHITECT_MODEL` | pipeline.conf (default: CLAUDE_STANDARD_MODEL) |
| `ARCHITECTURE_LOG_CONTENT` | File contents of ARCHITECTURE_LOG_FILE |
| `DRIFT_LOG_CONTENT` | File contents of DRIFT_LOG_FILE |
| `DRIFT_OBSERVATION_COUNT` | Count of unresolved observations |
| `DEPENDENCY_CONSTRAINTS_CONTENT` | File contents of dependency constraints (optional) |
| `PLAN_TEMPLATE_CONTENT` | Contents of selected design doc template (planning) |
| `PLAN_DESIGN_CONTENT` | Contents of DESIGN.md during generation (planning) |
| `PLAN_INCOMPLETE_SECTIONS` | List of incomplete sections for follow-up (planning) |
| `PLAN_INTERVIEW_MODEL` | Model for interview agent (default: opus) |
| `PLAN_INTERVIEW_MAX_TURNS` | Turn limit for interview (default: 50) |
| `PLAN_GENERATION_MODEL` | Model for generation agent (default: opus) |
| `PLAN_GENERATION_MAX_TURNS` | Turn limit for generation (default: 30) |

## Testing

```bash
# Run self-tests
cd tekhton && bash tests/run_tests.sh

# Verify shellcheck
shellcheck tekhton.sh lib/*.sh stages/*.sh
```

## Adding Tekhton to a New Project

```bash
cd /path/to/your/project
/path/to/tekhton/tekhton.sh --init
# Edit .claude/pipeline.conf
# Edit .claude/agents/*.md
/path/to/tekhton/tekhton.sh "Your first task"
```

## Current Initiative: Planning Phase Quality Overhaul

The `--plan` pipeline runs end-to-end but produces shallow output. The DESIGN.md
and CLAUDE.md it generates lack the depth, interconnection, and specificity needed
to drive successful execution pipeline runs. This initiative upgrades the entire
planning phase to produce output comparable to the Lönn project's GDD (1,600+ lines,
23 deep sections) and CLAUDE.md (970 lines, 11 milestones with seeds-forward notes,
watch-for blocks, and config architecture).

### Reference: What "Good" Looks Like

The gold standard is `loenn/docs/GDD_Loenn.md` and `loenn/CLAUDE.md`. Key qualities:

**DESIGN.md (GDD) qualities:**
- Opens with a Developer Philosophy section establishing non-negotiable architectural
  constraints before any feature content
- Each game system gets its own deep section with sub-sections, tables, config examples,
  edge cases, balance warnings, and explicit interaction rules with other systems
- Configurable values are called out specifically with defaults and rationale
- Open design questions are tracked explicitly rather than glossed over
- Naming conventions section maps lore names to code names
- ~1,600 lines for a complex project

**CLAUDE.md qualities:**
- Architecture Philosophy section with concrete patterns (composition over inheritance,
  interface-first, config-driven)
- Full project structure tree with every directory and key file annotated
- Key Design Decisions section resolving ambiguities with canonical rulings
- Config Architecture section with example config structures and key values
- Milestones with: scope, file paths, acceptance criteria, `Tests:` block,
  `Watch For:` block, `Seeds Forward:` block explaining what future milestones depend on
- Critical Game Rules section — behavioral invariants the engine must enforce
- "What Not to Build Yet" section — explicitly deferred features
- Code Conventions section (naming, git workflow, testing requirements, state management pattern)
- ~970 lines for a complex project

### Key Constraints

- **No `--dangerously-skip-permissions`.** The shell drives all file I/O. Claude
  generates text only via `_call_planning_batch()`.
- **Zero execution pipeline changes.** Modify only: `lib/plan.sh`, `stages/plan_interview.sh`,
  `stages/plan_generate.sh`, `prompts/plan_*.prompt.md`, `templates/plans/*.md`, and tests.
- **Default model: Opus.** Planning is a one-time cost per project. Use the best model.
- **All new `.sh` files must pass `bash -n` syntax check.**
- **All existing tests must continue to pass** (`bash tests/run_tests.sh`).

### Milestone Plan

#### Milestone 1: Model Default + Template Depth Overhaul
Change the default planning model from sonnet to opus, and completely rewrite all 7
design doc templates to match the depth and structure of the Lönn GDD. Templates are
the skeleton that determines interview quality — shallow templates produce shallow output.

Files to modify:
- `lib/plan.sh` — change default model from `sonnet` to `opus` on lines 39 and 41
- `templates/plans/web-app.md` — full rewrite
- `templates/plans/web-game.md` — full rewrite
- `templates/plans/cli-tool.md` — full rewrite
- `templates/plans/api-service.md` — full rewrite
- `templates/plans/mobile-app.md` — full rewrite
- `templates/plans/library.md` — full rewrite
- `templates/plans/custom.md` — full rewrite
- `CLAUDE.md` — update default model references in Template Variables table

Template rewrite requirements (using web-game.md as the exemplar):

Each template must have these structural qualities:
1. **Developer Philosophy / Constraints section** (REQUIRED) — before any feature content.
   Guidance: "What are your non-negotiable architectural rules? Config-driven? Interface-first?
   Composition over inheritance? What patterns must be followed from day one?"
2. **Table of Contents placeholder** — `<!-- Generated from sections below -->`
3. **Deep system sections** — each major system gets its own `## Section` with sub-sections
   (`### Sub-Section`). Guidance comments should ask probing follow-up questions:
   - "What are the edge cases?"
   - "What interactions does this system have with other systems?"
   - "What values should be configurable vs hardcoded?"
   - "What are the failure modes?"
4. **Config Architecture section** (REQUIRED) — "What values must live in config? What format?
   Show example config structures with keys and default values."
5. **Open Design Questions section** — "What decisions are you deliberately deferring?
   What needs playtesting/user-testing before you can decide?"
6. **Naming Conventions section** — "What code names map to what domain concepts?
   Especially important when lore/branding is not finalized."
7. **At least 15–25 sections** depending on project type, each with `<!-- REQUIRED -->`
   or optional markers and multi-line guidance comments that explain what depth is expected.

Template section counts by type (approximate):
- `web-game.md`: 20–25 sections (concept, pillars, player resources, each game system,
  UI layout, developer reference, debug tools, open questions)
- `web-app.md`: 18–22 sections (overview, auth, data model per entity, API design,
  state management, error handling, deployment, observability)
- `cli-tool.md`: 15–18 sections (command taxonomy, argument parsing, output formatting,
  config, error codes, shell completion, packaging)
- `api-service.md`: 18–22 sections (endpoints, auth, rate limiting, data model,
  error responses, versioning, deployment, monitoring)
- `mobile-app.md`: 18–22 sections (screens, navigation, offline support, push notifications,
  platform differences, app lifecycle, deep linking)
- `library.md`: 15–18 sections (public API surface, type safety, error handling,
  versioning strategy, bundling, tree-shaking, documentation)
- `custom.md`: 12–15 sections (generic but deep — overview, architecture, data model,
  key systems, config, constraints, open questions)

Acceptance criteria:
- Default model in `lib/plan.sh` is `opus` (both interview and generation)
- Every template has a Developer Philosophy section marked REQUIRED
- Every template has a Config Architecture section marked REQUIRED
- Every template has an Open Design Questions section
- `web-game.md` has at least 20 sections with guidance comments
- All other templates have at least 15 sections with guidance comments
- Guidance comments ask probing, specific questions — not just "describe X"
- All tests pass (`bash tests/run_tests.sh`)
- `CLAUDE.md` Template Variables table updated to show `opus` default

#### Milestone 2: Multi-Phase Interview with Deep Probing
Rewrite the interview flow to use a three-phase approach instead of a single pass.
The shell collects progressively deeper information, and the synthesis call produces
a document with the depth of the Lönn GDD.

Phase 1 — **Concept Capture** (sections marked with a new `<!-- PHASE:1 -->` marker):
High-level questions only. Project overview, tech stack, core concept, developer
philosophy. Quick answers, broad strokes.

Phase 2 — **System Deep-Dive** (sections marked `<!-- PHASE:2 -->`):
Each system/feature section. The shell presents the user's Phase 1 answers as
context before each Phase 2 question, so they can reference what they already said.

Phase 3 — **Architecture & Constraints** (`<!-- PHASE:3 -->`):
Config architecture, naming conventions, open questions, what NOT to build.
These sections benefit from the user having just articulated all their systems.

Files to modify:
- `templates/plans/*.md` — add `<!-- PHASE:N -->` markers to each section
- `stages/plan_interview.sh` — restructure `run_plan_interview()` to loop in
  three phases, displaying a phase header and accumulated context between phases
- `lib/plan.sh` — update `_extract_template_sections()` to parse `<!-- PHASE:N -->`
  marker into a fourth field (default: 1 if not specified)
- `prompts/plan_interview.prompt.md` — add instruction to expand each answer into
  deep, multi-paragraph design prose with sub-sections, tables, config examples,
  and edge case documentation. Replace the "2–6 sentences" guidance with "match the
  depth of a professional game design document or software architecture document."

Acceptance criteria:
- `_extract_template_sections()` outputs `NAME|REQUIRED|GUIDANCE|PHASE` format
- Interview displays phase headers: "Phase 1: Concept", "Phase 2: Deep Dive",
  "Phase 3: Architecture"
- Phase 2 questions show a summary of Phase 1 answers as context
- Synthesis prompt instructs Claude to produce sub-sections, tables, and config
  examples — not just prose paragraphs
- Interrupting mid-Phase 2 preserves all Phase 1 answers and produces a partial
  but valid DESIGN.md from what was collected
- All tests pass (`bash tests/run_tests.sh`)

#### Milestone 3: Generation Prompt Overhaul for Deep CLAUDE.md
Rewrite the CLAUDE.md generation prompt to produce output matching the Lönn CLAUDE.md
structure. The current prompt produces 6 generic sections. The gold standard has ~15
sections with config examples, behavioral rules, milestone details, and code conventions.

Files to modify:
- `prompts/plan_generate.prompt.md` — full rewrite with expanded required sections
- `stages/plan_generate.sh` — increase `PLAN_GENERATION_MAX_TURNS` default from 30
  to 50 (opus needs more turns for deep output)
- `lib/plan.sh` — update default `PLAN_GENERATION_MAX_TURNS` to 50

New required sections in CLAUDE.md (generation prompt must mandate all of these):

1. **Project Identity** — name, description, tech stack, platform, monetization model
2. **Architecture Philosophy** — concrete patterns and principles derived from the
   Developer Philosophy section of DESIGN.md. Not generic platitudes — specific to
   this project's tech stack and constraints.
3. **Repository Layout** — full tree with every directory and key file annotated.
   Inferred from tech stack and architecture decisions.
4. **Key Design Decisions** — resolved ambiguities from DESIGN.md. Each as a titled
   subsection with a canonical ruling and rationale.
5. **Config Architecture** — config format, loading strategy, example structures
   with actual keys and default values from DESIGN.md.
6. **Non-Negotiable Rules** — 10–20 behavioral invariants the system must enforce.
   Derived from constraints, edge cases, and interaction rules in DESIGN.md. Each
   rule is specific and testable, not generic.
7. **Implementation Milestones** — 6–12 milestones, each containing:
   - Title and scope paragraph
   - Bullet list of specific deliverables
   - `Files to create or modify:` with concrete paths from Repository Layout
   - `Tests:` block — what to test and how
   - `Watch For:` block — gotchas, edge cases, integration risks
   - `Seeds Forward:` block — what later milestones depend on from this one
   - Each milestone must work as a standalone task for `tekhton "Implement Milestone N"`
8. **Code Conventions** — naming, file organization, testing requirements, git workflow,
   state management pattern. Specific to this project's language and framework.
9. **Critical System Rules** — numbered list of invariants the implementation must
   enforce. Violating any is a bug.
10. **What Not to Build Yet** — explicitly deferred features with rationale.
11. **Testing Strategy** — frameworks, coverage targets, test categories, commands.
12. **Development Environment** — expected setup, dependencies, build commands.

Acceptance criteria:
- Generation prompt mandates all 12 sections in the specified order
- Milestone format in the prompt includes Seeds Forward and Watch For blocks
- Default `PLAN_GENERATION_MAX_TURNS` is 50 in `lib/plan.sh`
- Prompt instructs Claude to produce config examples with actual keys from DESIGN.md
- Prompt instructs Claude to derive 10–20 non-negotiable rules, not 5–10
- Prompt instructs Claude to number milestones and include file paths
- All tests pass (`bash tests/run_tests.sh`)

#### Milestone 4: Follow-Up Interview Depth + Completeness Checker Upgrade
Upgrade the completeness checker to enforce depth thresholds — not just "is the
section non-empty" but "does the section have enough content to drive implementation?"
Upgrade the follow-up interview to probe for missing depth.

Files to modify:
- `lib/plan_completeness.sh` — add depth scoring: count lines, sub-headings, tables,
  and config blocks per section. A required section with fewer than N lines (configurable,
  default: 5) or zero sub-sections for system-type sections is flagged as shallow.
- `prompts/plan_interview_followup.prompt.md` — rewrite to instruct Claude to focus on
  expanding shallow sections: add sub-sections, edge cases, config examples, interaction
  notes, and balance/design warnings.
- `stages/plan_interview.sh` — update `run_plan_followup_interview()` to present the
  current section content to the user as context, so they can see what was already written
  and add what's missing rather than starting from scratch.

Acceptance criteria:
- Completeness checker flags required sections with fewer than 5 lines as `SHALLOW`
- Completeness checker flags system sections lacking any `###` sub-headings as `SHALLOW`
- Follow-up interview shows existing section content before asking for additions
- Follow-up synthesis prompt instructs Claude to expand (not replace) existing content
- A section that passes the depth check on re-run is not re-prompted
- All tests pass (`bash tests/run_tests.sh`)

#### Milestone 5: Tests + Documentation Update
Write tests covering the new multi-phase interview, deep templates, expanded
completeness checking, and generation prompt changes. Update project documentation.

Files to create or modify:
- `tests/test_plan_templates.sh` — add checks for section count minimums (20+ for
  web-game, 15+ for others), Developer Philosophy presence, Config Architecture presence,
  PHASE marker parsing
- `tests/test_plan_completeness.sh` — add depth-scoring tests: shallow sections flagged,
  deep sections pass, line-count thresholds respected
- `tests/test_plan_interview_stage.sh` — add phase-header assertions, multi-phase
  flow test, context display between phases
- `tests/test_plan_interview_prompt.sh` — update assertions for new prompt content
  (sub-sections, tables, config examples instructions)
- `tests/test_plan_generate_stage.sh` — verify increased max turns default
- `CLAUDE.md` — update Template Variables table defaults (opus, max turns)
- `README.md` — update `--plan` documentation with examples of expected output depth

Acceptance criteria:
- Template depth tests verify section counts per template type
- Completeness depth tests verify shallow-section detection
- Phase-marker parsing tests verify `_extract_template_sections()` fourth field
- All 34+ existing tests continue to pass
- New tests pass via `bash tests/run_tests.sh`
- `bash -n` passes on all modified `.sh` files
