# Milestone 51: V3 Documentation & README Finalization
<!-- milestone-meta
id: "51"
status: "pending"
-->

## Overview

Tekhton V3 introduced major features — Milestone DAG, intelligent indexing,
Serena MCP, Watchtower, brownfield intelligence, security agent, express mode,
TDD support, and more — across 50 milestones. The README still says "v2.0 —
Adaptive Pipeline" and the GitHub Pages documentation site covers V3 features
only partially. This milestone brings all documentation current so the repo is
ready to merge into main as a polished V3 release.

## Scope

### 1. README.md Overhaul

**Problem:** The README header says `v2.0 — Adaptive Pipeline` (line 8). The
"What's New" section covers only V2 features. V3 features (DAG milestones,
repo maps, Watchtower, security agent, express mode, brownfield init, planning
interview, TDD support, etc.) are undocumented in the README.

**Fix:**
- Update version badge to `v3.0 — Context-Aware Pipeline` (or similar)
- Replace "What's New in v2.0" with "What's New in v3.0" covering key features:
  - **Milestone DAG** — file-based milestones with dependency tracking, sliding
    context window, parallel groups
  - **Intelligent Indexing** — tree-sitter repo maps with PageRank ranking,
    task-relevant context slicing, cross-run file association tracking
  - **Watchtower Dashboard** — real-time browser-based pipeline monitoring with
    Live Run, Milestone Map, Reports, and Trends tabs
  - **Security Agent** — automated OWASP-aware security review stage with
    finding classification and severity scoring
  - **Task Intake / PM Agent** — complexity estimation, task decomposition,
    scope validation before execution
  - **Brownfield Intelligence** — deep codebase analysis for `--init` on
    existing projects (tech stack detection, health scoring, AI artifact
    detection)
  - **Express Mode** — zero-config execution for quick tasks (`tekhton -x "fix typo"`)
  - **TDD Support** — configurable pipeline order (`--tdd` flag, tester-first)
  - **Browser Planning** — interactive planning interview in the browser
  - **Build Gate Hardening** — hang prevention, timeout enforcement, process
    tree cleanup
  - **Causal Event Log** — structured event logging for debugging and
    cross-run learning
  - **Test Baseline** — pre-existing failure detection to avoid blaming agents
    for inherited test debt
- Keep V2 features mentioned briefly in a "Foundation (v2)" subsection
- Update the Requirements section if V3 added any (Python 3.8+ for indexer)
- Update Quick Start if the workflow changed
- Add a "Watchtower" section with a brief description and launch instructions
- Add an "Optional Dependencies" section covering tree-sitter, Serena

**Files:** `README.md`

### 2. GitHub Pages Documentation Site

**Problem:** The `docs/` directory has guides and references but many are stale
or missing V3 content. Key gaps:
- `docs/index.md` — mentions V2 features only
- `docs/guides/watchtower.md` — exists but may not cover M34-M38 improvements
- `docs/concepts/milestone-dag.md` — exists but may lack DAG details from M1
- No docs for: security agent, express mode, TDD mode, test baseline, causal
  log, browser planning
- `docs/reference/commands.md` — may be missing V3 flags
- `docs/reference/configuration.md` — may be missing V3 config keys
- `docs/changelog.md` — needs V3 entries

**Fix:**
- Update `docs/index.md` to reflect V3 capabilities and features
- Update `docs/guides/watchtower.md` with current Watchtower feature set
  (Live Run, Milestone Map, Reports, Trends, smart refresh, context-aware
  layout, action items severity colors)
- Update `docs/concepts/milestone-dag.md` with MANIFEST.cfg format, DAG
  queries, migration from inline milestones, sliding window mechanics
- Add `docs/guides/security-review.md` — security agent configuration,
  finding severity levels, suppression
- Add `docs/guides/express-mode.md` — zero-config usage, when to use express
  vs full pipeline
- Add `docs/guides/tdd-mode.md` — `--tdd` flag, pipeline order customization
- Add `docs/concepts/causal-log.md` — event types, retention, querying
- Add `docs/concepts/test-baseline.md` — pre-existing failure detection,
  stuck detection, configuration
- Update `docs/reference/commands.md` with all V3 flags (`--watchtower`,
  `--express`, `--tdd`, `--fix-nonblockers`, `--diagnose`, `--dry-run`, etc.)
- Update `docs/reference/configuration.md` with all V3 config keys (DAG,
  indexer, Serena, causal log, test baseline, action items thresholds)
- Update `docs/changelog.md` with a V3 release section summarizing all
  milestones by theme (Watchtower, DAG, Indexer, Quality, DevX, Brownfield)
- Update `docs/getting-started/` guides if the onboarding flow changed

**Files:** `docs/index.md`, `docs/guides/watchtower.md`,
`docs/concepts/milestone-dag.md`, `docs/reference/commands.md`,
`docs/reference/configuration.md`, `docs/changelog.md`,
`docs/getting-started/*.md`, new files for missing guides/concepts

### 3. CLAUDE.md Sync

**Problem:** The project's own `CLAUDE.md` contains the repository layout,
template variables table, and initiative descriptions. These need to reflect
the final V3 state.

**Fix:**
- Update the repository layout tree if any new files were added in M36-M40
- Update the template variables table with any new variables from M36-M40
- Update the version section to reflect V3 final state
- Mark all V3 milestones as complete in the initiative description
- Add a brief "V3 Complete" summary under the V3 initiative section

**Files:** `CLAUDE.md`

### 4. DESIGN_v3.md Retrospective

**Problem:** `DESIGN_v3.md` was the planning document for V3. Now that V3 is
complete, the design doc should be annotated with final status.

**Fix:**
- Add a "Status: Complete" header or badge at the top
- Add a brief retrospective section noting: milestones completed, features
  shipped, any deviations from the original plan
- Do NOT rewrite the design doc — it's a historical artifact. Only add a
  status annotation and retrospective appendix.

**Files:** `DESIGN_v3.md`

## Acceptance Criteria

- README.md version badge says V3 (not V2)
- README.md "What's New" section covers all major V3 features
- README.md Requirements section mentions optional Python dependency
- `docs/index.md` reflects V3 capabilities
- `docs/reference/commands.md` includes all V3 CLI flags
- `docs/reference/configuration.md` includes all V3 config keys
- `docs/guides/watchtower.md` covers the complete Watchtower feature set
- `docs/concepts/milestone-dag.md` covers MANIFEST.cfg, DAG operations,
  migration, sliding window
- New guide pages exist for: security review, express mode, TDD mode
- New concept pages exist for: causal log, test baseline
- `docs/changelog.md` has a V3 release section
- `CLAUDE.md` repository layout and template variables are current
- `DESIGN_v3.md` has a completion status annotation
- All documentation is internally consistent (no references to "upcoming"
  features that are already shipped)
- All existing tests pass (`bash tests/run_tests.sh`)
- No broken internal links in documentation (relative paths all resolve)

## Watch For

- **Documentation scope creep:** This milestone is about documenting what
  exists, not redesigning docs infrastructure. Don't add search, versioning,
  or theme changes. Keep it to content updates.
- **CLAUDE.md size:** CLAUDE.md is already large. Don't expand it significantly.
  The template variables table should only add genuinely new variables, not
  re-document existing ones.
- **Changelog granularity:** Don't list all 40 milestones individually. Group
  by theme (Watchtower, DAG, Indexer, Quality, DevX, Brownfield, Planning)
  with 2-3 bullet points per theme.
- **Stale screenshots:** `docs/assets/screenshots/.gitkeep` exists but has no
  actual screenshots. If adding Watchtower screenshots, ensure they're
  generated from a real run, not mocked up.
- **Links to DESIGN_v3.md:** The CLAUDE.md already references `DESIGN_v3.md`.
  Don't move or rename the design doc.

## Seeds Forward

- This is the final V3 milestone. After completion, the branch is ready for
  merge to main.
- The documentation structure established here carries into V4 planning.
- The changelog format provides a template for future release notes.
