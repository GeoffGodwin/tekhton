#### Milestone 52: Fix Circular Onboarding Flow
<!-- milestone-meta
id: "52"
status: "done"
-->

The `--init` and `--plan` commands each tell users to run the other as a next step,
creating a confusing circular loop. Fix the next-steps messaging in all three
entry points to be context-aware: detect what has already been done and only
recommend what remains.

**The problem:**
- `--init` finishes and says "2. Start planning: tekhton --plan ..."
- `--plan` finishes and says "2. Run: tekhton --init (scaffold pipeline config)"
- A user who runs either command first gets told to run the other, which then
  tells them to run the first one again.

**The intended flows:**
- **Brownfield** (existing project): `--init` → `--plan-from-index` → run tasks
  (or `--init --full` which combines both)
- **Greenfield** (new project): `--plan` → `--init` → run tasks

**The fix:** Make next-steps messaging context-aware by checking what artifacts
already exist before recommending the next action.

Files to modify:
- `lib/plan.sh` — `_print_next_steps()` (line ~542):
  Check if `.claude/pipeline.conf` already exists. If it does, skip the
  "Run: tekhton --init" step. The next steps become:
  ```
  Next steps:
    1. Review the generated files and make any manual edits
    2. Run: tekhton "Implement Milestone 1: <title>"
  ```
  If `pipeline.conf` does NOT exist, keep the current messaging but clarify:
  ```
  Next steps:
    1. Review the generated files and make any manual edits
    2. Run: tekhton --init    (generate pipeline config & agent roles)
    3. Run: tekhton "Implement Milestone 1: <title>"
  ```

- `lib/init_report.sh` — `emit_init_summary()` (line ~116):
  Check if `CLAUDE.md` already has milestones (not just a stub). If milestones
  exist, skip the "Start planning" step and go straight to "run your first task".
  The next steps become:
  ```
  Next steps:
    1. Review essential config: .claude/pipeline.conf (lines 1-20)
    2. Run: tekhton "Implement Milestone 1: <title>"
  ```
  If CLAUDE.md is absent or is a stub (contains the TODO placeholder), keep the
  current planning recommendation.
  Detection: check for `<!-- TODO:.*--plan -->` comment OR absence of any
  `#### Milestone` header in CLAUDE.md, OR presence of MANIFEST.cfg with at
  least one entry.

- `lib/init_synthesize_ui.sh` — `_print_synthesis_next_steps()` (line ~107):
  This one is already correct (no circular reference). No changes needed, but
  verify it still reads well after the other changes.

Scope: ~30 lines of logic changes across 2 files. No new files, no new
functions, no new config keys.

Acceptance criteria:
- After `--plan` in a project that already has `.claude/pipeline.conf`, the
  next-steps output does NOT mention `--init`
- After `--plan` in a project that does NOT have `.claude/pipeline.conf`, the
  next-steps output mentions `--init` with a clear description
- After `--init` in a project that already has milestones (MANIFEST.cfg or
  non-stub CLAUDE.md), the next-steps output does NOT mention `--plan`
- After `--init` in a project with no milestones, the next-steps output
  recommends `--plan` or `--plan-from-index` as appropriate
- After `--init --full` (which runs both), the synthesis next-steps do NOT
  mention `--init` (already the case)
- All existing tests pass (`bash tests/run_tests.sh`)
- `shellcheck lib/plan.sh lib/init_report.sh` passes
- No new files created

Tests:
- Manual: run `--plan` in a project with pipeline.conf → verify no --init mention
- Manual: run `--init` in a project with milestones → verify no --plan mention
- Existing test suite passes

Watch For:
- The milestone detection in `init_report.sh` must handle three cases: no CLAUDE.md,
  stub CLAUDE.md (from init), and full CLAUDE.md (from plan). Use the presence of
  MANIFEST.cfg as the strongest signal since DAG is the default.
- `_print_next_steps()` in plan.sh uses `PROJECT_DIR` which is a global — confirm
  it is set when the function is called.
- Don't break the `--plan-from-index` path in init_report.sh — brownfield projects
  with >50 files should still see that recommendation when no milestones exist.
