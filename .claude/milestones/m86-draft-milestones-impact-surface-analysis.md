# Milestone 86: Draft Milestones Impact Surface Analysis
<!-- milestone-meta
id: "86"
status: "pending"
-->

## Overview

The M72 post-mortem showed that the `draft_milestones.prompt.md` Phase 2
(Analyze) instructs the agent to "survey the relevant code" and "understand
what exists today" but provides no specific guidance on exhaustive discovery.
The agent analyzed what it expected to find (known `_FILE` variables) rather
than discovering everything that was actually affected.

This milestone enhances the draft milestones prompt to require:
1. An **Impact Surface Scan** — explicit grep-based discovery of all affected
   code sites, including prompt templates and tests
2. A **Negative Space** section — documentation of what is intentionally NOT
   changed, forcing the author to confront the complete scope
3. **Behavioral acceptance criteria** — at least one criterion that observes
   runtime behavior, not just code structure
4. **Prompt template audit** — treating prompts as code sites that can contain
   write instructions (literal filenames agents are told to create)
5. **Self-referential check** — for milestones affecting configuration or
   file paths, checking Tekhton's own config files

## Design Decisions

### 1. Enhance Phase 2, not add a new phase

The impact surface scan is part of analysis, not a separate phase. Adding a
fifth phase would change the pipeline's phase tracking and introduce
unnecessary complexity. Instead, Phase 2 gets explicit sub-steps.

### 2. Prescriptive grep commands, not vague instructions

The prompt changes include actual example grep patterns, not just "search
thoroughly." For example: "Run `grep -rn 'LITERAL_NAME' lib/ stages/ prompts/`
for every file that the milestone creates, reads, or modifies." Specific
instructions produce specific results.

### 3. Negative Space is a required section, not optional

The milestone template adds `## Negative Space` as a required section (alongside
Overview, Design Decisions, etc.). This forces the milestone author to explicitly
think about and document what is out of scope. An empty Negative Space section
is a lint warning.

### 4. Acceptance criteria template includes both types

The criteria template section adds explicit guidance: "Include at least one
behavioral criterion that verifies runtime behavior (e.g., 'running the
pipeline produces no files at location X'), not just structural criteria
(e.g., 'grep returns zero hits')."

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Prompt file modified | 1 | `prompts/draft_milestones.prompt.md` |
| New sections in template | 2 | Negative Space, Impact Surface sub-steps |
| Criteria guidance added | 1 | Behavioral + structural balance requirement |

## Implementation Plan

### Step 1 — Enhance Phase 2 (Analyze)

Add an "Impact Surface Scan" sub-section to Phase 2 with these explicit
instructions:

```markdown
#### Impact Surface Scan

Before proposing milestones, identify EVERY code site affected by the change:

1. **Shell code:** `grep -rn 'PATTERN' lib/ stages/` for every file, variable,
   or path the milestone will create, modify, or reference. Include both the
   target name AND any aliases, abbreviations, or dynamic constructions.
2. **Prompt templates:** `grep -rn 'PATTERN' prompts/` — prompts instruct agents
   to read/write files. A literal filename in a prompt is a write-site.
3. **Test files:** `grep -rn 'PATTERN' tests/` — tests that reference affected
   paths must be updated.
4. **Config files:** Check `lib/config_defaults.sh` and pipeline.conf examples
   for variables or defaults that reference affected paths.

Document the complete hit count. If the change touches file paths, grep for
`$PROJECT_DIR/` and `${PROJECT_DIR}/` concatenated with literal filenames.
```

### Step 2 — Add Negative Space section to template

Add `## Negative Space` to the required sections list:

```markdown
## Negative Space
(Items explicitly NOT included in this milestone, with justification for each.
If this milestone renames, moves, or parameterizes items, list every item of
the same class that is intentionally left unchanged and explain why.)
```

### Step 3 — Enhance acceptance criteria guidance

Add to the criteria section template:

```markdown
## Acceptance Criteria
(Minimum 5 items as `- [ ] criterion`)

**Required criterion types:**
- At least one **behavioral** criterion: verifies actual runtime behavior
  (e.g., "running X produces no files at Y", "pipeline output contains Z")
- At least one **structural** criterion: verifies code patterns
  (e.g., "grep for X returns zero hits")
- For refactor/migration milestones: a **completeness** criterion that
  searches for remaining un-migrated references
- For config/path milestones: a **self-referential** criterion that checks
  Tekhton's own pipeline.conf and any example configs
```

### Step 4 — Add prompt template audit to Rules

Add to the Rules section:

```markdown
9. **Treat prompt templates as code sites.** Files in `prompts/*.prompt.md`
   instruct agents to create, read, and write files. If a milestone changes
   a file path or name, every prompt that references it must be updated.
   Grep `prompts/` alongside `lib/` and `stages/`.
```

### Step 5 — Shellcheck and test

Verify no template syntax errors; run full test suite.

## Files Touched

### Modified
- `prompts/draft_milestones.prompt.md` — Phase 2 enhancement, Negative Space
  section, acceptance criteria guidance, prompt audit rule

## Acceptance Criteria

- [ ] Phase 2 in `draft_milestones.prompt.md` includes an "Impact Surface Scan" sub-section with explicit grep instructions
- [ ] The milestone template includes `## Negative Space` as a required section
- [ ] The acceptance criteria template requires at least one behavioral criterion
- [ ] The acceptance criteria template requires a completeness criterion for refactor milestones
- [ ] The acceptance criteria template requires a self-referential check for config milestones
- [ ] Rule 9 (prompt template audit) is present in the Rules section
- [ ] **Behavioral:** An agent given the enhanced prompt and an M72-equivalent task would be instructed to grep for `PROJECT_DIR.*\.md` patterns that would surface DRIFT_ARCHIVE.md and PROJECT_INDEX.md
- [ ] No shellcheck warnings on any modified files
- [ ] `bash tests/run_tests.sh` passes
