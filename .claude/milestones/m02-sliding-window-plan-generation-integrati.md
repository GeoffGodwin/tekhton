#### [DONE] Milestone 2: Sliding Window & Plan Generation Integration
<!-- milestone-meta
id: "2"
status: "done"
-->

Wire the DAG into the prompt engine with a character-budgeted sliding window that
injects only relevant milestones into agent context. Update plan generation to emit
milestone files instead of inline CLAUDE.md sections. Add auto-migration at startup
for existing projects with inline milestones.

Files to create:
- `lib/milestone_window.sh` — `build_milestone_window(model)` assembles
  character-budgeted milestone context block from the manifest. Priority:
  active milestone (full content) → frontier milestones (first paragraph +
  acceptance criteria) → on-deck milestones (title + one-line description).
  Fills greedily until budget exhaustion. `_compute_milestone_budget(model)`
  calculates available chars: `min(available * MILESTONE_WINDOW_PCT/100,
  MILESTONE_WINDOW_MAX_CHARS)`. `_milestone_priority_list()` returns ordered
  IDs by priority. Integrates with `_add_context_component()` for accounting.

Files to modify:
- `stages/coder.sh` — replace static MILESTONE_BLOCK with
  `build_milestone_window()` call when manifest exists. Falls back to existing
  behavior when no manifest.
- `stages/plan_generate.sh` — after agent produces CLAUDE.md content, post-process:
  extract milestone blocks into individual files in `.claude/milestones/`, generate
  MANIFEST.cfg, remove milestone blocks from CLAUDE.md and insert pointer comment.
  Agent prompt and output format are unchanged — shell handles extraction.
- `lib/orchestrate_helpers.sh` — `_run_auto_advance_chain()` uses DAG-aware
  milestone ordering via `dag_find_next()`.
- `lib/config.sh` — add MILESTONE_DIR path resolution (relative → absolute).
- `tekhton.sh` — add auto-migration trigger at startup: if `MILESTONE_DAG_ENABLED`
  and `MILESTONE_AUTO_MIGRATE` and no manifest exists but inline milestones
  detected, run `migrate_inline_milestones()`.

Acceptance criteria:
- `build_milestone_window()` returns only the active milestone + frontier
  milestones that fit within the character budget
- When budget is exhausted, frontier milestones are truncated (first paragraph +
  acceptance criteria only) rather than omitted entirely
- On-deck milestones only included if budget remains after all frontier milestones
- The window integrates with `_add_context_component()` for context accounting
- Plan generation extracts milestones from agent output into individual files and
  generates a valid MANIFEST.cfg
- Auto-migration at startup correctly converts inline CLAUDE.md milestones to
  files + manifest
- After migration, CLAUDE.md no longer contains full milestone blocks
- `_run_auto_advance_chain()` works correctly with DAG-based ordering
- Window respects `MILESTONE_WINDOW_MAX_CHARS` hard cap
- When `MILESTONE_DAG_ENABLED=false`, all behavior is identical to v2
- All existing tests pass
- `bash -n lib/milestone_window.sh` passes
- `shellcheck lib/milestone_window.sh` passes
- New test files: `tests/test_milestone_window.sh` (budget calculation, priority
  ordering, budget exhaustion), `tests/test_milestone_dag_migrate.sh` (inline
  extraction, manifest generation, CLAUDE.md cleanup, re-migration idempotency)

Watch For:
- Plan generation post-processing must handle variable heading depth (####, #####)
  since agents may vary formatting. Use the same regex as `parse_milestones()`.
- Auto-migration must be idempotent. If MANIFEST.cfg already exists, skip.
  If interrupted mid-way, next run should detect partial state and complete.
- CLAUDE.md trimming after milestone extraction must preserve all non-milestone
  content exactly. Use existing `_extract_milestone_block()` +
  `_replace_milestone_block()` pattern.
- Character budget must account for the instruction header (~300 chars) prepended
  by `build_milestone_window()`. Subtract before filling with file content.
- When the active milestone file exceeds the entire budget, truncate it (keep
  acceptance criteria at minimum) rather than failing. Log a warning.

Seeds Forward:
- The DAG data model supports future parallel execution: `dag_get_frontier()`
  returns all parallelizable milestones
- The sliding window pattern can be extended for repo map integration: pre-compute
  the repo map slice from the milestone's "Files to create/modify" section
- Auto-migration creates the `.claude/milestones/` directory structure that future
  tooling (milestone dashboards, progress tracking) can consume
