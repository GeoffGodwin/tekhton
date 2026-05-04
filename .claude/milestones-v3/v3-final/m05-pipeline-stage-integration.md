#### [DONE] Milestone 5: Pipeline Stage Integration
<!-- milestone-meta
id: "5"
status: "done"
-->

Wire the repo map into all pipeline stages, replacing or supplementing full
ARCHITECTURE.md injection. Each stage receives a different slice of the map
optimized for its role. Integrate with v2's context accounting for
budget-aware injection. Graceful degradation to 2.0 when map unavailable.

Files to modify:
- `stages/coder.sh` — when `REPO_MAP_ENABLED=true` and `INDEXER_AVAILABLE=true`:
  (1) regenerate repo map with task-biased ranking before coder invocation,
  (2) inject `REPO_MAP_CONTENT` into the coder prompt instead of full
  `ARCHITECTURE_CONTENT` (architecture file is still available via scout report),
  (3) if scout identified specific files, call `get_repo_map_slice()` to produce
  a focused slice showing those files plus their direct dependencies. When
  indexer unavailable, fall back to existing ARCHITECTURE_CONTENT injection.
- `stages/review.sh` — when enabled: extract file list from CODER_SUMMARY.md,
  call `get_repo_map_slice()` for those files + their callers (reverse
  dependencies), inject as `REPO_MAP_CONTENT`. Reviewer sees the changed files
  in full context of what calls them and what they call.
- `stages/tester.sh` — when enabled: extract file list from CODER_SUMMARY.md,
  call `get_repo_map_slice()` for those files + their test file counterparts
  (heuristic: `foo.py` → `test_foo.py`, `foo.ts` → `foo.test.ts`). Inject as
  `REPO_MAP_CONTENT`.
- `stages/architect.sh` — when enabled: inject full repo map (not sliced).
  Architect needs the broadest view for drift detection.
- `lib/prompts.sh` — add `REPO_MAP_CONTENT` and `REPO_MAP_SLICE` as template
  variables. Add `{{IF:REPO_MAP_CONTENT}}` conditional blocks.
- `lib/context.sh` — add repo map as a named context component in
  `log_context_report()`. Include it in budget calculations.
- `prompts/coder.prompt.md` — add `{{IF:REPO_MAP_CONTENT}}` block with
  instructions: "The following repo map shows ranked file signatures relevant
  to your task. Use it to understand the codebase structure and identify files
  to read or modify. Signatures show the public API — read full files before
  making changes."
- `prompts/reviewer.prompt.md` — add repo map block with instruction: "The
  repo map below shows the changed files and their callers/callees. Use it
  to verify that changes are consistent with the broader codebase structure."
- `prompts/tester.prompt.md` — add repo map block with instruction: "The
  repo map below shows the changed files and their test counterparts. Use it
  to identify which test files need updates and what interfaces to test against."
- `prompts/scout.prompt.md` — add full repo map block with instruction: "Use
  this repo map to identify relevant files without needing to search the
  filesystem. The map is ranked by likely relevance to the task."
- `prompts/architect.prompt.md` — add full repo map block for drift analysis

Acceptance criteria:
- Coder stage injects repo map instead of full ARCHITECTURE.md when available
- Reviewer sees changed files + reverse dependencies in map slice
- Tester sees changed files + test counterparts in map slice
- Scout sees full ranked map (dramatically reducing exploratory reads)
- Context report shows repo map as a named component with token count
- When `REPO_MAP_ENABLED=false` or indexer unavailable, all stages behave
  identically to v2 (no warnings, no changes)
- Prompt templates use conditional blocks — no repo map content appears in
  prompts when feature is disabled
- Token budget is respected: repo map + other context stays within
  `CONTEXT_BUDGET_PCT`
- All existing tests pass
- `shellcheck` passes on all modified `.sh` files

Watch For:
- The scout stage benefits MOST from the repo map — it replaces blind `find`
  and `grep` with a ranked file list. This is where the biggest token savings
  come from.
- ARCHITECTURE.md still has value for high-level design intent that tree-sitter
  can't capture. Consider injecting a truncated architecture summary (first
  N lines) alongside the repo map, not replacing it entirely.
- The test file heuristic (`foo.py` → `test_foo.py`) is language-specific.
  Keep it simple and configurable. A missed test file just means the tester
  falls back to normal discovery.
- Reverse dependency lookup (callers of changed files) can be expensive for
  highly-connected files. Cap at top 20 callers by PageRank.

Seeds Forward:
- Milestone 6 (Serena) enhances the repo map with live symbol data, giving
  agents even more precise context
- Milestone 7 (Cross-Run Cache) uses task→file history from this milestone
  to improve future repo map rankings
- The prompt template patterns established here (`{{IF:REPO_MAP_CONTENT}}`)
  are reused by Milestone 6 for LSP tool instructions
