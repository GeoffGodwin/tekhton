# Project Crawling & Tech Stack Detection

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.

Tekhton can index brownfield projects for context-aware operations:

- **Tech stack detection** — automatically identifies languages, frameworks, entry
  points, and infers build/test/lint commands from manifest files and tooling
- **Project crawler** — generates `.claude/index/` (structured data: `meta.json`,
  `inventory.jsonl`, `dependencies.json`, `configs.json`, `tests.json`, per-file
  `samples/`) and a bounded human-readable `PROJECT_INDEX.md` view, both configurable
  via `PROJECT_INDEX_BUDGET`

Used by `--init` to auto-populate `pipeline.conf` and by `--replan` to produce
higher-quality document updates.
