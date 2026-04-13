# Milestone 79: README Restructure + docs/ Split
<!-- milestone-meta
id: "79"
status: "done"
-->

## Overview

Developer feedback: "The README is 823 lines and it's still not clear
how to actually use Tekhton effectively. I open it, scroll, and can't
find the answer to 'what's the happy path?'" Today's README is a
reference manual masquerading as an entry point — it covers every
feature in roughly the order they were built, not the order a new user
needs them.

M79 **slims the README to ≤ 300 lines** focused on the happy path, and
moves the reference material into `docs/` where it belongs. After the
split:

- **README.md** — one-page pitch: what Tekhton is, install, 5-minute
  quickstart, "How to use it effectively" narrative, link out to the
  rest.
- **docs/** — reference manual, one topic per file.

This is a **pure reorganization** milestone — no new behavior, no code
changes. The content already exists; M79 just cuts and pastes it into
better homes.

## Design Decisions

### 1. README target: ≤ 300 lines, with one-page flow

The new README has exactly these sections, in order:

1. **Headline** — one-sentence pitch + the "one intent, many hands" tagline.
2. **What is Tekhton?** — three paragraphs max.
3. **Install** — curl|bash + brew, same as M78 introduced.
4. **5-minute quickstart** — `cd my-project && tekhton --init && tekhton "fix the X bug"`.
5. **How to use Tekhton effectively** — prose narrative, NOT a feature list.
   Covers: plan first, let the pipeline iterate, check notes, rework,
   ship. One short paragraph per phase.
6. **What's in `docs/`** — an index linking out to the reference pages.
7. **Requirements** — short list (bash 4.3, jq, python3).
8. **Contributing** — link to CONTRIBUTING.md if it exists, else one
   paragraph.
9. **License** — MIT line.

No "Autonomous Modes", no "Specialist Reviews", no "Context Management"
section in the top-level README. Those are reference material and live
in `docs/`.

### 2. docs/ layout

New files created under `docs/`:

| File | Content pulled from README section |
|------|------------------------------------|
| `docs/USAGE.md` | How the Pipeline Works + Autonomous Modes + Human Notes |
| `docs/MILESTONES.md` | (placeholder for M80 to populate; stub here) |
| `docs/cli-reference.md` | CLI Reference |
| `docs/configuration.md` | Configuration |
| `docs/specialists.md` | Specialist Reviews |
| `docs/watchtower.md` | Watchtower Dashboard |
| `docs/metrics.md` | Metrics Dashboard |
| `docs/context.md` | Context Management + Clarification Protocol |
| `docs/crawling.md` | Project Crawling & Tech Stack Detection |
| `docs/drift.md` | Architecture Drift Prevention |
| `docs/resilience.md` | Agent Resilience |
| `docs/debt-sweeps.md` | Autonomous Debt Sweeps |
| `docs/planning.md` | Planning Phase |
| `docs/security.md` | Security |

`docs/` already has content from M18 (documentation site) — verify
before creating. If a file already exists, append rather than overwrite.
A collision check script lives in step 5 of the implementation plan.

### 3. Keep the "How to use effectively" narrative in the README

This is the part the user asked for. Ideal content:

> **1. Start with a plan.** `tekhton --plan` runs an interview that
> produces a `CLAUDE.md` plan and a set of milestone files. Edit them
> if you want — Tekhton will work from your edits.
>
> **2. Run a milestone.** `tekhton` (no args) picks the first pending
> milestone and runs the full pipeline: scout → coder → security →
> review → test. Most runs finish in a single invocation. If a rework
> cycle needs human input, Tekhton pauses with a clear prompt.
>
> **3. Check the notes.** `HUMAN_NOTES.md` is where the pipeline
> collects things it thinks need your eyes. Tick items off when done;
> the next run will pick up the unchecked ones.
>
> **4. Watch it drift.** Over many runs, architecture drifts.
> `DRIFT_LOG.md` and `ARCHITECTURE_LOG.md` record what changed and why.
> Run `tekhton --replan` when the plan stops matching reality.
>
> **5. Ship.** `CHANGELOG.md` and project version files auto-update
> (M76/M77). Tag when ready.

Approximately 120 words, fits the 300-line budget.

### 4. Don't move the CHANGELOG

`README.md`'s current `## Changelog` section is 127 lines (lines
691–820). It's big because it replicates historical version notes.
Move it into `CHANGELOG.md` (if it doesn't already exist from M77) as
a **single operation**:

- If `CHANGELOG.md` already exists (post-M77 project), leave its M77-
  generated content alone and **prepend** the historical entries under
  `## Historical (pre-M77)`.
- If `CHANGELOG.md` does not exist, create it from the README's
  Changelog section directly.

Replace the README's Changelog section with:

```markdown
## Changelog

See [CHANGELOG.md](./CHANGELOG.md).
```

Two lines instead of 127. Big win.

### 5. Leave history pointers in docs/

Each moved doc file gets a header:

```markdown
# Usage

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.
```

Preserves git-blame context for anyone following a link. Not strictly
necessary but cheap.

### 6. Mechanical safeguards

Do NOT edit README content during the move — copy verbatim, then edit
the **destination** for flow if needed. This keeps the diff reviewable:
one big set of file moves, one small set of destination tweaks.

Use `git mv` where possible (whole-file moves); use copy+delete for
partial-section moves. A `.github/scripts/readme-split-verify.sh`
one-off script greps the original README for each moved section and
asserts the destination file contains the same paragraph.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| README sections removed | ~15 | Moved to `docs/` |
| README final length | ≤ 300 lines | Down from 823 |
| New docs files | ~13 | See decision #2 table |
| Moved content blocks | ~15 | Copy verbatim then refine |
| New config vars | 0 | Pure reorganization |
| Code changes to tekhton.sh | 0 | — |
| Tests | 1 | One-off verification script |

## Implementation Plan

### Step 1 — Audit existing docs/ for collisions

```bash
ls docs/ 2>/dev/null
```

From M18 there may already be `docs/index.md`, `docs/cli.md`, etc.
Any existing file mentioned in decision #2's table must be:

- Read first.
- Either merged with the README content (append) or renamed to avoid
  clobbering.

Produce a short collision report as step 1's output before any file
writes. This is a required gate — do not move content without this
check.

### Step 2 — Create the new README skeleton in a staging file

Write the new README to `README.new.md` first. Copy the happy-path
narrative from decision #3, the install lines from M78, and the headline
text. Leave the link index for `docs/` as placeholders.

Validate `wc -l README.new.md ≤ 300`. If over, trim the narrative.

### Step 3 — Extract content sections one-by-one

For each row in decision #2's table:

1. Read the corresponding section from the current `README.md` (exact
   line ranges from `grep -n '^## '`).
2. Write to the matching `docs/<file>.md` with the history-pointer
   header from decision #5.
3. Delete the section from the current `README.md`.

Do this as ~15 separate Edit operations — each one is a contained,
reviewable change. Do NOT batch them into a single `Write README.md` —
we want git-blame to follow the moves cleanly.

### Step 4 — Swap README files

```bash
mv README.md README.old.md  # temporary — revert before commit
mv README.new.md README.md
```

Then verify:
- `wc -l README.md ≤ 300`
- No dangling section headers without content
- All `docs/*.md` files have non-empty content
- Link targets in the README's "What's in docs/" section resolve

Delete `README.old.md` before committing.

### Step 5 — Verification script

Create `tests/test_readme_split.sh` (one-off, not part of run_tests.sh
but runnable by CI or manually):

- Assert `wc -l README.md ≤ 300`.
- Assert each link in README's docs/ index points to an existing file.
- Assert `docs/<each-file>.md` is non-empty.
- Assert CHANGELOG.md exists (either pre-existing from M77 or created
  here).

Add to `tests/run_tests.sh` only if it's fast (< 1s) and doesn't depend
on network.

### Step 6 — Move the Changelog block

Per decision #4: either prepend historical entries to `CHANGELOG.md` or
create it fresh. Leave the README's `## Changelog` section as a two-line
link.

### Step 7 — Shellcheck + tests + version bump

```bash
shellcheck tests/test_readme_split.sh
bash tests/run_tests.sh
bash tests/test_readme_split.sh
```

Edit `tekhton.sh` — `TEKHTON_VERSION="3.79.0"`.
Edit manifest — M79 row with `depends_on=m78`, group `devx`.

## Files Touched

### Added
- `docs/USAGE.md`
- `docs/MILESTONES.md` (stub; M80 populates)
- `docs/cli-reference.md`
- `docs/configuration.md`
- `docs/specialists.md`
- `docs/watchtower.md`
- `docs/metrics.md`
- `docs/context.md`
- `docs/crawling.md`
- `docs/drift.md`
- `docs/resilience.md`
- `docs/debt-sweeps.md`
- `docs/planning.md`
- `docs/security.md`
- `tests/test_readme_split.sh`
- `.claude/milestones/m79-readme-restructure-docs-split.md` — this file

### Modified
- `README.md` — cut to ≤ 300 lines
- `CHANGELOG.md` — historical entries prepended (or created)
- `tekhton.sh` — `TEKHTON_VERSION` to `3.79.0`
- `.claude/milestones/MANIFEST.cfg` — M79 row

### Not modified (but verified)
- Any pre-existing files in `docs/` from M18 — collision-checked but
  left in place if they don't conflict

## Acceptance Criteria

- [ ] `README.md` is ≤ 300 lines
- [ ] README contains exactly these top-level sections, in order:
      Headline, What is Tekhton?, Install, 5-minute quickstart, How to
      use effectively, What's in docs/, Requirements, Contributing,
      License
- [ ] README Install section retains the curl|bash + brew one-liners
      from M78
- [ ] README "How to use effectively" narrative exists and covers
      plan → run → notes → drift → ship in that order
- [ ] `docs/USAGE.md` contains the previous "How the Pipeline Works"
      content
- [ ] `docs/cli-reference.md` contains the previous CLI Reference
      section
- [ ] `docs/configuration.md` contains the previous Configuration
      section
- [ ] All 13 `docs/<topic>.md` files listed in decision #2 exist and
      are non-empty
- [ ] Each moved doc file has a history pointer header linking back to
      this milestone
- [ ] `CHANGELOG.md` exists and contains the historical entries that
      were previously in README
- [ ] `README.md` Changelog section is a two-line pointer to
      `CHANGELOG.md`
- [ ] `tests/test_readme_split.sh` exists and asserts README ≤ 300
      lines and all doc links resolve
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `shellcheck` on changed shell files reports zero warnings
- [ ] `tekhton.sh` `TEKHTON_VERSION` is `3.79.0`
- [ ] `.claude/milestones/MANIFEST.cfg` contains the M79 row
      (`depends_on=m78`, group `devx`)

## Watch For

- **Collision check first, move second.** M18 already created
  `docs/index.md` and some site files. DO NOT blindly overwrite them.
  Step 1 of the plan is a required gate. If `docs/cli.md` exists with
  different content, either append or rename before writing.
- **Content moves are copy+delete, not rewrite.** Do not "improve" the
  documentation during the move. A clean reorganization diff is
  reviewable; an "improved" one is not. Rewrites are a separate
  follow-up milestone if needed.
- **Link updates.** After the move, scan the repo for any internal
  links that pointed at `README.md#foo-section` anchors. Update them to
  point at the new `docs/<file>.md` locations. `grep -rn
  'README.md#' .` finds them.
- **Don't drop the "What's New in v3" block entirely.** It's valuable
  release history. Move to `docs/changelog.md` or merge into the
  historical section of `CHANGELOG.md` — don't just delete it.
- **Preserve anchor backwards compat where cheap.** If external links
  point at `README.md#watchtower-dashboard`, add a line to the README's
  new "What's in docs/" section: `<a id="watchtower-dashboard"></a>
  See [docs/watchtower.md](./docs/watchtower.md)` — five characters per
  anchor, maintains incoming links from blog posts or issues.
- **File-length guardrail.** Each new `docs/<file>.md` has no max line
  limit (they're reference material) but the README has a HARD 300-line
  cap. If the narrative bloats, cut adjectives before cutting structure.
- **Markdown linter.** If `markdownlint` or similar runs in CI, the
  split may trip heading-level warnings (e.g., a moved `##` becomes the
  top heading in the new file and should be `#`). Bump heading levels
  up by one during the move.
- **CHANGELOG merge order.** If M77 lands before M79 (the dependency
  graph says m77 does NOT block m79, but ordering is likely), M77 may
  have already started a `CHANGELOG.md`. M79's historical entries go
  UNDER the "Unreleased" header from M77, NOT above it.
- **M80 stub.** `docs/MILESTONES.md` is a placeholder — write a one-line
  stub saying "M80 populates this." Don't attempt to write the content
  here; it would rot.

## Seeds Forward

- **Docusaurus or mkdocs site from docs/.** M18 already shipped a doc
  site, but the new flat docs/ tree could drive a prettier rendering.
  Out of scope.
- **Auto-generated CLI reference.** `tekhton --help` output parsed into
  `docs/cli-reference.md` on every release would eliminate doc drift.
  Small follow-up — requires a parser pass in CI.
- **Translations.** Once the README is short, translating it to
  Japanese/Spanish/French becomes feasible. `README.ja.md`,
  `README.es.md`, etc. Out of scope.
- **Interactive tutorial.** A `tekhton --tutorial` subcommand could
  walk a user through the 5-minute quickstart with real output. Future
  devx milestone.
- **Quickstart-validation in CI.** Run the exact commands from the
  README quickstart against a fixture project in CI. Catches docs drift
  automatically. Low effort, high value; flag for a follow-up.
