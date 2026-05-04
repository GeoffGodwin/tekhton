# Milestone 80: --draft-milestones — Interactive Milestone Authoring Flow
<!-- milestone-meta
id: "80"
status: "done"
-->

## Overview

Developer feedback: "I have an informal process when I want to add new
milestones — I discuss the idea with an LLM, clarify what I want, have
it look at the codebase, decide whether it should be split into
multiple milestones, then generate them. Tekhton should bake this
process in as a feature."

Today `tekhton --add-milestone "<desc>"` exists (tekhton.sh:1252,
`run_intake_create` at stages/intake.sh:222) but it's **non-interactive**
— it takes a one-line description and hands it to the intake agent in
CREATE_MODE. That's a 10-second convenience, not a collaborative design
session. Users skip it and either write milestones by hand or paste
them into Claude Desktop.

M80 **replaces** `--add-milestone` with `--draft-milestones` — an
interactive, multi-phase conversational flow:

1. **Clarify.** Ask 2–4 targeted questions about what the user wants.
2. **Analyze.** Use the repo map + Serena (if enabled) to survey
   existing code the milestone will touch.
3. **Propose.** Come back with "I think this is N milestones, split as
   A / B / C because …" for user confirmation.
4. **Generate.** On approval, write N milestone files in
   `.claude/milestones/` and add rows to `MANIFEST.cfg`.

The old `--add-milestone` flag is kept as a deprecated alias that prints
a warning and forwards to the new flow.

## Design Decisions

### 1. New flag, old flag deprecated

```bash
tekhton --draft-milestones              # fully interactive
tekhton --draft-milestones "initial idea" # seed with an idea
tekhton --add-milestone "..."            # deprecated alias, forwards to above
```

The deprecation warning points at `--draft-milestones` and explains the
rename. Alias stays one release cycle, removed in a future milestone.

### 2. Agent is driven by a single prompt template

New `prompts/draft_milestones.prompt.md` structures a 4-phase
conversation:

```markdown
Phase 1 — Clarify
  - Ask the user 2–4 questions about the goal, scope, and constraints.
  - One question at a time. Wait for answers.

Phase 2 — Analyze
  - Use the repo map / Serena / file reads to understand what's there.
  - Produce a 1-paragraph "state of the relevant code" summary.

Phase 3 — Propose
  - Propose a milestone split: N milestones, each with a name, 1-line
    goal, and dependency on the previous. Explain why you split this
    way.
  - Pause for user confirmation: "does this look right?"
  - Accept revisions (merge 2+3, split 1, rename) as conversation.

Phase 4 — Generate
  - Write each milestone file using the same template as the
    .claude/milestones/ files in this repo.
  - Emit MANIFEST.cfg rows.
  - Summarize what was written.
```

The prompt template reads existing milestone files (`m70-*` through
`m72-*`) as formatting exemplars — consistent output without hardcoding
the schema in the prompt.

### 3. New lib: lib/draft_milestones.sh

```bash
run_draft_milestones              # entry point — parses optional seed,
                                  # invokes agent, handles phase transitions
                                  # (matches Tekhton's run_* convention for
                                  # CLI-facing entry points — see stages/*.sh)
draft_milestones_build_prompt     # assembles prompt with repo map slice
draft_milestones_validate_output  # checks that generated files parse as
                                  # milestone files with proper metadata
draft_milestones_write_manifest   # appends new rows to MANIFEST.cfg
draft_milestones_next_id          # pure helper — returns next free milestone ID
```

Stays ≤ 300 lines. The heavy lifting is in the agent prompt, not the
bash glue.

### 4. Config surface

```bash
: "${DRAFT_MILESTONES_MODEL:=$CLAUDE_STANDARD_MODEL}"  # opus default
: "${DRAFT_MILESTONES_MAX_TURNS:=40}"                  # generous — it's interactive
: "${DRAFT_MILESTONES_AUTO_WRITE:=false}"              # require confirmation
: "${DRAFT_MILESTONES_SEED_EXEMPLARS:=3}"              # how many recent milestones
                                                       # to show as format examples
```

Opus by default because milestone design rewards thinking. User can
downgrade via `DRAFT_MILESTONES_MODEL=claude-sonnet-4-6` for cheaper runs.

### 5. Next milestone ID detection

Scan `.claude/milestones/m*.md` and `MANIFEST.cfg`, pick max ID + 1.
If the split produces N milestones they take IDs max+1 through max+N.
`lib/draft_milestones.sh` exposes `draft_milestones_next_id N` for
this.

### 6. Repo map integration

The agent gets a **context-compiled slice** of the repo map — not the
full thing. If the user says "add a metrics dashboard for test flake
rate," we pass only the slice relevant to metrics + tests, not the
entire codebase. Reuses the existing context compiler from M47 / M67
(see `lib/context_compiler.sh`).

If repo map / Serena are disabled, the agent falls back to `ls -la` +
`head` reads — degraded but functional. Document the fallback in the
prompt.

### 7. Write gate — never silent

After the agent proposes the split, it MUST print the exact file paths
it intends to write and wait for user confirmation:

> I'll write:
>   .claude/milestones/m82-foo.md
>   .claude/milestones/m83-bar.md
> And add 2 rows to MANIFEST.cfg.
>
> Proceed? [y/N]

`DRAFT_MILESTONES_AUTO_WRITE=true` bypasses the prompt (for scripting)
— default is false. The goal is zero-surprise generation.

### 8. Validate output before committing

`draft_milestones_validate_output` checks each generated file:

- Has an H1 heading `# Milestone NN: Title`.
- Has a `<!-- milestone-meta -->` block with `id:` and `status:`.
- Has sections: Overview, Design Decisions, Scope Summary,
  Implementation Plan, Files Touched, Acceptance Criteria.
- Has at least 5 items in Acceptance Criteria.

If validation fails, print the errors and leave the files in place but
don't update MANIFEST.cfg. User can fix and re-run (idempotent: the
manifest writer skips IDs that already have rows).

### 9. Watchtower hook — seed for future

Add a stub `emit_draft_milestones_data` in `lib/dashboard.sh` that
emits `.tekhton/dashboard/draft_milestones_pending.json` listing any
in-progress draft sessions. This is a 10-line stub — the Watchtower UI
integration ("Draft milestones from Watchtower") is a future V4
milestone. Stub is here so the data file exists by the time Watchtower
wants to read it.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| New libs | 1 | `lib/draft_milestones.sh` |
| New prompts | 1 | `prompts/draft_milestones.prompt.md` |
| Replaced CLI flag | 1 | `--add-milestone` → `--draft-milestones` (alias kept) |
| New config vars | 4 | DRAFT_MILESTONES_* |
| New template vars | 4 | Mirrored |
| Dashboard stub | 1 | `emit_draft_milestones_data` |
| Tests | 2 | Flow smoke test + validation test |
| Files modified | 4 | `tekhton.sh`, `lib/config_defaults.sh`, `lib/prompts.sh`, `lib/dashboard.sh` |

## Implementation Plan

### Step 1 — Config scaffolding

Edit `lib/config_defaults.sh` — add four `DRAFT_MILESTONES_*` vars from
decision #4. Edit `lib/prompts.sh` — register as template vars. Run
`bash tests/run_tests.sh`. Must pass unchanged — no behavior yet.

### Step 2 — Library skeleton

Create `lib/draft_milestones.sh` with function signatures and a no-op
body. Make `draft_milestones_next_id` functional immediately since it's
pure (glob + max). Unit-test it via a tiny fixture.

### Step 3 — Prompt template

Write `prompts/draft_milestones.prompt.md` covering all 4 phases. Read
existing milestones m70 / m71 / m72 / m73 as formatting exemplars. The
template is ≤ 200 lines. Use existing `{{VAR}}` substitution for
project name, repo map slice, exemplar milestones, next milestone ID.

### Step 4 — Agent invocation

Wire `run_draft_milestones` in `lib/draft_milestones.sh` to call
`run_agent` (from `lib/agent.sh`) with the rendered prompt. Pass the
user's seed description (if any) as the initial user turn. (Entry-point
naming follows the Tekhton `run_*` convention — see `run_intake_create`,
`run_stage_coder`, etc.)

Capture the agent's stdout — phase transitions are marked by agent
outputting known sigils (`[PHASE:PROPOSE]`, `[PHASE:GENERATE]`) that
the shell wrapper watches for.

### Step 5 — Output validation

Implement `draft_milestones_validate_output`. Uses awk + grep on the
proposed file list to assert each acceptance criterion from decision #8.
Return non-zero if any fail. Write validation errors to
`.tekhton/draft_milestones_errors.log`.

### Step 6 — Manifest writer

`draft_milestones_write_manifest` reads the proposed milestone IDs,
checks for duplicates, and appends pipe-delimited rows to
`MANIFEST.cfg`. Dependency detection: the first proposed milestone
depends on the highest-numbered existing milestone; subsequent
proposed milestones depend on the previous one.

### Step 7 — Wire the CLI

Edit `tekhton.sh`:

1. Add `--draft-milestones` to the argument parser (near line 1252).
2. Update `--add-milestone` to print a deprecation warning and call
   the same handler.
3. Update `usage()` help block.

```bash
--draft-milestones)
    shift
    local seed="${1:-}"
    [[ -n "$seed" ]] && shift
    run_draft_milestones "$seed"
    _TEKHTON_CLEAN_EXIT=true
    exit 0
    ;;
--add-milestone)
    warn "--add-milestone is deprecated. Use --draft-milestones for the new interactive flow."
    shift
    local seed="${1:-}"
    [[ -n "$seed" ]] && shift
    run_draft_milestones "$seed"
    _TEKHTON_CLEAN_EXIT=true
    exit 0
    ;;
```

### Step 8 — Dashboard stub

Add `emit_draft_milestones_data` to `lib/dashboard.sh`. 10 lines:
scan `.tekhton/draft_sessions/*.json`, emit a summary. If directory
doesn't exist, emit an empty JSON array. Hooked into the existing
dashboard emission sequence.

### Step 9 — Tests

Create `tests/test_draft_milestones_next_id.sh`:
- Empty manifest → next ID is 1.
- Manifest with m01–m72 → next ID is 73.
- Three-milestone split starting at 73 → returns 73, 74, 75.

Create `tests/test_draft_milestones_validate.sh`:
- Well-formed milestone file → passes.
- Missing Acceptance Criteria section → fails with explicit message.
- Missing `<!-- milestone-meta -->` → fails.

Wire both into `tests/run_tests.sh`.

### Step 10 — Shellcheck + tests + version bump

```bash
shellcheck lib/draft_milestones.sh tekhton.sh
bash tests/run_tests.sh
```

Edit `tekhton.sh` — `TEKHTON_VERSION="3.80.0"`.
Edit manifest — M80 row with `depends_on=m79`, group `devx`.

Note on dependency: `depends_on=m79` not `m72`. M79 stubs
`docs/MILESTONES.md`; M80 populates it with a user-facing description
of the flow. Keeping the linear devx chain tight.

## Files Touched

### Added
- `lib/draft_milestones.sh`
- `prompts/draft_milestones.prompt.md`
- `tests/test_draft_milestones_next_id.sh`
- `tests/test_draft_milestones_validate.sh`
- `.claude/milestones/m80-draft-milestones-interactive-flow.md` — this file

### Modified
- `tekhton.sh` — add `--draft-milestones` flag, deprecate
  `--add-milestone` alias, source `lib/draft_milestones.sh`, bump version
- `lib/config_defaults.sh` — four `DRAFT_MILESTONES_*` vars
- `lib/prompts.sh` — register as template vars
- `lib/dashboard.sh` — `emit_draft_milestones_data` stub
- `docs/MILESTONES.md` — populate with user-facing description
- `tests/run_tests.sh` — register new tests
- `.claude/milestones/MANIFEST.cfg` — M80 row

## Acceptance Criteria

- [ ] `--draft-milestones` flag exists in `tekhton.sh` and runs the
      interactive flow
- [ ] `--add-milestone` is deprecated but still functional — prints
      warning and forwards to `--draft-milestones`
- [ ] `lib/draft_milestones.sh` exists, is ≤ 300 lines, passes
      shellcheck with zero warnings
- [ ] `prompts/draft_milestones.prompt.md` exists and defines 4 phases
      (Clarify, Analyze, Propose, Generate)
- [ ] Config has four `DRAFT_MILESTONES_*` vars with correct defaults
- [ ] `DRAFT_MILESTONES_AUTO_WRITE` defaults to `false` — user must
      confirm before files are written
- [ ] Agent uses the repo map slice for analysis when available, falls
      back to ls + head reads when disabled
- [ ] `draft_milestones_next_id` correctly identifies the next ID by
      scanning `.claude/milestones/m*.md` + `MANIFEST.cfg`
- [ ] `draft_milestones_validate_output` rejects files missing any
      required section
- [ ] `draft_milestones_write_manifest` appends rows with correct
      dependency chaining
- [ ] Failed validation leaves files in place but skips MANIFEST
      update
- [ ] `emit_draft_milestones_data` stub exists in `lib/dashboard.sh`
- [ ] `docs/MILESTONES.md` exists with user-facing flow description
- [ ] `tests/test_draft_milestones_next_id.sh` passes all scenarios
- [ ] `tests/test_draft_milestones_validate.sh` passes all scenarios
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `tekhton.sh` `TEKHTON_VERSION` is `3.80.0`
- [ ] `.claude/milestones/MANIFEST.cfg` contains the M80 row
      (`depends_on=m79`, group `devx`)

## Watch For

- **Phase sigils must be grep-visible.** The shell wrapper watches for
  `[PHASE:PROPOSE]` and `[PHASE:GENERATE]` in agent stdout. The prompt
  must instruct the model to emit these exact strings — no variations.
  Test with at least one dry-run invocation before declaring victory.
- **Don't bypass the confirmation.** Default is `AUTO_WRITE=false`. A
  user who runs `--draft-milestones` without setting the env var MUST
  see the confirmation prompt. CI-friendly scripting uses the env
  override explicitly.
- **Interactive flows are hard to test.** The two listed tests cover
  the pure functions (next-ID, validation). A real end-to-end flow
  test would need stdin mocking — skip it. Document the manual test
  procedure in `docs/MILESTONES.md` instead.
- **Dependency auto-wiring is naive.** The manifest writer assumes
  linear dependencies. If the user's split really is a DAG (M82a + M82b
  in parallel depending on M81), the writer will mis-wire them. Accept
  this — a future milestone can add DAG detection. For now, the prompt
  should nudge toward linear chains.
- **Alias deprecation timing.** Don't remove `--add-milestone` in this
  milestone. Keep the alias for one release. Removal is a seed-forward
  item.
- **Exemplar milestone leakage.** The prompt shows m70/m71/m72/m73 as
  format exemplars. If those files are 500+ lines each (they are),
  the prompt burns a LOT of tokens. Option 1: show just the first 100
  lines of each. Option 2: show a single "canonical" exemplar. Pick
  option 1 — it captures structure without bloating context.
- **Repo map slice scope.** The slice is computed from the seed
  description, not from the clarify-phase answers. If the user's clarify
  answers reveal the slice is wrong, the analysis phase may proceed
  on outdated context. Acceptable — the agent can ask for more reads
  if it needs them.
- **File-length guardrail.** `lib/draft_milestones.sh` must stay ≤ 300
  lines. If it grows, split into `lib/draft_milestones_write.sh` and
  `lib/draft_milestones_validate.sh`.
- **Security consideration.** The agent writes files under
  `.claude/milestones/`. Validate the milestone IDs are integers and
  the filenames match `m[0-9]+-[a-z0-9-]+\.md`. Never let the agent
  write outside that directory — enforce in `draft_milestones_write_manifest`.
- **Don't re-use intake CREATE_MODE.** `run_intake_create` in
  `stages/intake.sh:222` is the old flow. Leave it alone for the
  deprecation window. The new flow is a completely separate code path.

## Seeds Forward

- **Watchtower integration.** The stub dashboard emitter is step 1.
  Step 2 (future) is a Watchtower UI panel "Draft new milestones" that
  launches the flow and streams phase transitions to the dashboard.
  Moves Tekhton closer to the user's stated "do anything from
  Watchtower" goal.
- **Remove `--add-milestone` alias.** Once the deprecation cycle ends
  (one release), remove the alias and its handler. Small follow-up.
- **DAG-aware splits.** The current manifest writer chains linearly.
  A future milestone could let the proposal phase suggest parallel
  groups ("M82a and M82b can run in parallel, both depend on M81").
- **Rework an existing milestone.** A `--redraft-milestone m73` flow
  could re-run the interactive session on an existing milestone file
  to refine it without starting from scratch. Out of scope; users can
  edit files manually.
- **Milestone templates by project type.** Just like plan templates
  (library / cli-tool / web-app), milestone templates could be
  type-specific. A game project's milestone might default to a
  "Playtesting" section. Out of scope — the current flow is
  intentionally uniform.
- **Browser-based version.** M32 shipped browser-based plan interviews.
  A future milestone could put `--draft-milestones` in the browser too
  — useful for teams that don't live in a terminal. Out of scope.
