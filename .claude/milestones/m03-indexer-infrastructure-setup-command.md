#### [DONE] Milestone 3: Indexer Infrastructure & Setup Command
<!-- milestone-meta
id: "3"
status: "done"
-->
Add the shell-side orchestration layer, Python dependency detection, setup command,
and configuration keys. This milestone builds the framework that Milestones 4-8
plug into. No actual indexing logic yet — just the plumbing.

Files to create:
- `lib/indexer.sh` — `check_indexer_available()` (returns 0 if Python + tree-sitter
  found), `run_repo_map(task, token_budget)` (invokes Python tool, captures output),
  `get_repo_map_slice(file_list)` (extracts entries for specific files from cached
  map), `invalidate_repo_map_cache()`. All functions are no-ops returning fallback
  values when Python is unavailable.
- `tools/setup_indexer.sh` — standalone setup script: checks Python version (≥3.8),
  creates virtualenv in `.claude/indexer-venv/`, installs `tree-sitter`,
  `tree-sitter-languages` (or individual grammars), `networkx`. Idempotent — safe
  to re-run. Prints clear error messages if Python is missing.

Files to modify:
- `tekhton.sh` — add `--setup-indexer` early-exit path that runs
  `tools/setup_indexer.sh`. Source `lib/indexer.sh`. Call
  `check_indexer_available()` at startup and set `INDEXER_AVAILABLE=true/false`.
- `lib/config.sh` — add defaults: `REPO_MAP_ENABLED=false`,
  `REPO_MAP_TOKEN_BUDGET=2048`, `REPO_MAP_CACHE_DIR=".claude/index"`,
  `REPO_MAP_LANGUAGES="auto"` (auto-detect from file extensions),
  `SERENA_ENABLED=false`, `SERENA_CONFIG_PATH=""`.
- `templates/pipeline.conf.example` — add indexer config section with explanatory
  comments

Acceptance criteria:
- `tekhton --setup-indexer` creates virtualenv and installs dependencies
- `check_indexer_available` returns 0 when venv + tree-sitter exist, 1 otherwise
- When `REPO_MAP_ENABLED=true` but Python unavailable, pipeline logs a warning
  and falls back to 2.0 behavior (no error, no abort)
- Config keys are validated (token budget must be positive integer, etc.)
- `.claude/indexer-venv/` is added to the default `.gitignore` warning check
- All existing tests pass
- `bash -n lib/indexer.sh tools/setup_indexer.sh` passes
- `shellcheck lib/indexer.sh tools/setup_indexer.sh` passes

Watch For:
- virtualenv creation must work on Linux, macOS, and Windows (Git Bash). Use
  `python3 -m venv` not `virtualenv` command.
- tree-sitter grammar installation varies by platform. The setup script should
  handle failures gracefully per-grammar (some languages may fail on some platforms).
- The `.claude/indexer-venv/` directory can be large. It must never be committed.
- `REPO_MAP_LANGUAGES="auto"` detection should scan file extensions in the project
  root (1 level deep to stay fast), not walk the entire tree.

Seeds Forward:
- Milestone 4 implements the Python tool that `run_repo_map()` invokes
- Milestone 5 wires the repo map output into pipeline stages
- Milestone 6 extends the setup command with `--with-lsp` for Serena
