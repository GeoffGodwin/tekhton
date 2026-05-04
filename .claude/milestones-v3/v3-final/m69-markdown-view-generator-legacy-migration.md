# Milestone 69: Markdown View Generator, Rescan Rewrite & Legacy Migration
<!-- milestone-meta
id: "69"
status: "done"
-->

## Overview

M67 creates the structured data layer. M68 migrates consumers to read from it.
This milestone completes the trilogy:

1. **Markdown view generator** — Replaces the backward-compatibility bridge from
   M67 with a proper, bounded PROJECT_INDEX.md renderer that assembles the human
   view from structured data. No truncation markers, no lossy compression — just
   intelligent record selection within budget.

2. **Rescan rewrite** — The current incremental rescan (`lib/rescan.sh`,
   `lib/rescan_helpers.sh`) performs surgical section replacement on the markdown
   file using `_replace_section` and re-applies `_truncate_section` per section.
   This approach has multiple issues:
   - `_replace_section` passes section bodies through awk's ENVIRON (ARG_MAX
     risk for large sections on macOS — issue #3)
   - Orphaned truncation markers from deleted files persist (issue #11)
   - The incremental complexity is no longer worth the maintenance cost when
     the underlying data is structured (issue #12)
   
   Replace incremental markdown patching with structured data updates + markdown
   view regeneration.

3. **Legacy cleanup** — Remove `_truncate_section`, the compression cascade in
   `_compress_synthesis_context`, and other code that only existed because of the
   monolithic markdown architecture.

4. **Test rewrite** — Update `tests/test_crawler_budget.sh` and add new tests
   for the view generator and rescan rewrite.

Depends on M68 for the consumer migration (no consumer reads raw markdown after M68).

## Scope

### 1. Markdown View Generator

**New file:** `lib/index_view.sh`

Provides `generate_project_index_view()` — reads from `.claude/index/` and
writes a bounded, human-readable `PROJECT_INDEX.md`.

```bash
# generate_project_index_view — Assembles PROJECT_INDEX.md from structured data.
# Args: $1 = project directory, $2 = budget in chars (default: PROJECT_INDEX_BUDGET)
# Output: Writes PROJECT_INDEX.md to project directory
generate_project_index_view()
```

**Internal structure:**

```
generate_project_index_view()
  ├─ _render_header()         # From meta.json → markdown header with HTML comments
  ├─ _render_tree()           # From tree.txt → ## Directory Tree (capped at 300 lines)
  ├─ _render_inventory()      # From inventory.jsonl → ## File Inventory (smart selection)
  ├─ _render_dependencies()   # From dependencies.json → ## Key Dependencies
  ├─ _render_configs()        # From configs.json → ## Configuration Files
  ├─ _render_tests()          # From tests.json → ## Test Infrastructure
  └─ _render_samples()        # From samples/ → ## Sampled File Content
```

**Budget allocation (same percentages as M18):**

| Section | % | Purpose |
|---------|---|---------|
| Tree | 10% | Directory structure |
| Inventory | 15% | File listing |
| Dependencies | 10% | Package manifests |
| Configs | 5% | Config files |
| Tests | 5% | Test infrastructure |
| Samples | 55% | File content |

**Key difference from old approach:** When a section's data fits within its
allocation, it's included in full (no truncation). When data exceeds the
allocation, the renderer **selects** records instead of truncating:

- **Inventory:** Sort by size category (huge > large > medium > small > tiny),
  then by directory breadth. Include records until budget is reached. Append a
  count line: `... and 2,847 more files (see .claude/index/inventory.jsonl for
  complete listing)`. This is a **selection** indicator, not a truncation marker
  — the underlying data is complete.
- **Tree:** Include first N lines (cap at 300 for very deep trees). Append:
  `... (N more directories — see .claude/index/tree.txt for full tree)`.
- **Samples:** Include highest-priority samples that fit. No truncation of
  individual sample content — either a sample file fits or it's skipped.
- **Deps/Configs/Tests:** These are typically small enough to fit in full.
  If they somehow exceed budget, include the first N records.

**Atomic write:** Write to temp file, then `mv` to `PROJECT_INDEX.md`.

### 2. Update `crawl_project()` to Use View Generator

**File:** `lib/crawler.sh`

Replace the M67 backward-compatibility bridge (`_generate_legacy_index()`) with
a call to `generate_project_index_view()`:

```bash
crawl_project() {
    local project_dir="${1:-.}"
    local budget_chars="${2:-${PROJECT_INDEX_BUDGET:-120000}}"

    # Phase 1: Emit structured data (M67)
    _ensure_index_dir "$project_dir"
    local file_list
    file_list=$(_list_tracked_files "$project_dir")
    _emit_meta_json "$project_dir" "$file_list"
    _emit_tree_txt "$project_dir"
    _emit_inventory_jsonl "$project_dir" "$file_list"
    _emit_dependencies_json "$project_dir" "$file_list"
    _emit_configs_json "$project_dir" "$file_list"
    _emit_tests_json "$project_dir" "$file_list"
    _emit_sampled_files "$project_dir" "$file_list" "$budget_chars"

    # Phase 2: Generate human-readable view (M69)
    generate_project_index_view "$project_dir" "$budget_chars"
}
```

### 3. Rescan Rewrite — Structured Updates

**File:** `lib/rescan.sh` (rewrite of `_update_index_sections`)

The current `_update_index_sections` (rescan.sh:117-232) regenerates individual
markdown sections and patches them into the file using `_replace_section`. This
is replaced with a simpler flow:

```bash
_update_index_sections() {
    local project_dir="$1"
    local changed_files="$2"
    local budget_chars="$3"

    local file_list
    file_list=$(_list_tracked_files "$project_dir")

    # Determine which structured files need regeneration
    local regen_tree=false regen_inventory=false
    local regen_deps=false regen_configs=false regen_samples=false

    # ... same detection logic as current code (lines 124-180) ...

    # Regenerate only affected structured files
    [[ "$regen_tree" == true ]]      && _emit_tree_txt "$project_dir"
    [[ "$regen_inventory" == true ]] && _emit_inventory_jsonl "$project_dir" "$file_list"
    [[ "$regen_deps" == true ]]      && _emit_dependencies_json "$project_dir" "$file_list"
    [[ "$regen_configs" == true ]]   && _emit_configs_json "$project_dir" "$file_list"
    [[ "$regen_samples" == true ]]   && _emit_sampled_files "$project_dir" "$file_list" "$budget_chars"

    # Always update meta (scan date, commit, file count)
    _emit_meta_json "$project_dir" "$file_list"

    # Regenerate the markdown view from updated structured data
    generate_project_index_view "$project_dir" "$budget_chars"
}
```

**What this fixes:**

- **Issue #3 (ARG_MAX risk):** `_replace_section` is no longer called. The old
  function passed section bodies through awk's ENVIRON variable, which is subject
  to `execve` ARG_MAX limits (~1MB on macOS). Large inventory sections could
  silently fail. With structured updates, each emitter writes directly to files
  — no shell variable accumulation of section bodies.

- **Issue #11 (orphaned truncation markers):** No longer possible. The markdown
  view is regenerated from scratch each time — there are no "old" markers to
  become orphaned. If a file is deleted, it disappears from `inventory.jsonl`
  on the next `_emit_inventory_jsonl` call, and the view generator never sees it.

- **Issue #12 (incremental complexity not worth it):** The rescan still
  performs incremental *detection* (which sections changed), but the *update*
  is now a simple re-emit of affected structured files followed by a full view
  regeneration. The view generator is fast (it reads files and formats text —
  no `tree` command, no `wc -l`, no git calls). This gives us the performance
  benefit of incremental detection without the complexity of surgical markdown
  patching.

### 4. Remove `_replace_section` and `_truncate_section`

**Files:** `lib/rescan_helpers.sh`, `lib/crawler.sh`

After M69, no code calls `_replace_section` or `_truncate_section`. Remove them:

- **`_replace_section`** (rescan_helpers.sh:112-136) — DELETE. Was the ARG_MAX
  risk vector. No longer needed when rescan regenerates views from structured data.

- **`_truncate_section`** (crawler.sh:219-230) — DELETE. Was the function that
  produced the `... (truncated to fit budget)` marker that triggered this entire
  initiative. No longer needed when the view generator uses record selection
  instead of string truncation.

### 5. Remove Synthesis Compression Cascade (Issue #14)

**File:** `lib/init_synthesize_helpers.sh`

After M68 migrates synthesis to use `read_index_summary()`, the
`_compress_synthesis_context` function's PROJECT_INDEX compression step is dead
code. The function at lines 127-189 has a 4-step cascade:

1. Compress index with `summarize_headings` ← **remove (M68 made this unnecessary)**
2. Truncate README to 50 lines ← **keep**
3. Truncate ARCHITECTURE.md to 50 lines ← **keep**
4. Truncate git log to 10 entries ← **keep**

Remove step 1 and its associated re-check block (lines 145-161). The README,
ARCHITECTURE.md, and git log compression steps remain — they operate on
different content that is NOT part of the structured index.

Verify that `compress_context "summarize_headings"` in `lib/context_compiler.sh`
is not called from anywhere else after this removal. If it is, keep the function
but remove the call site in synthesis. If `summarize_headings` has no remaining
callers, add a deprecation comment but don't remove the function yet (it may
be useful for other contexts).

### 6. Remove Old Crawler Section Assembly

**File:** `lib/crawler.sh`

After M69, the Phase 4 (truncation) and Phase 6 (assembly) blocks in
`crawl_project()` are replaced by the view generator call. Remove:

- Lines 65-77: Phase 4 truncation block (all `_truncate_section` calls)
- Lines 91-103: Phase 6 assembly block (the `{ printf ... } > "$index_file"`)

These are replaced by the single `generate_project_index_view()` call.

### 7. Rescan `_record_scan_metadata` Simplification

**File:** `lib/rescan_helpers.sh`

M67 already rewrites `_record_scan_metadata` to read from structured data.
M69 goes further: since the view is now regenerated from `meta.json` data,
`_record_scan_metadata` only needs to update `meta.json`. The HTML comment
updates in PROJECT_INDEX.md (`sed -i` calls at lines 176-183) are no longer
needed — the view generator reads `meta.json` and emits fresh HTML comments.

Simplify to:

```bash
_record_scan_metadata() {
    local project_dir="$1"
    # Update meta.json with current scan info
    _emit_meta_json "$project_dir" "$(_list_tracked_files "$project_dir")"
    # View will be regenerated by caller
}
```

The `sed -i` calls that patch HTML comments in PROJECT_INDEX.md and the
visible `**Scanned:**` line are removed. The view generator handles all of this.

### 8. Test Rewrite

**File:** `tests/test_crawler_budget.sh` (rewrite)

The existing test file tests `_budget_allocator` and `_truncate_section`.
After M69:

- `_truncate_section` is deleted → remove those tests
- `_budget_allocator` is still used by the view generator → keep those tests
- Add new tests for the view generator

**New test file:** `tests/test_index_structured.sh`

Tests for the complete M67-M69 pipeline:

```bash
# Test: Structured index emission
# - crawl_project writes all structured files
# - meta.json has correct schema_version
# - inventory.jsonl records match file count
# - samples/manifest.json lists sampled files

# Test: View generator produces valid markdown
# - Output contains all 6 section headings
# - Output fits within budget
# - No truncation markers in output
# - Selection indicators present when data exceeds section budget

# Test: View generator budget compliance
# - With 10000-char budget: output <= 10000 chars
# - With 1000-char budget: output <= 1000 chars, still has header
# - With large budget: output includes all data (no selection needed)

# Test: Rescan structured update
# - After adding a file, rescan updates inventory.jsonl
# - After deleting a file, it disappears from inventory.jsonl
# - After modifying a manifest, dependencies.json is regenerated
# - View is regenerated with updated data

# Test: Reader API (from M68)
# - read_index_summary respects budget
# - read_index_inventory with filter returns subset
# - read_index_meta returns correct fields
# - Legacy fallback works when .claude/index/ doesn't exist

# Test: No truncation markers
# - After crawl, PROJECT_INDEX.md does not contain "truncated to fit budget"
# - After rescan, PROJECT_INDEX.md does not contain "truncated to fit budget"
```

**Update `tests/test_crawler_budget.sh`:**

- Remove `_truncate_section` tests (function deleted)
- Keep `_budget_allocator` tests (function still exists in view generator)
- Add view generator budget compliance tests
- Rename file to `tests/test_index_budget.sh` for clarity

### 9. Migration: One-Time Upgrade from Legacy Format

**File:** `lib/crawler.sh` (or `lib/rescan.sh`)

When `rescan_project` or `crawl_project` is called on a project that has
`PROJECT_INDEX.md` but no `.claude/index/` directory:

1. Log: `"Upgrading to structured project index (one-time migration)..."`
2. Run a full crawl (which now produces structured files + view)
3. The old PROJECT_INDEX.md is overwritten by the new view

This is not a parsing migration (we don't try to extract structured data from
the old markdown). It's simply a full re-crawl. Given that `--reinit` and
`--rescan --full` already trigger full crawls, the migration path is natural.

For incremental rescan (without `--full`), if `.claude/index/meta.json` doesn't
exist, force a full crawl:

```bash
# In rescan_project(), after the existing index check:
if [[ ! -f "${project_dir}/.claude/index/meta.json" ]]; then
    log "No structured index found — running full crawl for migration..."
    crawl_project "$project_dir" "$budget_chars"
    return $?
fi
```

### 10. `.gitignore` Considerations

**File:** Project's `.gitignore` (documentation only — Tekhton doesn't modify it)

The `.claude/index/` directory contains generated data that should not be
committed. Most projects already have `.claude/` in their `.gitignore` (added
by `--init`). Document in the milestone that:

- `.claude/index/` is gitignored by the existing `.claude/` pattern
- If a project gitignores only specific `.claude/` subdirectories, they may
  need to add `.claude/index/` explicitly
- PROJECT_INDEX.md at the project root is intentionally NOT gitignored — it's
  the human-readable view meant to be browsable

## Migration Impact

| Key | Default | Notes |
|-----|---------|-------|
| (none) | | No new config keys |

**Removed functions:**
- `_truncate_section` (crawler.sh) — deleted
- `_replace_section` (rescan_helpers.sh) — deleted
- `_generate_legacy_index` (crawler.sh, M67 bridge) — deleted

**New source file:** `lib/index_view.sh` — must be sourced in `tekhton.sh`
alongside `lib/index_reader.sh` (M68). Add after the M68 source line.

**Behavioral change:** PROJECT_INDEX.md no longer contains `... (truncated to
fit budget)` markers. Instead, sections that exceed their budget show
selection indicators like `... and N more files (see .claude/index/inventory.jsonl
for complete listing)`. The underlying data in `.claude/index/` is always
complete.

## Acceptance Criteria

- `generate_project_index_view()` produces valid markdown from structured data
- PROJECT_INDEX.md output fits within `PROJECT_INDEX_BUDGET` chars
- No `... (truncated to fit budget)` markers appear anywhere in the output
- Selection indicators show when data exceeds section budget
- Rescan uses structured file updates + view regeneration (no `_replace_section`)
- `_truncate_section` and `_replace_section` are deleted
- Synthesis compression cascade no longer compresses index content
- Incremental rescan correctly detects and updates affected structured files
- Legacy projects auto-migrate on first rescan or crawl
- `test_crawler_budget.sh` updated (truncation tests removed, view tests added)
- New `test_index_structured.sh` covers the full pipeline
- All existing tests pass

Tests:
- View generator output contains all 6 section headings (## Directory Tree, etc.)
- View generator output size <= budget for budgets 1000, 10000, 50000, 120000
- View generator inventory section uses selection (not truncation) for large data
- View generator tree section capped at 300 lines with indicator
- View generator samples section includes only complete samples (no mid-file cuts)
- Rescan with file addition updates inventory.jsonl and regenerates view
- Rescan with file deletion removes from inventory.jsonl and regenerates view
- Rescan with manifest change regenerates dependencies.json and view
- Rescan forced full crawl produces identical result to fresh crawl
- Legacy migration: project with old PROJECT_INDEX.md but no .claude/index/
  triggers full crawl and creates structured files
- No truncation markers in any output (grep -r "truncated to fit budget")
- `_budget_allocator` tests still pass (function preserved for view generator)
- `_truncate_section` is not callable (function removed)

Watch For:
- **View generator performance:** The generator reads multiple files from
  `.claude/index/`. For typical projects this is fast (< 100ms). For very
  large projects with thousands of inventory records, reading and sorting
  the JSONL may take noticeable time. Monitor this and consider caching the
  sorted inventory if it becomes a bottleneck.
- **Selection indicator wording:** The indicators should guide users to the
  complete data. Use consistent phrasing:
  - Inventory: `... and N more files (see .claude/index/inventory.jsonl)`
  - Tree: `... (N more lines — see .claude/index/tree.txt)`
  - Samples: `... (N more files available — sampled M of N candidates)`
- **Rescan atomicity:** The rescan now writes multiple structured files and
  then regenerates the view. If interrupted between structured writes and
  view generation, the structured data is updated but the view is stale.
  This is acceptable — the next rescan or crawl will regenerate the view.
  Do NOT try to make the entire rescan atomic (it would require writing all
  files to a temp directory and then moving them all at once, which is
  complex and fragile).
- **Empty sections:** If a project has no dependencies (no package.json,
  Cargo.toml, etc.), `dependencies.json` should contain `{"manifests":[],"key_dependencies":[]}`.
  The view generator should render this as `(no package manifests detected)`
  — the same text as the current fallback.
- **Test fixture updates:** The existing test fixture at
  `tests/fixtures/indexer_project/` may need additional files to exercise
  the new structured output. Add a few config files and a test file to
  ensure all emitters produce non-empty output.
- **The `_budget_allocator` function stays.** It's still used by the view
  generator to distribute budget across sections. Only `_truncate_section`
  is removed. Update the test file name but keep the allocator tests.
- **Don't remove `compress_context` itself.** Only remove the specific
  call site in `_compress_synthesis_context` that applies `summarize_headings`
  to PROJECT_INDEX_CONTENT. The `compress_context` function and its strategies
  are used elsewhere and must remain.

Seeds Forward:
- Complete structured index is the foundation for V4 features: cross-project
  analysis, programmatic codebase queries, AI-driven architecture review
- The view generator pattern (structured data -> bounded human view) can be
  applied to other artifacts (MILESTONE_ARCHIVE.md, RUN_SUMMARY.json)
- With structured data, future rescans can produce a precise diff showing
  exactly what changed since the last scan (new files, removed files,
  size changes) — useful for drift detection
