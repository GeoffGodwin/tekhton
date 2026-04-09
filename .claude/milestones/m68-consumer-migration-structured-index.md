# Milestone 68: Consumer Migration to Structured Index
<!-- milestone-meta
id: "68"
status: "done"
-->

## Overview

M67 produces structured project data in `.claude/index/` but all consumers
still read the legacy PROJECT_INDEX.md markdown file. This milestone migrates
every consumer to read structured data directly, fixing multiple pre-existing
bugs in the process.

Three consumers read PROJECT_INDEX.md today:

1. **Intake agent** (`stages/intake.sh:97-98`) — Uses `_safe_read_file` with
   an 8KB cap, which silently **rejects the entire file** (returns empty string)
   for any project where the index exceeds 8KB. This means intake has been
   running blind on most brownfield projects since M10.

2. **Synthesis** (`lib/init_synthesize_helpers.sh:50-51`) — Loads via bare
   `cat`, then applies `compress_context "summarize_headings"` when over budget,
   which strips all non-heading lines — destroying the entire file inventory
   table, dependency details, and sampled content.

3. **Replan** (`lib/replan_brownfield.sh:39`) — Loads via bare `cat` with no
   size gate at all. For a 500KB PROJECT_INDEX.md on a large project, this
   injects the entire thing into the replan prompt, potentially blowing the
   context window.

Each consumer needs different data at different granularity levels. A shared
reader API lets each consumer request exactly what it needs from the structured
files.

Depends on M67 for the structured data layer.

## Scope

### 1. Structured Index Reader API

**New file:** `lib/index_reader.sh`

Provides functions that read from `.claude/index/` and return formatted content
suitable for prompt injection. All functions accept a project directory argument
and gracefully fall back to legacy PROJECT_INDEX.md parsing when structured
files don't exist (pre-M67 projects).

#### Core functions:

```bash
# read_index_meta — Returns metadata as key=value pairs
# Args: $1 = project directory
# Output: "project_name=foo\nfile_count=342\ntotal_lines=48291\n..."
read_index_meta()

# read_index_tree — Returns directory tree text
# Args: $1 = project directory, $2 = max_lines (optional, 0=unlimited)
# Output: Plain text tree (truncated to max_lines if specified)
read_index_tree()

# read_index_inventory — Returns file inventory as formatted text
# Args: $1 = project directory, $2 = max_records (optional, 0=unlimited)
#        $3 = filter (optional: "dir:src" or "size:large,huge")
# Output: Formatted table or record list
read_index_inventory()

# read_index_dependencies — Returns dependency summary
# Args: $1 = project directory
# Output: Formatted dependency text
read_index_dependencies()

# read_index_configs — Returns config file list
# Args: $1 = project directory
# Output: Formatted config table
read_index_configs()

# read_index_tests — Returns test infrastructure summary
# Args: $1 = project directory
# Output: Formatted test summary
read_index_tests()

# read_index_samples — Returns sampled file content
# Args: $1 = project directory, $2 = max_total_chars (optional)
# Output: Formatted sample blocks (markdown fenced)
read_index_samples()

# read_index_summary — Returns a bounded summary for prompt injection
# Args: $1 = project directory, $2 = max_chars (total budget)
# Output: Abbreviated project summary within budget
read_index_summary()
```

**`read_index_summary()` is the key function.** It assembles a prompt-ready
project summary within a caller-specified character budget. Internal allocation:

1. Always include: meta header (~200 chars), tree (first 100 lines), test
   summary (~500 chars)
2. Priority fill: dependencies, configs, top-50 inventory records by size
   (large/huge first), then samples with remaining budget
3. No truncation markers — content is selected, not truncated

This replaces the current pattern where consumers load the full file and then
apply lossy compression.

#### Legacy fallback:

When `.claude/index/meta.json` doesn't exist (pre-M67 project that hasn't
been re-crawled), all reader functions fall back to parsing PROJECT_INDEX.md
using section extraction:

```bash
read_index_meta() {
    local project_dir="$1"
    local meta_file="${project_dir}/.claude/index/meta.json"
    if [[ -f "$meta_file" ]]; then
        # Parse JSON
        ...
    elif [[ -f "${project_dir}/PROJECT_INDEX.md" ]]; then
        # Legacy: extract from HTML comments
        ...
    fi
}
```

This ensures backward compatibility for projects that haven't re-scanned.

### 2. Fix Intake Consumer (Issue #1 — CRITICAL)

**Files:** `stages/intake.sh`, `prompts/intake_scan.prompt.md`

**Current bug:** Lines 93-98 use `_safe_read_file` with `8192` byte cap.
`_safe_read_file` (prompts.sh:51-73) is a **rejection gate**, not a truncating
reader. If the file exceeds 8192 bytes, it returns an empty string and logs a
warning. The comment says "capped to 8KB" but the behavior is "skip entirely
if > 8KB". Any brownfield project with more than ~100 files produces an index
larger than 8KB, so intake has been running blind.

**Fix:** Replace the `_safe_read_file` call with `read_index_summary`:

```bash
# OLD (broken):
# INTAKE_PROJECT_INDEX=$(_safe_read_file "${PROJECT_DIR}/PROJECT_INDEX.md" "PROJECT_INDEX" 8192)

# NEW:
export INTAKE_PROJECT_INDEX=""
if [[ -d "${PROJECT_DIR}/.claude/index" ]] || [[ -f "${PROJECT_DIR}/PROJECT_INDEX.md" ]]; then
    INTAKE_PROJECT_INDEX=$(read_index_summary "$PROJECT_DIR" 8000)
fi
```

The intake agent gets an 8KB summary that includes metadata, tree overview,
test infrastructure, and the most important inventory records — instead of
either the full 120KB file or nothing at all.

Also fix the identical pattern in `run_intake_create` at intake.sh:238-239.

### 3. Fix Synthesis Consumer (Issue #2 — CRITICAL)

**Files:** `lib/init_synthesize_helpers.sh`

**Current bug:** `_assemble_synthesis_context` at line 50-51 loads via bare
`cat`. When the context exceeds the model's budget, `_compress_synthesis_context`
at line 145 calls `compress_context "$PROJECT_INDEX_CONTENT" "summarize_headings"`
which runs:

```bash
echo "$content" | grep -E '^#{1,3} ' || true
```

This keeps only markdown headings, destroying:
- The entire file inventory table (every `| path | lines | size |` row)
- All dependency details (only `## Key Dependencies` heading survives)
- All config details
- All sampled file content

The compressed result is nearly useless for synthesis — the agent gets headings
like `## File Inventory` with no actual inventory data.

**Fix:** Replace the `cat` load with `read_index_summary`, and update the
existence guard at line 42 to also accept structured data:

```bash
# OLD guard:
# if [[ ! -f "$index_file" ]]; then error "..."; return 1; fi

# NEW guard:
if [[ ! -f "$index_file" ]] && [[ ! -f "${project_dir}/.claude/index/meta.json" ]]; then
    error "PROJECT_INDEX.md not found at ${index_file}"
    error "Run 'tekhton --init' first to generate the project index."
    return 1
fi

# OLD load:
# PROJECT_INDEX_CONTENT=$(cat "$index_file")

# NEW load:
PROJECT_INDEX_CONTENT=$(read_index_summary "$project_dir" 60000)
```

The 60KB budget gives synthesis a rich but bounded view. The reader's internal
prioritization ensures the most valuable data (large files, key deps,
frameworks) is included first.

Also update `_compress_synthesis_context` to handle the new format:
- Remove the `compress_context "$PROJECT_INDEX_CONTENT" "summarize_headings"`
  call entirely — the reader already produces bounded output
- Keep the README, ARCHITECTURE.md, and git log compression steps as-is
  (they operate on different content)

### 4. Fix Replan Consumer (Issue #7)

**File:** `lib/replan_brownfield.sh`

**Current behavior:** `_generate_codebase_summary` at line 39 uses bare
`cat "$index_file"` when PROJECT_INDEX.md exists and is recent. For large
projects, this injects 120KB+ of raw markdown into the replan prompt with
zero budget awareness.

**Fix:** Replace `cat` with `read_index_summary`:

```bash
# OLD:
# cat "$index_file"

# NEW:
read_index_summary "$PROJECT_DIR" 40000
```

The 40KB budget is appropriate for replan context — the agent needs enough
to understand project structure but doesn't need every file listed.

Also keep the staleness check (lines 20-36) but adapt it to read the scan
commit from `meta.json` via `read_index_meta` instead of parsing HTML comments
from the markdown file.

### 5. Fix `_safe_read_file` Future Foot-Gun (Issue #8)

**File:** `lib/prompts.sh`

**Current risk:** `_safe_read_file` has a 1MB default cap (line 54). As
PROJECT_INDEX.md grows, it will silently reject the file when consumed by
other callers using the default cap. This is not a current bug but will
become one as structured data grows.

**Fix:** After M68, no consumer should be using `_safe_read_file` for
PROJECT_INDEX.md. Add a comment documenting this:

```bash
# NOTE: Do not use _safe_read_file for PROJECT_INDEX.md.
# Use read_index_summary() or read_index_*() from lib/index_reader.sh
# which provide bounded, structured access to project index data.
```

This is a documentation fix, not a code change. The function itself is correct
for its intended use (reading role files, design docs, etc.) — it's the
*misuse* on PROJECT_INDEX.md that was the bug.

### 6. Fix `_extract_scan_metadata` to Prefer Structured Data

**File:** `lib/rescan_helpers.sh`

`_extract_scan_metadata` at lines 143-150 parses HTML comments from
PROJECT_INDEX.md using grep+sed. After M67, the canonical source for this
data is `meta.json`.

**Fix:** Check for `meta.json` first, fall back to HTML comment parsing:

```bash
_extract_scan_metadata() {
    local index_file="$1"
    local field="$2"
    local project_dir
    project_dir=$(dirname "$index_file")
    local meta_file="${project_dir}/.claude/index/meta.json"

    # Prefer structured data
    if [[ -f "$meta_file" ]]; then
        local json_field
        # Map field names: "Scan-Commit" -> "scan_commit", "Last-Scan" -> "scan_date"
        case "$field" in
            Scan-Commit) json_field="scan_commit" ;;
            Last-Scan)   json_field="scan_date" ;;
            File-Count)  json_field="file_count" ;;
            Total-Lines) json_field="total_lines" ;;
            *) json_field="" ;;
        esac
        if [[ -n "$json_field" ]]; then
            # Extract without jq dependency — simple grep+sed on formatted JSON
            grep "\"${json_field}\"" "$meta_file" 2>/dev/null | \
                sed 's/.*: *"\?\([^",}]*\)"\?.*/\1/' | tr -d '[:space:]' || true
            return
        fi
    fi

    # Legacy fallback: parse HTML comments from markdown
    grep "<!-- ${field}:" "$index_file" 2>/dev/null | \
        sed "s/.*<!-- ${field}: *\(.*\) *-->.*/\1/" | \
        tr -d '[:space:]' || true
}
```

### 7. Fix `_extract_sampled_files` Latent Bug

**File:** `lib/rescan_helpers.sh`

**Current bug:** `_extract_sampled_files` at line 225 uses regex `^### \``
to find sampled file headings. But the crawler emits headings as `### filename`
(without backticks — see crawler_content.sh:72: `output+="### ${f}"`). The
regex pattern `^### \`` with backtick never matches, so `_extract_sampled_files`
always returns empty, meaning the rescan never detects when sampled files
have been modified.

**Fix:** After M67, sampled files are tracked in
`.claude/index/samples/manifest.json`. Rewrite `_extract_sampled_files` to
read from the manifest:

```bash
_extract_sampled_files() {
    local index_file="$1"
    local project_dir
    project_dir=$(dirname "$index_file")
    local manifest="${project_dir}/.claude/index/samples/manifest.json"

    if [[ -f "$manifest" ]]; then
        # Extract "original" field values from manifest JSON
        grep '"original"' "$manifest" 2>/dev/null | \
            sed 's/.*"original": *"\([^"]*\)".*/\1/' || true
        return
    fi

    # Legacy fallback (fixed regex — no backtick)
    grep '^### ' "$index_file" 2>/dev/null | \
        sed 's/^### //' | sed 's/`//g' || true
}
```

## Migration Impact

| Key | Default | Notes |
|-----|---------|-------|
| (none) | | No new config keys. Reader API respects existing `PROJECT_INDEX_BUDGET` from M67 |

**New source file:** `lib/index_reader.sh` — must be sourced in `tekhton.sh`
alongside `crawler.sh`. Add the source line after the crawler source:

```bash
source "${TEKHTON_HOME}/lib/index_reader.sh"
```

**Backward compatibility:** All reader functions fall back to legacy
PROJECT_INDEX.md parsing when `.claude/index/meta.json` doesn't exist. Projects
that haven't re-crawled since M67 continue to work.

## Acceptance Criteria

- `read_index_summary()` returns bounded project overview within caller's budget
- Intake agent receives project context for all project sizes (not empty for >8KB)
- Synthesis context uses structured reader instead of `cat` + lossy compression
- Replan context is budget-bounded via structured reader
- `_extract_scan_metadata` reads from `meta.json` when available
- `_extract_sampled_files` correctly identifies sampled files (manifest-based)
- All reader functions gracefully fall back for pre-M67 projects
- No consumer uses `_safe_read_file` for PROJECT_INDEX.md
- `summarize_headings` compression strategy is no longer applied to index data
- All existing tests pass

Tests:
- `read_index_meta` returns correct fields from `.claude/index/meta.json`
- `read_index_meta` falls back to HTML comment parsing for legacy projects
- `read_index_inventory` returns formatted records from JSONL
- `read_index_inventory` with filter returns only matching records
- `read_index_inventory` with max_records limits output correctly
- `read_index_summary` respects character budget (output <= budget)
- `read_index_summary` includes metadata, tree, tests in all budgets
- `read_index_summary` fills with deps and inventory when budget allows
- Intake receives non-empty project context for fixture project
- Intake receives non-empty project context for legacy (pre-M67) fixture
- Synthesis context is bounded without `summarize_headings` compression
- Replan context is bounded without raw `cat` injection
- `_extract_scan_metadata` reads "scan_commit" from meta.json
- `_extract_scan_metadata` falls back for legacy project
- `_extract_sampled_files` reads from samples/manifest.json
- `_extract_sampled_files` falls back for legacy project (fixed regex)

Watch For:
- **JSON parsing without jq:** Tekhton has no `jq` dependency. All JSON
  parsing uses grep+sed on formatted (pretty-printed) JSON. This is fragile
  but acceptable for the simple, controlled schemas we emit. The `_emit_*`
  functions in M67 MUST emit formatted JSON (one key per line) to make this
  parsing reliable. Never minify the JSON output.
- **Budget arithmetic in read_index_summary:** The function must track
  accumulated chars as it adds sections, stopping when the budget is reached.
  Use the same `used` + `remaining` pattern from `_crawl_sample_files`
  (crawler_content.sh:28-29).
- **JSONL streaming for inventory:** `read_index_inventory` should use
  `while IFS= read -r line` to process JSONL line by line, not load the
  entire file into a variable. For a 5,000-file project, the JSONL is ~300KB
  — manageable in memory but better streamed for consistency.
- **Fallback testing:** The legacy fallback paths must be tested explicitly.
  Create a test fixture that has PROJECT_INDEX.md but no `.claude/index/`
  directory. Every reader function should produce meaningful output from the
  legacy format.
- **Source ordering in tekhton.sh:** `lib/index_reader.sh` must be sourced
  AFTER `lib/crawler.sh` (it may reference `_CRAWL_EXCLUDE_DIRS` or other
  crawler globals). Place the source line immediately after the crawler
  source block.

Seeds Forward:
- M69 uses the reader API to generate the markdown view
- Structured reader enables future context-compiler integration (per-stage
  inventory slicing based on task relevance)
- `read_index_inventory` with filters enables targeted file discovery
  (e.g., "show me all large files in src/") for future interactive features
