# Milestone 67: Structured Project Index Data Layer
<!-- milestone-meta
id: "67"
status: "done"
-->

## Overview

PROJECT_INDEX.md is a single markdown file trying to serve three incompatible
roles simultaneously:

1. **Human-readable project map** — needs to be bounded and browsable
2. **Programmatic project index** — needs to be complete and queryable
3. **LLM prompt context** — needs to be bounded and compressible

The current architecture (introduced in M18, refined in M20) generates this
single file with a hard character budget (120,000 chars), then truncates sections
that exceed their allocation with a `... (truncated to fit budget)` marker. For
brownfield projects of any significant size, this means the index is lossy from
the moment it's created — file inventories are cut mid-table, dependency graphs
are incomplete, and sampled content is arbitrarily shortened.

Every downstream consumer then applies additional lossy transformations:
- `_safe_read_file` in intake rejects the entire file if it exceeds 8KB
- `compress_context` with `summarize_headings` drops all non-heading lines
  (destroying the entire inventory table)
- `_replace_section` passes full section bodies through awk ENVIRON (ARG_MAX risk)

**This milestone replaces the monolithic markdown producer with a structured data
layer.** Individual data files in `.claude/index/` store the complete, unbounded
project data. A separate milestone (M69) generates the bounded human-readable
PROJECT_INDEX.md view from this data.

Depends on M66 (last completed V3 milestone) for stable pipeline baseline.

## Scope

### 1. Directory Schema: `.claude/index/`

**New directory:** `.claude/index/` (already partially used by tree-sitter repo
map cache from M07 — `task_history.jsonl` lives here).

Create the following files during a crawl:

| File | Format | Content | Bounded? |
|------|--------|---------|----------|
| `meta.json` | JSON | Scan metadata (date, commit, file count, total lines, doc quality score) | Yes (~500B) |
| `tree.txt` | Plain text | Directory tree output (no markdown wrapper) | Soft cap at depth 6, no hard truncation |
| `inventory.jsonl` | JSONL | One record per tracked file: path, lines, size category, directory | No — complete |
| `dependencies.json` | JSON | Dependency graph (same data as current `## Key Dependencies`) | No — complete |
| `configs.json` | JSON | Config file inventory with purpose annotations | No — complete |
| `tests.json` | JSON | Test infrastructure: directories, frameworks, coverage | No — complete |
| `samples/` | Directory | One file per sampled source file, plain text content | Budget-aware per file |

**Why JSONL for inventory:** The file inventory is the section most likely to
blow the budget on large projects (a 5,000-file repo produces ~300KB of markdown
table). JSONL is append-friendly, line-grep-friendly, and can be streamed without
loading the entire dataset. This follows the precedent set by M07's
`task_history.jsonl` in the same directory.

**Why JSON (not JSONL) for deps/configs/tests:** These are small, self-contained
structures that benefit from being a single parseable unit. They rarely exceed
a few KB even for large projects.

### 2. Rewrite `crawl_project()` as Structured Emitter

**File:** `lib/crawler.sh`

Replace the current `crawl_project()` (lines 31-109) with a new implementation
that writes to `.claude/index/` instead of assembling a single markdown string.

**New flow:**

```
crawl_project()
  ├─ _ensure_index_dir()          # mkdir -p .claude/index/samples
  ├─ file_list=$(_list_tracked_files)  # ONCE — cached for all phases
  ├─ _emit_meta_json()            # writes meta.json
  ├─ _emit_tree_txt()             # writes tree.txt
  ├─ _emit_inventory_jsonl()      # writes inventory.jsonl
  ├─ _emit_dependencies_json()    # writes dependencies.json
  ├─ _emit_configs_json()         # writes configs.json
  ├─ _emit_tests_json()           # writes tests.json
  └─ _emit_sampled_files()        # writes samples/<filename>.txt
```

**Critical: single `_list_tracked_files` call.** The current code calls
`_list_tracked_files` independently in `crawl_project` (line 62),
`_crawl_file_inventory` (crawler_inventory.sh:28), `_crawl_config_inventory`
(crawler_inventory.sh:98), and `_crawl_test_structure` (crawler_inventory.sh:178).
The new implementation passes the file list as a parameter to all sub-functions.

**All writes are atomic.** Each emitter writes to a temp file in the same
directory (via `mktemp`), then `mv` to the final path. This prevents partial
writes if the crawl is interrupted.

### 3. `_emit_meta_json()` — Scan Metadata

**File:** `lib/crawler.sh` (new function, replaces `_build_index_header`)

Writes `.claude/index/meta.json`:

```json
{
  "schema_version": 1,
  "project_name": "my-project",
  "scan_date": "2026-04-09T12:00:00Z",
  "scan_commit": "abc1234",
  "file_count": 342,
  "total_lines": 48291,
  "doc_quality_score": 65
}
```

**Fix for issue #10 (wc -l per file in header):** The current `_build_index_header`
at crawler.sh:233-271 counts total lines by running `wc -l` per file in a
while-read loop — O(n) process spawns. Replace with a single `xargs wc -l`
batch (same pattern already used in `_crawl_file_inventory` at
crawler_inventory.sh:37-43). Compute `file_count` and `total_lines` from the
inventory JSONL after it's emitted (read the file, count lines for file_count,
sum the lines field for total_lines).

### 4. `_emit_tree_txt()` — Directory Tree

**File:** `lib/crawler.sh` (new function, replaces `_crawl_directory_tree`)

Writes `.claude/index/tree.txt` as plain text (no markdown fences).

**Fix for issue #9 (hardcoded `head -500` truncation):** The current
`_crawl_directory_tree` at crawler.sh:154 pipes through `head -500`, silently
dropping directories beyond line 500 with no indicator. The new emitter:
- Writes the full tree output to `tree.txt` (no truncation)
- Records the line count in `meta.json` as `"tree_lines": N`
- The M69 markdown view generator applies display truncation with a proper
  indicator when rendering the human-readable view

The `_find_based_tree` fallback (crawler.sh:166-181) also gets the same treatment
— remove `head -500`, write complete output.

### 5. `_emit_inventory_jsonl()` — File Inventory

**File:** `lib/crawler_inventory.sh` (rewrite of `_crawl_file_inventory`)

Writes `.claude/index/inventory.jsonl`, one JSON record per line:

```jsonl
{"path":"src/main.ts","dir":"src","lines":142,"size":"small"}
{"path":"src/utils/helpers.ts","dir":"src/utils","lines":89,"size":"small"}
{"path":"tests/main.test.ts","dir":"tests","lines":203,"size":"medium"}
```

**Fix for issue #4 (O(n^2) bash string concatenation):** The current
`_crawl_file_inventory` at crawler_inventory.sh:25-88 builds an `$output`
string via `+=` in a while loop. Each append copies the entire accumulated
string — O(n^2) for n files. The new emitter writes each record directly to
the temp file via `>>` — O(n) total.

**Batched line counting preserved:** Keep the `xargs wc -l` batch pattern from
crawler_inventory.sh:37-43 for efficiency. Parse results into an associative
array, then emit one JSONL record per file with the pre-computed line count.

**Size categories:** Same thresholds as current code (tiny <50, small <200,
medium <500, large <1000, huge >=1000).

### 6. `_emit_dependencies_json()` — Dependency Graph

**File:** `lib/crawler_deps.sh` (add new emitter alongside existing
`_crawl_dependency_graph`)

Writes `.claude/index/dependencies.json`:

```json
{
  "manifests": [
    {"file": "package.json", "manager": "npm", "deps": 12, "dev_deps": 8},
    {"file": "pyproject.toml", "manager": "pip", "deps": 5, "dev_deps": 3}
  ],
  "key_dependencies": [
    {"name": "react", "version": "^18.2.0", "manifest": "package.json"},
    {"name": "fastapi", "version": ">=0.100", "manifest": "pyproject.toml"}
  ]
}
```

The existing `_crawl_dependency_graph` function's markdown output is preserved
as-is for backward compatibility during M69 view generation. The new
`_emit_dependencies_json` extracts the same data into structured JSON.

### 7. `_emit_configs_json()` — Configuration Inventory

**File:** `lib/crawler_inventory.sh` (add new emitter alongside existing
`_crawl_config_inventory`)

Writes `.claude/index/configs.json`:

```json
{
  "configs": [
    {"path": ".eslintrc.json", "purpose": "ESLint configuration"},
    {"path": "tsconfig.json", "purpose": "TypeScript configuration"},
    {"path": "Dockerfile", "purpose": "Docker container definition"}
  ]
}
```

Reuses the same case-match purpose detection from `_crawl_config_inventory`
(crawler_inventory.sh:108-162).

### 8. `_emit_tests_json()` — Test Infrastructure

**File:** `lib/crawler_inventory.sh` (add new emitter alongside existing
`_crawl_test_structure`)

Writes `.claude/index/tests.json`:

```json
{
  "test_dirs": [
    {"path": "tests/", "file_count": 24},
    {"path": "e2e/", "file_count": 8}
  ],
  "test_file_count": 32,
  "frameworks": ["jest", "playwright"],
  "coverage": ["nyc"]
}
```

### 9. `_emit_sampled_files()` — File Content Samples

**File:** `lib/crawler_content.sh` (rewrite of `_crawl_sample_files`)

Writes individual files to `.claude/index/samples/<sanitized_path>.txt`.

Path sanitization: replace `/` with `__` (e.g., `src/main.ts` becomes
`src__main.ts.txt`). This avoids creating nested directories in the samples
folder while preserving readability.

**Budget-aware sampling preserved:** The priority ordering (README > entry
points > config > architecture docs > tests > source) and per-file char budget
from `_read_sampled_file` remain unchanged. The difference is that each sample
is written to its own file instead of concatenated into a single string.

Also write `.claude/index/samples/manifest.json` listing which files were
sampled, their original paths, and their sizes:

```json
{
  "samples": [
    {"original": "README.md", "stored": "README.md.txt", "chars": 2400},
    {"original": "src/main.ts", "stored": "src__main.ts.txt", "chars": 1800}
  ],
  "total_chars": 4200,
  "budget_chars": 66000
}
```

### 10. Budget Constant Consolidation

**Files:** `lib/crawler.sh`, `lib/rescan.sh`, `lib/init.sh`, `tekhton.sh`

**Fix for issue #6 (hardcoded 120000 magic numbers):** The value `120000` appears
at four call sites:
- `lib/init.sh:121` — `crawl_project "$project_dir" 120000`
- `tekhton.sh:482` — `rescan_project "$PROJECT_DIR" 120000 "$local_full"`
- `lib/rescan.sh:39,46,53,63,71,96` — passthrough to `crawl_project`
- `lib/crawler.sh:33` — default parameter `${2:-120000}`

Introduce a config key in `lib/config_defaults.sh`:

```bash
: "${PROJECT_INDEX_BUDGET:=120000}"
```

Replace all hardcoded `120000` references with `"${PROJECT_INDEX_BUDGET}"`.
The default remains 120000 for backward compatibility, but users with very
large codebases can increase it.

**Note:** In the new structured architecture, this budget primarily governs the
markdown view generation (M69) and sample file budgets — not the structured data
files themselves, which are unbounded.

### 11. Backward Compatibility Bridge

**File:** `lib/crawler.sh`

After emitting all structured files, the new `crawl_project()` ALSO generates
PROJECT_INDEX.md using the existing assembly logic (reading from structured
files instead of in-memory strings). This ensures all existing consumers
continue to work unchanged until they are migrated in M68.

This bridge is temporary — M69 replaces it with the proper view generator.

Implementation: after all `_emit_*` calls complete, call a
`_generate_legacy_index()` function that reads the structured files and
assembles the markdown. This function uses `_truncate_section` for now —
the truncation markers will still appear in the legacy view, but the underlying
data in `.claude/index/` is complete.

### 12. Fix `_record_scan_metadata()` Duplicate Work

**File:** `lib/rescan_helpers.sh`

**Fix for issue #10 (duplicate wc -l per file):** `_record_scan_metadata`
at rescan_helpers.sh:154-184 recomputes file count and total lines from
scratch using `_list_tracked_files` + per-file `wc -l`. After M67, this
data is already in `meta.json` and `inventory.jsonl`.

Rewrite `_record_scan_metadata` to:
1. Read `file_count` and `total_lines` from `.claude/index/meta.json`
2. Update only the scan-specific fields (date, commit) in both `meta.json`
   and the PROJECT_INDEX.md header comments
3. Remove the per-file `wc -l` loop entirely

## Migration Impact

| Key | Default | Notes |
|-----|---------|-------|
| `PROJECT_INDEX_BUDGET` | `120000` | Governs markdown view size, not structured data |

No breaking changes. The new `crawl_project()` produces both structured files
AND the legacy PROJECT_INDEX.md. Existing consumers see no difference until
M68 migrates them.

The `.claude/index/` directory already exists in projects that use the
tree-sitter indexer (M03-M08). The new files coexist with the existing
`tag_cache.json`, `task_history.jsonl`, and repo map cache.

## Acceptance Criteria

- `crawl_project()` writes all 7 structured files to `.claude/index/`
- `meta.json` contains correct scan metadata including schema_version
- `tree.txt` contains complete directory tree (no `head -500` truncation)
- `inventory.jsonl` has one record per tracked file with correct line counts
- `dependencies.json` captures all detected package manifests and key deps
- `configs.json` lists all config files with purpose annotations
- `tests.json` records test directories, frameworks, and coverage
- `samples/` directory contains individual sample files with manifest
- `_list_tracked_files` is called exactly once per crawl (not 4 times)
- All file writes are atomic (mktemp + mv pattern)
- `PROJECT_INDEX_BUDGET` config key replaces hardcoded `120000` at all call sites
- Legacy PROJECT_INDEX.md is still generated for backward compatibility
- `_record_scan_metadata` reads from structured data instead of recomputing
- All existing tests pass (backward compatibility bridge ensures this)

Tests:
- `crawl_project` creates `.claude/index/` directory with all expected files
- `meta.json` is valid JSON with all required fields
- `inventory.jsonl` line count matches `meta.json` file_count
- `inventory.jsonl` lines field sum matches `meta.json` total_lines
- `dependencies.json` is valid JSON, captures manifests found in test fixture
- `configs.json` is valid JSON, lists config files from test fixture
- `tests.json` is valid JSON, detects test directories from test fixture
- `samples/manifest.json` lists sampled files with correct stored paths
- Sample files exist on disk and contain expected content
- `tree.txt` is not truncated for test fixture (fixture is small)
- Atomic write: interrupted crawl leaves no partial files
- `PROJECT_INDEX_BUDGET` config key is respected when set
- Legacy PROJECT_INDEX.md is generated and matches prior format
- Existing `test_crawler_budget.sh` tests still pass

Watch For:
- **`.claude/index/` permissions:** The directory is created by `mkdir -p`. On
  shared systems, ensure it inherits the project directory's umask. Do not
  chmod explicitly — let the system default handle it.
- **JSONL newline discipline:** Every JSONL record must end with exactly one
  newline (`\n`). Use `printf '%s\n' "$record"` not `echo` (which may add
  trailing newlines on some platforms). Empty inventory (zero files) should
  produce an empty file, not a file with a blank line.
- **JSON generation in bash:** Use `printf` with explicit escaping for JSON
  string values. File paths may contain characters that need JSON escaping
  (quotes, backslashes). Use a helper function `_json_escape()` that handles
  `"`, `\`, and control characters.
- **Associative array size limits:** Bash associative arrays can handle tens of
  thousands of entries on modern systems. The `file_lines` array from
  `_crawl_file_inventory` already uses this pattern — no change needed.
- **`samples/` cleanup:** When re-crawling, remove stale sample files from
  a prior crawl before writing new ones. `rm -f .claude/index/samples/*.txt`
  at the start of `_emit_sampled_files()` handles this. Do NOT rm the entire
  `samples/` directory (it might contain other files in future milestones).
- **ARG_MAX safety:** The `_emit_inventory_jsonl` function writes records one
  at a time via `>>` append. It never accumulates the full inventory in a
  shell variable. This sidesteps the ARG_MAX concern entirely.
- **schema_version field:** Set to `1` in this milestone. If the schema
  changes in future milestones, consumers check this field and can handle
  migration. Do not over-engineer versioning — a simple integer is sufficient.

Seeds Forward:
- M68 migrates consumers to read structured data directly
- M69 generates the bounded markdown view from structured data
- Complete structured data enables future features: incremental diffing,
  cross-project comparison, programmatic queries
- JSONL inventory enables `jq` one-liners for ad-hoc project analysis
