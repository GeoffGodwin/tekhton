#### [DONE] Milestone 1: Milestone DAG Infrastructure
Add the DAG-based milestone storage system: a pipe-delimited manifest tracking
dependencies and status, individual `.md` files per milestone, DAG query functions
(frontier detection, cycle validation), and auto-migration from inline CLAUDE.md
milestones. This milestone replaces the sequential-only milestone model with a
dependency-aware DAG that enables future parallel execution.

Files to create:
- `lib/milestone_dag.sh` — manifest parser (`load_manifest()`, `save_manifest()`
  using atomic tmpfile+mv), DAG query functions (`dag_get_frontier()`,
  `dag_deps_satisfied()`, `dag_find_next()`, `dag_get_active()`), validation
  (`validate_manifest()` with cycle detection via DFS), ID↔number conversion
  (`dag_id_to_number()`, `dag_number_to_id()`). Data structures: parallel bash
  arrays (`_DAG_IDS[]`, `_DAG_TITLES[]`, `_DAG_STATUSES[]`, `_DAG_DEPS[]`,
  `_DAG_FILES[]`, `_DAG_GROUPS[]`) with associative index `_DAG_IDX[id]=index`.
- `lib/milestone_dag_migrate.sh` — `migrate_inline_milestones(claude_md, milestone_dir)`
  extracts all inline milestones from CLAUDE.md into individual files in
  `.claude/milestones/`, generates `MANIFEST.cfg`. Uses existing
  `_extract_milestone_block()` for block extraction. File naming:
  `m{NN}-{slugified-title}.md`. Dependencies inferred from sequential order
  (each depends on previous) unless explicit "depends on Milestone N" references
  found in text.

Files to modify:
- `lib/milestones.sh` — add `parse_milestones_auto()` dual-path wrapper: if
  manifest exists, returns milestone data from it in the same
  `NUMBER|TITLE|ACCEPTANCE_CRITERIA` format as `parse_milestones()`. All
  downstream consumers work unchanged.
- `lib/milestone_ops.sh` — `find_next_milestone()` gains DAG-aware path calling
  `dag_find_next()`. `mark_milestone_done()` gains DAG path calling
  `dag_set_status(id, "done")` + `save_manifest()`.
- `lib/milestone_archival.sh` — adapt for file-based milestones: read milestone
  file directly via `dag_get_file()`, append to archive, no CLAUDE.md block
  extraction needed.
- `lib/milestone_split.sh` — adapt for file-based milestones: write sub-milestone
  files + insert manifest rows instead of replacing CLAUDE.md blocks.
- `lib/milestone_metadata.sh` — write metadata into milestone files instead of
  CLAUDE.md headings.
- `lib/config_defaults.sh` — add defaults: `MILESTONE_DAG_ENABLED=true`,
  `MILESTONE_DIR=".claude/milestones"`, `MILESTONE_MANIFEST="MANIFEST.cfg"`,
  `MILESTONE_AUTO_MIGRATE=true`, `MILESTONE_WINDOW_PCT=30`,
  `MILESTONE_WINDOW_MAX_CHARS=20000`. Add clamps for PCT (80) and MAX_CHARS (100000).
- `tekhton.sh` — source new modules, add DAG-aware milestone initialization,
  add auto-migration at startup (if manifest missing but inline milestones found).
- `templates/pipeline.conf.example` — add milestone DAG config section with
  explanatory comments.

Manifest format (`.claude/milestones/MANIFEST.cfg`):
```
