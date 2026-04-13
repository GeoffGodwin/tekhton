# M72 Quality Gap Analysis — Systematic Prevention of Milestone Blind Spots

**Date:** 2026-04-13
**Scope:** Post-mortem of M72 (Tidy Project Root), residual gap audit, process improvement proposals

---

## 1. Remaining M72 Gaps (Empirical Audit)

The following gaps were discovered by searching `lib/*.sh`, `stages/*.sh`, and
`prompts/*.prompt.md` for hardcoded filenames that resolve to the project root
but have no corresponding `_FILE` config variable and were not included in M72's
migration.

### 1A. Persistent files written to project root — no config variable

These files survive across runs and accumulate state. They should be under
`${TEKHTON_DIR}/` but were completely missed by M72.

| File | Code Sites | Type |
|------|-----------|------|
| **DRIFT_ARCHIVE.md** | `lib/drift_prune.sh:57` — `local archive_file="${PROJECT_DIR}/DRIFT_ARCHIVE.md"` | Persistent archive |
| **PROJECT_INDEX.md** | `lib/crawler.sh:67`, `lib/index_view.sh:23`, `lib/rescan.sh:32`, `stages/intake.sh:98,239`, `lib/replan_brownfield.sh:16` | Persistent index |
| **REPLAN_DELTA.md** | `lib/replan_brownfield.sh:199,344`, `lib/replan_midrun.sh:190,259` | Semi-persistent delta |
| **MERGE_CONTEXT.md** | `lib/init.sh:160-161`, `lib/artifact_handler_ops.sh:119`, `lib/init_synthesize_helpers.sh:93-94` | Init-time transient |

**Impact:** After M72, running `--init`, `--replan`, or a drift prune still
creates files at the project root, defeating the `.tekhton/` consolidation goal.

### 1B. Transient artifacts written to project root — no config variable

These files are created during a pipeline run, read within the same run, then
archived to `LOG_DIR`. They exist at the project root during execution and leave
stale copies if the pipeline is interrupted.

| File | Code Sites | Count |
|------|-----------|-------|
| **SCOUT_REPORT.md** | `stages/coder.sh:152,155,161-162,226,231,250-251,264,267,272-273,284-286`, `lib/dry_run.sh:120-121,162-163,374,397`, `lib/turns.sh:40,96`, `lib/context_compiler.sh:203-204` | ~23 sites |
| **ARCHITECT_PLAN.md** | `stages/architect.sh:94,100,110,119,221,285,348-349`, `tekhton.sh:132-134,2457` | ~11 sites |
| **CLEANUP_REPORT.md** | `stages/cleanup.sh:168,172,197` | 3 sites |
| **SPECIALIST_*_FINDINGS.md** | `lib/specialists.sh:111-112,165-166`, `lib/specialists_helpers.sh:18,33` — dynamic pattern `SPECIALIST_${upper_name}_FINDINGS.md` for UI/Security/Performance/API | 6 sites |

**Impact:** During any pipeline run, 3-5 transient files appear in the project
root. If a run is interrupted, these orphans remain. `tekhton.sh:2457` even
mixes parameterized paths (`${CODER_SUMMARY_FILE}`) with a literal
`ARCHITECT_PLAN.md` in the same loop, showing inconsistent migration.

### 1C. Prompt templates with literal filenames

These prompts instruct agents to write or read files by literal name instead of
using `{{VAR}}` template substitution. Agents will create files at whatever
path the literal name resolves to (the project root).

| Prompt File | Literal Filename | Usage |
|-------------|-----------------|-------|
| `prompts/scout.prompt.md:66` | `SCOUT_REPORT.md` | "Write a file called `SCOUT_REPORT.md`" |
| `prompts/tester_write_failing.prompt.md:33,84` | `SCOUT_REPORT.md` | "Read SCOUT_REPORT.md" |
| `prompts/architect.prompt.md:63` | `ARCHITECT_PLAN.md` | "Write `ARCHITECT_PLAN.md`" |
| `prompts/architect_jr_rework.prompt.md:4,10` | `ARCHITECT_PLAN.md` | "Read `ARCHITECT_PLAN.md`" |
| `prompts/architect_sr_rework.prompt.md:4,10` | `ARCHITECT_PLAN.md` | "Read `ARCHITECT_PLAN.md`" |
| `prompts/architect_review.prompt.md:8` | `ARCHITECT_PLAN.md` | Reference |
| `prompts/cleanup.prompt.md:28` | `CLEANUP_REPORT.md` | "Write `CLEANUP_REPORT.md`" |
| `prompts/specialist_ui.prompt.md:51` | `SPECIALIST_UI_FINDINGS.md` | "Write `SPECIALIST_UI_FINDINGS.md`" |
| `prompts/specialist_performance.prompt.md:47` | `SPECIALIST_PERFORMANCE_FINDINGS.md` | "Write" |
| `prompts/specialist_api.prompt.md:50` | `SPECIALIST_API_FINDINGS.md` | "Write" |
| `prompts/specialist_security.prompt.md:47` | `SPECIALIST_SECURITY_FINDINGS.md` | "Write" |
| `prompts/intake_scan.prompt.md:40` | `PROJECT_INDEX.md` | Reference heading |

### 1D. Migration file list omissions

`migrations/003_to_031.sh` does not include these files that may exist at the
project root:

- `DRIFT_ARCHIVE.md` — persistent, should be migrated
- `PROJECT_INDEX.md` — persistent, should be migrated
- `REPLAN_DELTA.md` — transient, may exist from interrupted replan
- `MERGE_CONTEXT.md` — transient, may exist from interrupted init
- `SCOUT_REPORT.md` — transient orphan from interrupted run
- `ARCHITECT_PLAN.md` — transient orphan from interrupted run
- `CLEANUP_REPORT.md` — transient orphan from interrupted run

### 1E. Test harness masks production paths

`tests/run_tests.sh:14-43` sets all `_FILE` variables to root-relative paths
with the comment "Tests predate the TEKHTON_DIR move (M72)". This means tests
never exercise the actual `.tekhton/` paths that production uses. A file-creation
bug (wrong path) would pass all tests.

### 1F. Total gap count

| Category | Files | Code sites |
|----------|-------|-----------|
| Persistent — no config var | 4 | ~15 |
| Transient — no config var | 7+ (dynamic) | ~43 |
| Prompt literal filenames | 12 entries | ~15 |
| Migration list omissions | 7 | 7 |
| **Total unique files missed** | **~11** | **~80** |

---

## 2. Root Cause Summary

### Why M72 shipped with gaps

The M72 failure was not a single mistake but a systematic process failure at
four levels:

**Level 1: Incomplete discovery.**
The M72 audit searched for `_FILE` variables and `$PROJECT_DIR/NAME.md` patterns.
This missed files that:
- Had no `_FILE` variable to find (DRIFT_ARCHIVE.md, PROJECT_INDEX.md)
- Used local variable assignments (`local archive_file=...`) instead of global
  config patterns
- Were created dynamically via string interpolation (`SPECIALIST_${name}_FINDINGS.md`)
- Were written by agent prompts (where the filename is a literal string the
  agent is told to write, not a bash variable)

The correct audit would have been: "grep for every `.md` or `.txt` literal that
could resolve to a file at the project root, regardless of whether it's already
parameterized." The M72 audit was: "find all existing `_FILE` variables and
their references." This is a classic case of searching for what you expect to
find rather than what you need to find.

**Level 2: Verification vs. validation.**
M72's acceptance criteria were all verification criteria: "did we do what the
spec says?" The criteria checked:
- "All ~14 new `_FILE` variables listed in 'File Inventory' exist" (verification)
- "Zero literal occurrences of the 25 migrated filenames remain" (verification)

None were validation criteria: "did we achieve the actual goal?" Missing:
- "No Tekhton-managed `.md` file is created at the project root during a
  pipeline run" (validation)
- "Every hardcoded filename in prompts/*.prompt.md uses `{{VAR}}` substitution"
  (validation)
- "Every `_FILE` path written by the pipeline resolves under `${TEKHTON_DIR}/`"
  (validation)

Verification confirms the spec was followed. Validation confirms the spec was
complete. M72 had 100% verification coverage and 0% validation coverage.

**Level 3: No self-referential check.**
The milestone never asked: "Does Tekhton's own pipeline.conf override the new
defaults?" This was the original Bug 2 (since fixed). More broadly, the
milestone did not test the full end-to-end path from config load → variable
expansion → file creation → actual filesystem location.

**Level 4: Missing negative-space analysis.**
The milestone design said "~30 files to relocate" but never asked "what files
did we NOT include, and is that intentional?" There was no "negative space"
section documenting files that were explicitly left at the root with a
justification. If the milestone had been required to document exclusions
(CLAUDE.md, README.md, CHANGELOG.md — intentionally at root) alongside
inclusions, the omission of DRIFT_ARCHIVE.md and PROJECT_INDEX.md would have
been immediately visible.

### Systemic pattern

The root cause is that the `draft_milestones.prompt.md` does not instruct the
analysis phase to:
1. Perform exhaustive codebase discovery using available tooling — the repo map
   (tree-sitter AST + PageRank) can scope which files are affected, Serena LSP
   can trace symbol references, and targeted grep can catch string-literal
   patterns invisible to both. M72 used none of these systematically.
2. Require behavioral acceptance criteria (observe actual runtime behavior,
   not just structural patterns)
3. Require negative-space documentation (what is explicitly out of scope, with
   justification)
4. Cross-reference prompts as code sites (prompt templates tell agents to
   create files — those are write sites too)

### Underutilized tooling

Tekhton already has two tools that could have prevented M72's gaps, but neither
was used during milestone generation:

- **Repo map** (tree-sitter): Could have scoped the blast radius at the file
  level, surfacing files like `lib/drift_prune.sh` and `lib/crawler.sh` as
  relevant to a "move files" change. Currently only injected as a passive
  context slice — not actively queried during impact analysis.

- **Serena LSP** (`find_referencing_symbols`): Could have traced all call sites
  of functions that write to `PROJECT_DIR`. Available to the draft milestones
  agent if enabled, but the prompt never mentions it.

Neither tool can catch literal string patterns in code (`"SCOUT_REPORT.md"`)
or in prompt templates — that requires grep. But the tiered combination
(repo map → Serena → targeted grep) catches more than any single tool alone
while avoiding context bloat from dumping raw grep output.

---

## 3. Milestone Proposals

New milestones numbered M84–M87, following the current highest (M83).

### M84: Complete TEKHTON_DIR Migration — Remaining Hardcoded Paths

**Goal:** Parameterize all remaining hardcoded filenames that write to the
project root, completing the M72 migration.

**Scope:**
- Add `_FILE` config variables for: `SCOUT_REPORT_FILE`, `ARCHITECT_PLAN_FILE`,
  `CLEANUP_REPORT_FILE`, `DRIFT_ARCHIVE_FILE`, `PROJECT_INDEX_FILE`,
  `REPLAN_DELTA_FILE`, `MERGE_CONTEXT_FILE`, `SPECIALIST_FINDINGS_DIR` (or
  pattern variable)
- Replace ~80 hardcoded references across `lib/`, `stages/`, and `prompts/`
- Update `migrations/003_to_031.sh` file list to include DRIFT_ARCHIVE.md,
  PROJECT_INDEX.md, and transient orphan cleanup
- Update prompt templates to use `{{VAR}}` substitution for all affected files
- Fix `tekhton.sh:2457` mixed parameterized/literal pattern

**Key Acceptance Criteria:**
- [ ] `grep -rn '"[A-Z][A-Z_]*\.\(md\|txt\)"' lib/ stages/` returns zero hits
      for files that should be under `${TEKHTON_DIR}/` (excluding CLAUDE.md,
      README.md, CHANGELOG.md, ARCHITECTURE.md, and other intentionally root-level files)
- [ ] `grep -rn 'PROJECT_DIR.*[A-Z][A-Z_]*\.\(md\|txt\)' lib/ stages/` returns
      zero hits for Tekhton-managed files
- [ ] A full pipeline run on a test project creates zero `.md` files at the
      project root that aren't in the explicit "stays at root" list
- [ ] All prompt templates that instruct agents to write files use `{{VAR}}`
      substitution, not literal filenames

### M85: Milestone Acceptance Criteria Linter

**Goal:** Add an automated validation pass that checks milestone acceptance
criteria for completeness patterns before a milestone is accepted as "done."

**Scope:**
- New library `lib/milestone_acceptance_lint.sh`
- Validates criteria contain at least one behavioral criterion (runtime check,
  not just grep)
- Validates refactor/migration milestones include a "completeness grep" criterion
  that searches for remaining literal references
- Validates milestones that affect Tekhton configuration include a
  self-referential check
- Warns on criteria that are pure verification without validation
- Integrates into `check_milestone_acceptance()` as a pre-check

**Key Acceptance Criteria:**
- [ ] Linter flags milestones with zero behavioral acceptance criteria
- [ ] Linter flags refactor milestones missing a "no remaining literal
      references" criterion
- [ ] Linter flags config-affecting milestones missing a self-referential
      check criterion
- [ ] M72's original acceptance criteria (before fixes) would have triggered
      at least 2 warnings from the linter
- [ ] Zero false positives on the existing M73-M83 milestone files

### M86: Draft Milestones Impact Surface Analysis

**Goal:** Enhance the `draft_milestones.prompt.md` Analyze phase with tiered
codebase discovery (repo map → Serena LSP → targeted grep) and negative-space
documentation, preventing the blind spots that caused M72's gaps.

**Scope:**
- Add mandatory "Impact Surface Scan" sub-phase to Phase 2 (Analyze) with
  tiered tooling: repo map for file scoping, Serena for symbol tracing,
  targeted grep for string-literal patterns invisible to AST/LSP
- Add mandatory "Negative Space" section to milestone template requiring
  explicit documentation of what is intentionally NOT changed
- Add mandatory "Prompt Template Audit" step that treats prompt files as
  code sites
- Add requirement for at least one behavioral acceptance criterion
- Add "Self-Referential Check" requirement for milestones affecting
  configuration or file paths

**Key Acceptance Criteria:**
- [ ] Phase 2 prompt text includes explicit grep commands for discovering
      affected code sites
- [ ] Milestone template includes `## Negative Space` section with
      "intentionally excluded" documentation requirement
- [ ] Milestone template requires `prompts/*.prompt.md` audit for
      literal filenames
- [ ] Generated acceptance criteria template includes both structural
      (grep/pattern) and behavioral (runtime observation) criteria
- [ ] Re-running the enhanced draft_milestones flow for an M72-equivalent
      task would produce a milestone that catches DRIFT_ARCHIVE.md and
      PROJECT_INDEX.md

### M87: Test Harness TEKHTON_DIR Parity

**Goal:** Update the test harness so tests exercise the actual `.tekhton/`
paths used in production, eliminating the test/production path divergence
introduced by M72's workaround.

**Scope:**
- Refactor `tests/run_tests.sh` to use `${TEKHTON_DIR}` prefix for all
  `_FILE` variable defaults instead of root-relative paths
- Update individual test files that hardcode root-relative `_FILE` values
  (found in ~8 test files)
- Add a specific test that verifies no Tekhton-managed files are created
  at the project root during a mock pipeline run
- Ensure `mkdir -p ${TEKHTON_DIR}` is part of test setup

**Key Acceptance Criteria:**
- [ ] `tests/run_tests.sh` no longer sets `_FILE` variables to root-relative
      paths
- [ ] All `_FILE` defaults in the test harness use `${TEKHTON_DIR}/` prefix
- [ ] At least one test verifies no unexpected files are created at the
      project root
- [ ] `bash tests/run_tests.sh` passes with zero failures after the change
- [ ] The "Tests predate the TEKHTON_DIR move" comment is removed

---

## 4. Prompt Edits: draft_milestones.prompt.md

See the companion commit for the actual edits to
`prompts/draft_milestones.prompt.md`. The changes add:

1. **Impact Surface Scan** — Phase 2 now requires tiered discovery: repo map
   for file-level scoping, Serena LSP for symbol-level tracing, and targeted
   grep for string-literal patterns invisible to AST/LSP. This avoids context
   bloat (no raw grep dumps) while catching the exact class of bug that caused
   M72's gaps.

2. **Negative Space section** — The milestone template now requires a
   `## Negative Space` section documenting what is intentionally not changed.

3. **Behavioral acceptance criteria** — The criteria template now requires
   at least one runtime/behavioral criterion alongside structural greps.

4. **Self-referential check** — For milestones that change config variables
   or file paths, the template requires a check of Tekhton's own
   `pipeline.conf` and any existing project configs.

5. **Prompt template audit** — Phase 2 requires checking `prompts/*.prompt.md`
   for literal filenames that should use `{{VAR}}` substitution.
