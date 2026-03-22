# Tekhton 3.0 — Intelligent Indexing & Milestone DAG Design Document

## Problem Statement

Tekhton 2.0 delivered adaptive pipeline behavior: context accounting, milestone
state machines, auto-advance, clarification protocols, specialist reviewers, and
run metrics. However, two fundamental scaling problems remain.

**Context waste from milestones.** All milestone definitions live inline in
CLAUDE.md. A project with 8 milestones loses ~25k characters (48% of the file) to
milestone definitions that agents don't need — they only need the CURRENT milestone.
Completed milestones are archived, but FUTURE milestones that aren't immediately
relevant still bloat the prompt on every agent invocation. Adding more milestones
(parallelization, security agents, UI) makes this worse linearly.

**Context waste from architecture.** Agents receive the full ARCHITECTURE.md and
a large Repository Layout section regardless of what files they're actually touching.
A coder working on `lib/agent.sh` doesn't need the signatures of `tools/repo_map.py`.
There is no mechanism to rank or filter codebase context by task relevance.

Tekhton 3.0 addresses both: a **Milestone DAG** with a sliding context window for
the first problem, and **intelligent indexing** (tree-sitter repo maps + optional
LSP) for the second.

## Design Philosophy

1. **Files are the unit of work.** Each milestone is a standalone `.md` file. The
   manifest tracks the DAG; the file carries the full specification. This enables
   git-level change tracking per milestone and clean parallel execution in the future.

2. **Character budgets, not fixed counts.** The sliding window fills milestone
   context greedily until a character budget is exhausted, not by including a fixed
   number of milestones. Projects with lean CLAUDE.md files get more milestone
   context; heavy ones get less. This naturally adapts.

3. **Rank, don't truncate.** The repo map uses PageRank to surface the most
   task-relevant files. When the token budget is tight, low-ranked files are
   omitted — not arbitrarily truncated. Quality degrades gracefully.

4. **Shell crawls, agent synthesizes.** Indexing infrastructure (tree-sitter
   parsing, graph building) runs as a Python subprocess. The shell orchestrates
   invocation, budget enforcement, and stage-specific slicing. No Python process
   holds state across stages.

5. **Backward compatible.** All 2.0 workflows work unchanged. DAG features are
   auto-detected (manifest exists → use it; no manifest → inline CLAUDE.md
   parsing). Indexer features are opt-in via `REPO_MAP_ENABLED`.

6. **Parallel-ready data model.** DAG edges, parallel groups, and dependency
   tracking exist from day one. The data structures support future parallel
   execution without modification, even though we don't build the execution
   engine yet.

## Target User

Same as 2.0, plus:
- Users with large milestone plans (10+ milestones) where context waste matters
- Users working on large codebases where full architecture injection is wasteful
- Teams planning to use Tekhton's future parallel execution capabilities

## Current Architecture (2.0 Baseline)

Milestones are stored inline in CLAUDE.md as `#### Milestone N: Title` headings.
`parse_milestones()` extracts them to `NUMBER|TITLE|ACCEPTANCE_CRITERIA` format.
The entire CLAUDE.md is available to agents at every stage. Milestone operations
(advance, mark done, split, archive) all manipulate blocks within CLAUDE.md using
`_extract_milestone_block()` and `_replace_milestone_block()`.

Context injection is assembled per-stage in `stages/coder.sh` (and similar) by
concatenating shell variables (`ARCHITECTURE_BLOCK`, `MILESTONE_BLOCK`, etc.) into
prompt templates. The context budget system (`lib/context.sh`) measures and logs
component sizes but has no mechanism to selectively include or exclude milestone
content.

Architecture context comes from reading the full `ARCHITECTURE.md` file into
`ARCHITECTURE_CONTENT`. There is no ranking, filtering, or task-relevance scoring.

---

## System Design: Milestone DAG Infrastructure

### Problem

Milestones are strictly sequential and fully embedded in CLAUDE.md. There is no
mechanism to express dependency relationships (milestone B depends on A and C),
no way to identify which milestones could run in parallel, and no path toward
DAG-based parallel execution. Every milestone definition consumes context on every
agent invocation regardless of relevance.

### Design

**Directory structure:**
```
<project>/.claude/milestones/
    MANIFEST.cfg              # DAG definition (pipe-delimited)
    m01-dag-infrastructure.md # Full milestone specification
    m02-sliding-window.md
    m03-indexer-infra.md
    ...
```

**Manifest format** (`MANIFEST.cfg`):
```
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|DAG Infrastructure|pending||m01-dag-infra.md|foundation
m02|Sliding Window|pending|m01|m02-sliding-window.md|foundation
m03|Indexer Infra|pending|m02|m03-indexer-infra.md|indexing
```

Fields:
- `id` — stable short identifier (`m01`, `m02`). Never renumbered on insert.
- `title` — human-readable name
- `status` — `pending`, `active`, `done`, `skipped`
- `depends_on` — comma-separated milestone IDs (empty = no dependencies)
- `file` — filename within `.claude/milestones/`
- `parallel_group` — advisory label for future parallel execution batching

One line per milestone. Comments (`#`) and blank lines allowed. Parseable with
`IFS='|' read -r id title status deps file group`.

**Milestone files** contain the full specification: description, files to
create/modify, acceptance criteria, watch for, seeds forward. Identical structure
to current inline `#### Milestone N:` headings.

**Core module** (`lib/milestone_dag.sh`):

Data structures — parallel bash arrays with associative index:
```bash
declare -a _DAG_IDS=() _DAG_TITLES=() _DAG_STATUSES=()
declare -a _DAG_DEPS=() _DAG_FILES=() _DAG_GROUPS=()
declare -A _DAG_IDX=()   # _DAG_IDX[id]=array_index for O(1) lookup
```

Functions:
- `load_manifest(path)` — parse MANIFEST.cfg into arrays, return 0 if valid
- `save_manifest(path)` — atomic write (tmpfile + mv) of arrays to MANIFEST.cfg
- `has_milestone_manifest()` — return 0 if MANIFEST.cfg exists and is non-empty
- `dag_get_status(id)` / `dag_set_status(id, status)` — read/write status
- `dag_get_file(id)` / `dag_get_title(id)` / `dag_get_deps(id)` — field accessors
- `dag_deps_satisfied(id)` — return 0 if all deps have status=done
- `dag_get_frontier()` — space-separated IDs: pending milestones with all deps done
- `dag_get_active()` — return ID of the active milestone (or empty)
- `dag_find_next([current_id])` — next milestone to execute (active > frontier)
- `dag_id_to_number(id)` / `dag_number_to_id(number)` — conversion for display
- `validate_manifest()` — check dep references exist, detect cycles (DFS with
  visited set), verify files exist, exactly 0-1 active milestones

**Migration module** (`lib/milestone_dag_migrate.sh`):

- `migrate_inline_milestones(claude_md, milestone_dir)` — extract all inline
  milestones from CLAUDE.md into individual files, generate MANIFEST.cfg.
  Uses existing `_extract_milestone_block()` for block extraction.
  Dependencies inferred from sequential order (each depends on previous) unless
  explicit "depends on Milestone N" references found in text.
  File naming: `m{NN}-{slugified-title}.md`
- `_slugify(title)` — convert title to filename-safe slug

**Dual-path wrapper** (`lib/milestones.sh`):

`parse_milestones_auto(claude_md)` — if manifest exists, return milestone data
from it in the SAME `NUMBER|TITLE|ACCEPTANCE_CRITERIA` format as
`parse_milestones()`. Otherwise, fall back to `parse_milestones()`. All
downstream consumers (`get_milestone_count`, `get_milestone_title`,
`find_next_milestone`, `check_milestone_acceptance`) work unchanged.

**Adapted operations** (milestone_ops.sh, milestone_archival.sh,
milestone_split.sh, milestone_metadata.sh):

Each gains a DAG-aware code path guarded by `has_milestone_manifest()`:
- `mark_milestone_done()` → also calls `dag_set_status(id, "done")` + `save_manifest()`
- `find_next_milestone()` → calls `dag_find_next()` instead of sequential scan
- `archive_completed_milestone()` → reads file directly, appends to archive
- `split_milestone()` → writes sub-milestone files + manifest rows
- `emit_milestone_metadata()` → writes into milestone file instead of CLAUDE.md

### Config Keys

```bash
MILESTONE_DAG_ENABLED=true          # Use manifest+files vs inline CLAUDE.md
MILESTONE_DIR=".claude/milestones"  # Directory for milestone files
MILESTONE_MANIFEST="MANIFEST.cfg"   # Manifest filename within MILESTONE_DIR
MILESTONE_AUTO_MIGRATE=true         # Auto-extract inline milestones on first run
```

### Why This Design

- Pipe-delimited manifests are trivially parseable in bash with `IFS='|' read`.
  No jq, no Python, no new dependencies.
- Individual files enable git-level change tracking per milestone and clean diffs.
- The parallel-arrays + associative-index data structure is the standard bash 4+
  pattern for structured data (matching `_CONF_KEYS_SET` patterns in config.sh).
- Auto-migration means zero manual work for existing projects.
- The DAG data model costs nothing to store but enables future parallel execution.

---

## System Design: Milestone Sliding Window

### Problem

The `MILESTONE_BLOCK` variable injected into agent prompts is currently a static
4-line instruction string. The agent's actual milestone context comes from reading
the full CLAUDE.md, which contains ALL milestone definitions. There is no mechanism
to selectively inject only the relevant milestones.

### Design

**Window assembly** (`lib/milestone_window.sh`):

`build_milestone_window(model)` assembles a character-budgeted milestone context
block from the manifest. Priority order:

1. **Active milestone** (status=active) — full file content, always included
2. **Frontier milestones** (deps satisfied, pending) — first paragraph +
   acceptance criteria
3. **On-deck milestones** (one unsatisfied dep from frontier) — title +
   one-line description only

The window fills greedily, stopping when the character budget is exhausted.

**Budget calculation:**
```
available = (CONTEXT_BUDGET_PCT / 100 * model_window * CHARS_PER_TOKEN) - claude_md_base_chars
milestone_budget = min(available * MILESTONE_WINDOW_PCT / 100, MILESTONE_WINDOW_MAX_CHARS)
```

**Output format** (stored in `MILESTONE_BLOCK` template variable):
```markdown
## Milestone Mode — Active Milestone

### Milestone 3: Indexer Infrastructure
[full content of m03-indexer-infra.md]

---

## Upcoming Milestones (context only — do NOT implement)

### Milestone 4: Tree-Sitter Repo Map (frontier)
[first paragraph + acceptance criteria]

### Milestone 5: Pipeline Integration (on-deck)
[title + one-line description]
```

**Integration points:**
- `stages/coder.sh` — calls `build_milestone_window()` when manifest exists
- No prompt template changes — `MILESTONE_BLOCK` variable already exists
- Context accounting via `_add_context_component()` registration

**Plan generation integration** (`stages/plan_generate.sh`):

After the agent produces CLAUDE.md content (which includes inline milestones),
the shell post-processes:
1. Extract milestone blocks using `parse_milestones()`
2. Write each to an individual file in `.claude/milestones/`
3. Generate MANIFEST.cfg
4. Remove milestone blocks from CLAUDE.md, insert pointer comment

The agent's prompt and expected output format are unchanged.

**Auto-migration** at startup (`tekhton.sh`):

If `MILESTONE_DAG_ENABLED=true` and `MILESTONE_AUTO_MIGRATE=true` and no manifest
exists but inline milestones are detected in CLAUDE.md, automatically run
`migrate_inline_milestones()`.

### Config Keys

```bash
MILESTONE_WINDOW_PCT=30             # % of context budget for milestones
MILESTONE_WINDOW_MAX_CHARS=20000    # Hard cap on window chars
```

### Why This Design

- Character budgeting integrates with the existing context accounting system
  from v2 (CONTEXT_BUDGET_PCT, CHARS_PER_TOKEN).
- Greedy filling with priority ordering ensures the most important milestone
  (the active one) always gets full content, with diminishing detail for
  less-relevant milestones.
- The agent continues to generate monolithic CLAUDE.md during `--plan` — the
  shell handles the extraction. This avoids changing agent prompts or training
  agents on a new output format.

---

## System Design: Tree-Sitter Repo Map Generator

### Problem

Agents receive the full ARCHITECTURE.md and Repository Layout regardless of
task relevance. A coder modifying two files gets the signatures of every file
in the project. This wastes tokens and dilutes signal with noise.

### Design

See CLAUDE.md Milestones 3-8 for the detailed indexer design. Summary:

**Repo map pipeline:**
1. Tree-sitter parses source files → extracts definition/reference tags
2. File-relationship graph built from cross-references
3. PageRank with task-keyword personalization ranks files
4. Token-budgeted output emits only ranked signatures (no bodies)

**Stage-specific slicing:**
- Scout: full ranked map
- Coder: task-relevant slice (scout-identified files + dependencies)
- Reviewer: changed files + reverse dependencies (callers)
- Tester: changed files + test file counterparts

**Optional LSP enrichment** (Serena MCP):
Agents gain `find_symbol`, `find_referencing_symbols` tools for live,
accurate cross-reference queries supplementing the static repo map.

**Cross-run persistence:**
Tag cache (mtime-based invalidation), task→file history (JSONL),
personalization blending (keyword 0.6, history 0.3, recency 0.1).

### Config Keys

```bash
REPO_MAP_ENABLED=false              # Enable tree-sitter repo map
REPO_MAP_TOKEN_BUDGET=2048          # Max tokens for map output
REPO_MAP_CACHE_DIR=".claude/index"  # Index cache directory
REPO_MAP_LANGUAGES="auto"           # Languages to index (or "auto")
REPO_MAP_HISTORY_ENABLED=true       # Track task→file associations
REPO_MAP_HISTORY_MAX_RECORDS=200    # Max history entries
SERENA_ENABLED=false                # Enable Serena LSP via MCP
SERENA_PATH=".claude/serena"        # Serena installation directory
SERENA_CONFIG_PATH=""               # Generated MCP config path
SERENA_LANGUAGE_SERVERS="auto"      # LSP servers (or "auto")
SERENA_STARTUP_TIMEOUT=30           # Seconds to wait for startup
SERENA_MAX_RETRIES=2                # Health check retry attempts
```

---

## Scope Boundaries

### In Scope (3.0)
- Milestone DAG with manifest + individual files
- Character-budgeted sliding window
- Auto-migration from inline CLAUDE.md milestones
- Plan generation producing milestone files + manifest
- Tree-sitter repo map generator with PageRank ranking
- Stage-specific repo map slicing
- Optional Serena LSP integration via MCP
- Cross-run tag cache and task→file history

### Out of Scope (Future)
- Parallel milestone execution (multiple agent teams in worktrees)
- Dedicated security and tech debt agents
- UI / dashboard for milestone progress
- Semantic similarity for task→file matching (vs keyword-based)
- Multi-project monorepo support

### Stretch
- Repository Layout section compression when repo map is active
- Automatic `parallel_group` inference from file overlap analysis

---

## New Files Summary

**lib/ (shell orchestration):**
- `milestone_dag.sh` — DAG infrastructure (manifest parse, queries, validation)
- `milestone_dag_migrate.sh` — inline→file migration
- `milestone_window.sh` — sliding window assembly
- `indexer.sh` — repo map orchestration + Python tool invocation
- `mcp.sh` — MCP server lifecycle management (Serena)

**tools/ (Python, optional dependency):**
- `repo_map.py` — tree-sitter parser + PageRank ranker
- `tag_cache.py` — disk-based tag cache
- `tree_sitter_languages.py` — language detection + grammar loading
- `requirements.txt` — pinned Python dependencies
- `setup_indexer.sh` — indexer virtualenv setup
- `setup_serena.sh` — Serena MCP server setup
- `serena_config_template.json` — MCP config template

**tests/:**
- `test_milestone_dag.sh` — DAG parsing, queries, cycle detection, migration
- `test_milestone_window.sh` — budget calculation, priority ordering

## Modified Files Summary

- `lib/milestones.sh` — add `parse_milestones_auto()` dual-path wrapper
- `lib/milestone_ops.sh` — DAG-aware `find_next_milestone()`, `mark_milestone_done()`
- `lib/milestone_archival.sh` — file-based archival path
- `lib/milestone_split.sh` — file-based splitting path
- `lib/milestone_metadata.sh` — metadata in milestone files
- `lib/config_defaults.sh` — new config keys + clamps
- `lib/config.sh` — MILESTONE_DIR path resolution
- `lib/context.sh` — repo map as named context component
- `stages/coder.sh` — milestone window + repo map injection
- `stages/review.sh` — repo map slice injection
- `stages/tester.sh` — repo map slice injection
- `stages/plan_generate.sh` — milestone file extraction post-processing
- `lib/orchestrate_helpers.sh` — DAG-aware auto-advance
- `tekhton.sh` — source new modules, DAG init, auto-migration, setup commands
- `templates/pipeline.conf.example` — new config sections
- `prompts/coder.prompt.md` — repo map + Serena conditional blocks
- `prompts/reviewer.prompt.md` — repo map conditional block
- `prompts/tester.prompt.md` — repo map conditional block
- `prompts/scout.prompt.md` — repo map conditional block
- `prompts/architect.prompt.md` — repo map conditional block

## Backward Compatibility

| Feature | Default | Opt-in Mechanism |
|---------|---------|-----------------|
| Milestone DAG | on (auto-detect) | MILESTONE_DAG_ENABLED=false to disable |
| Sliding window | on when DAG active | MILESTONE_WINDOW_PCT / MAX_CHARS |
| Auto-migration | on | MILESTONE_AUTO_MIGRATE=false to disable |
| Repo map | off | REPO_MAP_ENABLED=true |
| Serena LSP | off | SERENA_ENABLED=true |
| Cross-run cache | on when repo map on | REPO_MAP_HISTORY_ENABLED=false |
