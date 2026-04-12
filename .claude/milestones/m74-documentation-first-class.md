# Milestone 74: Documentation as a First-Class Pipeline Concern
<!-- milestone-meta
id: "74"
status: "done"
-->

## Overview

Tekhton currently treats project documentation (README, `docs/`) as a
post-facto health check (`HEALTH_WEIGHT_DOCS=15`) rather than a commitment
the pipeline actively maintains. This shows up in three places:

1. **Planning phase.** Only `templates/plans/library.md` has a
   `## Documentation Strategy` section — and even there the section is
   *not* marked `<!-- REQUIRED -->`, so the completeness checker
   (`lib/plan_completeness.sh`) never scores it. Six of seven project-type
   templates (`cli-tool.md`, `web-app.md`, `api-service.md`, `mobile-app.md`,
   `web-game.md`, `custom.md`) don't even mention docs.
2. **CLAUDE.md generation.** `prompts/plan_generate.prompt.md` (lines 60–275)
   requires 12 sections in the generated `CLAUDE.md`. None of them is a
   Documentation section. Line 98 has a passing mention of "documentation
   locations" as an annotation in the Repository Layout tree — that's it.
3. **Per-milestone acceptance.** `lib/milestone_acceptance.sh` has zero
   references to `README`, `docs/`, or `documentation`. Neither
   `prompts/coder.prompt.md` nor `prompts/reviewer.prompt.md` requires doc
   updates when a coder touches a public surface. The only coder mention of
   "documentation" is at line 199 of `coder.prompt.md` and it's about
   system-design contradictions, not README maintenance.

Result: projects built with Tekhton ship working code whose `README.md` and
`docs/` drift further out of date with each milestone.

This milestone is the **bake-in** fix — no new agent, no new stage. We make
documentation a required concern at three existing touchpoints:

1. **Plan interview** asks about docs strategy (all templates, `<!-- REQUIRED -->`
   marker).
2. **Coder prompt** says "if you changed a public surface, update the README
   or `docs/` page that describes it."
3. **Reviewer prompt** adds "docs freshness" to the review checklist and
   flags missing doc updates as a non-blocking finding by default, blocking
   when `DOCS_STRICT_MODE=true`.

A follow-up milestone (**M75**) will add the optional dedicated Haiku docs
agent that runs between coder and reviewer. M74 is the prerequisite: M75's
coder handoff depends on the coder having flagged its public-surface
changes in `CODER_SUMMARY.md`, which is part of what M74 adds.

## Design Decisions

### 1. Scope of "documentation"

For this milestone, "documentation" means three concrete artifacts:

- `README.md` at the project root.
- Anything under `docs/` (Markdown).
- Any auto-generated API reference config (`typedoc.json`, `mkdocs.yml`,
  `sphinx.conf`, `rustdoc` comments, `javadoc` comments). We do not
  auto-generate the reference — we only flag when the source it reads from
  has drifted.

Release notes / CHANGELOG are **not** included — that's M77's territory and
fits under the versioning initiative rather than documentation.

### 2. The plan interview asks four questions

Added to the plan interview (Phase 2 — System, matching the existing
PHASE:2 sections in the templates):

1. **Does this project ship user-facing documentation?** (yes / no / just a
   README / README + docs/ site)
2. **Where is documentation hosted?** (GitHub README only, GitHub Pages,
   ReadTheDocs, docs.rs, mkdocs Material, other)
3. **What must be updated on every feature change?** (README + relevant
   `docs/` page; README only; docs/ site only)
4. **Do you want Tekhton to enforce doc freshness during review?**
   (strict = block merge, warn = non-blocking finding, off)

Answers get written into DESIGN.md under the new `## Documentation Strategy`
section, then synthesized into CLAUDE.md under the same header in M74's new
13th required section.

### 3. Plan templates — all seven get the section

Add `## Documentation Strategy` with the `<!-- REQUIRED -->` marker to each
`templates/plans/*.md` file. The content template mirrors what's already in
`library.md:148-154` but generalized: API reference hosting, which surfaces
are documented, tutorial-vs-reference split, doc testing strategy.

`library.md`'s existing section gets the `<!-- REQUIRED -->` marker (it was
missing) but otherwise stays as-is.

### 4. CLAUDE.md gains a 13th required section: "Documentation Responsibilities"

Edit `prompts/plan_generate.prompt.md` — after section 12 ("Development
Environment"), add section 13:

```
### 13. Documentation Responsibilities
- Which files/directories are the project's documentation sources
  (README.md, docs/, etc.)
- Who owns doc updates (the feature author, a docs owner, auto-generated)
- When docs must be updated: per feature? per milestone? per release?
- What "public surface" means for this project (exported API, CLI flags,
  config keys, schema, UI routes, …)
- Doc freshness policy: strict (block) / warn / off
```

The count on line 56 of `plan_generate.prompt.md` changes from "12 required
sections" to "13 required sections."

### 5. Coder prompt — public-surface-touch clause

Add a short rule to `prompts/coder.prompt.md` under the existing
"Definition of Done" / output contract area. Pattern:

> **Public-surface changes require doc updates.** If your change adds,
> removes, or changes the signature/behavior of something users can
> observe — a CLI flag, an exported function, a config key, a REST
> endpoint, a schema — locate the existing README or `docs/` page that
> documents it and update that page in the same commit. If no such doc
> exists and the project's CLAUDE.md says docs are required, create one.
> List every doc file you touched under a `## Docs Updated` subsection of
> `{{CODER_SUMMARY_FILE}}`.

The `## Docs Updated` marker is the handoff to M75's docs agent (if
enabled) and to M74's reviewer check (always enabled).

### 6. Reviewer prompt — docs freshness checklist item

Add a line to `prompts/reviewer.prompt.md`'s checklist area:

> **Documentation freshness.** Check whether this change touches a public
> surface described in CLAUDE.md's Documentation Responsibilities section.
> If so, confirm the coder updated the relevant doc (look for a
> `## Docs Updated` section in `{{CODER_SUMMARY_FILE}}`). If the coder
> says docs are required but didn't update any, report it at severity
> `WARN` (or `BLOCK` if `{{DOCS_STRICT_MODE}}` is `true`).

### 7. Minimal new config surface

Four new variables in `lib/config_defaults.sh`:

```bash
: "${DOCS_ENFORCEMENT_ENABLED:=true}"   # Master toggle for M74 behavior
: "${DOCS_STRICT_MODE:=false}"          # Reviewer blocks on missing doc update
: "${DOCS_DIRS:=docs/}"                 # Colon-separated list of doc dirs
: "${DOCS_README_FILE:=README.md}"      # Path to primary README (brownfield override)
```

Expose as template variables via `lib/prompts.sh`.

### 8. Plan completeness scoring

Edit `lib/plan_completeness.sh` to recognize the new required section. The
existing mechanism reads `<!-- REQUIRED -->` markers — once the section is
added to the templates with that marker, the scorer picks it up
automatically. We only need to verify the scorer hits the new section, not
extend it.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Plan templates updated | 7 | All of `templates/plans/*.md` get the REQUIRED section |
| Prompt files modified | 4 | `plan_interview.prompt.md`, `plan_generate.prompt.md`, `coder.prompt.md`, `reviewer.prompt.md` |
| New config variables | 4 | `DOCS_ENFORCEMENT_ENABLED`, `DOCS_STRICT_MODE`, `DOCS_DIRS`, `DOCS_README_FILE` |
| New template variables | 4 | Mirrored from config |
| New CLAUDE.md required sections | 1 | Section 13 — Documentation Responsibilities |
| Tests added | 1 | `tests/test_plan_docs_section.sh` — scorer recognizes new REQUIRED section |
| lib/ files modified | 3 | `config_defaults.sh`, `prompts.sh`, `plan_completeness.sh` (validation only) |

## Implementation Plan

### Step 1 — Config + template variable scaffolding

Edit `lib/config_defaults.sh`:

```bash
# --- Documentation enforcement (M74) ---
# Tekhton treats README/docs as first-class artifacts. When enabled, the plan
# interview asks about docs strategy, the coder is told to update public-surface
# docs in-commit, and the reviewer flags missing doc updates.
: "${DOCS_ENFORCEMENT_ENABLED:=true}"
: "${DOCS_STRICT_MODE:=false}"
: "${DOCS_DIRS:=docs/}"
: "${DOCS_README_FILE:=README.md}"
```

Edit `lib/prompts.sh` template-variable registry — add all four vars so
`{{DOCS_STRICT_MODE}}`, `{{DOCS_DIRS}}`, `{{DOCS_README_FILE}}`, and
`{{DOCS_ENFORCEMENT_ENABLED}}` render correctly in prompts.

### Step 2 — Update all 7 plan templates

For each of `templates/plans/{cli-tool,web-app,api-service,mobile-app,web-game,custom}.md`:

Add after the existing "Versioning & Release Strategy" or equivalent Phase 2
section (or if absent, between the System and Architecture phases):

```markdown
## Documentation Strategy
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- What documentation does this project ship? (README only, README + docs/ site, API reference site) -->
<!-- Where is documentation hosted? (GitHub, GitHub Pages, ReadTheDocs, docs.rs, mkdocs Material) -->
<!-- What surfaces must be documented? (CLI flags, REST endpoints, exported library API, UI features, config keys) -->
<!-- On every feature change, which docs must be updated in the same commit? -->
<!-- Is doc freshness strict (block the merge) or warn-only? -->
<!-- Any auto-generation tooling? (typedoc, sphinx, rustdoc, javadoc, pydoc) -->
```

For `templates/plans/library.md`: the section already exists — just add
`<!-- REQUIRED -->` as the first comment line.

### Step 3 — Plan interview prompt

Edit `prompts/plan_interview.prompt.md` and `prompts/plan_interview_followup.prompt.md`
so Phase 2 includes the four docs questions listed in Design Decision #2.
The prompts already walk through PHASE:2 sections template-by-template —
adding the new section is consistent with the existing loop.

### Step 4 — CLAUDE.md generation prompt adds 13th section

Edit `prompts/plan_generate.prompt.md`:

1. Line 56: change "all 12 required sections" to "all 13 required sections."
2. After section 12 ("Development Environment") insert section 13
   ("Documentation Responsibilities") — content per Design Decision #4.

### Step 5 — Coder prompt — public-surface clause

Edit `prompts/coder.prompt.md`. Add the "Public-surface changes require
doc updates" clause from Design Decision #5 to the coder's Definition of
Done. Add a matching instruction: "Record every doc file you touched under
a `## Docs Updated` subsection of `{{CODER_SUMMARY_FILE}}`."

### Step 6 — Reviewer prompt — docs freshness checklist

Edit `prompts/reviewer.prompt.md`. Add the "Documentation freshness"
checklist item per Design Decision #6. Use the template variable
`{{DOCS_STRICT_MODE}}` so the reviewer knows whether to block or warn.

### Step 7 — Milestone acceptance checker (light touch only)

`lib/milestone_acceptance.sh` does NOT get per-milestone docs-update
enforcement in this milestone. The reviewer checks docs freshness per-coder-run
already; re-checking at milestone acceptance would be double counting.
We do one lightweight change: if `DOCS_STRICT_MODE=true` and the
reviewer reported a BLOCK-severity docs finding, milestone acceptance
refuses to mark the milestone done until the finding clears. This is a
one-line addition to the acceptance check that already reads reviewer
verdicts.

### Step 8 — Regression test for the plan scorer

Create `tests/test_plan_docs_section.sh`:

1. Use each `templates/plans/*.md` as a fixture.
2. Feed an incomplete DESIGN.md (no Documentation Strategy section) to
   `lib/plan_completeness.sh` — assert it flags the missing section.
3. Feed a minimally-populated DESIGN.md (6 lines under Documentation
   Strategy) — assert it passes the scorer.

Wire into `tests/run_tests.sh`.

### Step 9 — Shellcheck + full test suite

```bash
shellcheck lib/config_defaults.sh lib/prompts.sh lib/milestone_acceptance.sh
bash tests/run_tests.sh
```

### Step 10 — Version bump

Edit `tekhton.sh` — `TEKHTON_VERSION="3.74.0"`.

## Files Touched

### Added
- `tests/test_plan_docs_section.sh`
- `.claude/milestones/m74-documentation-first-class.md` — this file

### Modified
- `lib/config_defaults.sh` — four new DOCS_* variables
- `lib/prompts.sh` — register new template variables
- `lib/milestone_acceptance.sh` — block on BLOCK-severity docs findings
  when `DOCS_STRICT_MODE=true`
- `templates/plans/cli-tool.md`
- `templates/plans/web-app.md`
- `templates/plans/api-service.md`
- `templates/plans/mobile-app.md`
- `templates/plans/web-game.md`
- `templates/plans/custom.md`
- `templates/plans/library.md` (add `<!-- REQUIRED -->` marker only)
- `prompts/plan_interview.prompt.md` — four new Phase 2 questions
- `prompts/plan_interview_followup.prompt.md` — matching followups
- `prompts/plan_generate.prompt.md` — section count 12 → 13, new section 13
- `prompts/coder.prompt.md` — public-surface-touch clause + Docs Updated section
- `prompts/reviewer.prompt.md` — docs freshness checklist item
- `tests/run_tests.sh` — register new test
- `tekhton.sh` — bump `TEKHTON_VERSION` to `3.74.0`
- `.claude/milestones/MANIFEST.cfg` — add M74 row

## Acceptance Criteria

- [ ] `lib/config_defaults.sh` defines `DOCS_ENFORCEMENT_ENABLED=true`,
      `DOCS_STRICT_MODE=false`, `DOCS_DIRS="docs/"`, `DOCS_README_FILE="README.md"`
- [ ] `lib/prompts.sh` registers all four as template variables
- [ ] All 7 `templates/plans/*.md` files contain a `## Documentation Strategy`
      section with a `<!-- REQUIRED -->` marker
- [ ] `templates/plans/library.md`'s existing section has the REQUIRED marker
      added (not duplicated)
- [ ] `prompts/plan_interview.prompt.md` walks the interviewer through the
      four docs questions from Design Decision #2
- [ ] `prompts/plan_generate.prompt.md` lists 13 required sections (not 12)
      and section 13 is "Documentation Responsibilities"
- [ ] `prompts/coder.prompt.md` contains the public-surface-touch clause and
      tells the coder to write a `## Docs Updated` subsection in
      `CODER_SUMMARY.md`
- [ ] `prompts/reviewer.prompt.md` contains the docs freshness checklist item
      and references `{{DOCS_STRICT_MODE}}`
- [ ] `lib/milestone_acceptance.sh` rejects milestone completion when
      `DOCS_STRICT_MODE=true` and a BLOCK-severity docs finding is unresolved
- [ ] `tests/test_plan_docs_section.sh` exists and is registered
- [ ] Test asserts `plan_completeness.sh` flags missing doc section as
      incomplete
- [ ] Test asserts populated doc section scores as complete
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `shellcheck` zero warnings on modified lib files
- [ ] `tekhton.sh` `TEKHTON_VERSION` is `3.74.0`
- [ ] `.claude/milestones/MANIFEST.cfg` contains the M74 row with
      `depends_on=m72`, group `quality`

## Watch For

- **Don't conflate M74 with M75.** M74 is the bake-in — prompt + config
  + template changes only. M75 adds a new Haiku stage. Keep the two
  milestones decoupled: the coder and reviewer changes here must be
  useful even without M75's docs agent enabled.
- **Backwards compatibility for existing projects.** Projects that already
  have a CLAUDE.md generated under the 12-section format will not have a
  "Documentation Responsibilities" section. The reviewer logic must
  gracefully fall back to "no documented public surfaces" when the section
  is missing — do NOT hard-error. A one-time `--replan` run will regenerate
  CLAUDE.md with the 13th section.
- **`lib/plan_completeness.sh` already respects `<!-- REQUIRED -->` markers
  — verify by code reading, not by trust.** The scoring function reads
  markers at template load time. If the scorer hardcodes a list of
  section names rather than reading markers, the new section won't score.
  Read `lib/plan_completeness.sh` and confirm the REQUIRED flow before
  adding markers.
- **The "public surface" definition is per-project.** A CLI tool's public
  surface is its flag set; a library's is its exported API; a web app's
  may be its routes and screens. The coder prompt must say "what
  CLAUDE.md defines as your public surface" rather than hardcode a
  definition. Keeping it project-configurable is the whole point of
  putting docs responsibilities in CLAUDE.md section 13.
- **`DOCS_STRICT_MODE=false` by default.** Do NOT flip strict mode on by
  default — that would immediately start blocking projects that aren't
  ready for it. The default is warn-only. Strict mode is an opt-in per
  project via `pipeline.conf`.
- **Reviewer can't see the coder's git diff directly.** It reads
  `CODER_SUMMARY.md`. So the "docs updated" handoff MUST be a dedicated
  subsection in `CODER_SUMMARY.md`, not just a mention in prose. That's
  why the coder prompt requires `## Docs Updated`. The reviewer looks for
  that exact header.
- **Avoid regex-matching "README" in coder output.** The docs freshness
  check is structural (look for the `## Docs Updated` section), not
  lexical. A coder that updated `docs/api.md` but wrote "I also fixed
  the README" in free-form prose should NOT fool the check.
- **M73 is the dependency for m74's branch — cleanest ordering.** M74
  depends on M72 in the manifest (same as M73 does) because M73 is a
  parallel-track bug fix. Both can land in either order.
- **Test fixture hygiene.** The new test for the plan scorer should use
  minimal in-memory fixtures, not write to `.claude/plans/`. Model it on
  existing `tests/test_plan_*.sh` files.
- **`library.md` already has the section — don't duplicate.** Add only
  the `<!-- REQUIRED -->` marker. The content is fine as-is.

## Seeds Forward

- **M75 builds on this.** M75 adds a dedicated Haiku docs agent that runs
  after the coder and before the reviewer. It consumes the
  `## Docs Updated` section we're creating here plus the coder's diff to
  auto-suggest README/docs patches. M74 is M75's prerequisite.
- **CHANGELOG integration in M77.** When M77 adds CHANGELOG generation,
  it can read `## Docs Updated` to include a "Docs" line in each changelog
  entry. Already aligned.
- **Docs freshness at health-score time.** `HEALTH_WEIGHT_DOCS=15` already
  exists as a post-hoc metric. A follow-up could tie it to the new
  CLAUDE.md section 13 — checking whether the declared public surface
  matches the actual code — but that's out of scope here.
- **Auto-generated API reference triggering.** Projects that use typedoc,
  sphinx, or rustdoc could have Tekhton automatically re-run the
  generator at finalize time when public-surface files changed. Flagged
  for a future devx milestone.
- **`docs/` link-checker integration.** A future quality milestone could
  run a link-checker on `docs/` at reviewer time and flag broken links.
  Cheap to add once the docs-awareness plumbing exists.
