# Milestone 88: Test Symbol Map — Indexer Extension for Stale-Reference Detection
<!-- milestone-meta
id: "88"
status: "pending"
-->

## Overview

The M20 test audit closes the loop on tests written or modified in the current
run — orphan detection fires when the *file* a test imports was deleted this run.
But it has a structural blind spot: a test file that nobody touches never gets
re-evaluated, and a deleted/renamed *symbol* (function, class) inside a still-present
module is invisible to file-level import analysis.

The canonical example is a migration test: `test_migrate_v2_to_v3.py` imports
`migrations.v2`, the module still exists on disk (migrations don't get deleted),
but the function `apply_migration()` it calls was refactored away three milestones
ago. `_detect_orphaned_tests` misses it because the file is not deleted and the
test wasn't touched this run.

This milestone adds a deterministic, zero-agent-cost mechanism to catch that class
of stale reference:

1. **Test symbol map** — extend `repo_map.py` with `--emit-test-map PATH`: walk
   test files, extract their *reference* tags (call targets, imports), write a
   JSON map of `{test_file: [referenced_symbol, ...]}`. The file is mtime-tracked
   and cached — zero cost on unchanged tests.

2. **Symbol-level orphan detection** — upgrade `_detect_orphaned_tests` to
   cross-reference each test file's symbol list (from `test_map.json`) against
   the existing `tags.json` definitions. Symbols that appear in no source file
   definition → candidate orphan finding, annotated `STALE-SYM`.

Both pieces are purely deterministic (no agent turns); the LLM audit in M20 then
gets pre-verified `STALE-SYM` entries injected into its context, giving it
better signal with zero extra cost.

## Design Decisions

### 1. Separate test_map.json from tags.json

Test files reference the same tree-sitter reference tags already captured during
normal indexing. Keeping a separate file avoids polluting the source definition
map (which drives repo map ranking) with test-only references, and lets the map
be invalidated/regenerated independently of source tags.

### 2. Reference tags, not import paths

Import paths (`from migrations.v2 import apply_migration`) contain module-path
strings that don't match the symbol names in `tags.json` (`apply_migration`).
Tree-sitter's `call_expression` and `import_statement` reference nodes already
give us the bare symbol names. Cross-referencing name-to-name is O(n) with a
simple grep or set intersection.

### 3. Soft orphan signal, not hard block

A symbol present in `test_map.json` but absent from `tags.json` is a *candidate*
— it could be a standard library call, an external package, or a locally-defined
helper not captured by tree-sitter. The finding is emitted as `STALE-SYM` and
fed to the existing M20 LLM audit as pre-computed context. The LLM makes the
final call; the shell narrows the search space.

### 4. Gated by REPO_MAP_ENABLED

The test symbol map requires the Python indexer. When `REPO_MAP_ENABLED=false`,
`_detect_orphaned_tests` silently skips symbol-level detection and falls back to
the existing file-level check. No behavior change for projects without the indexer.

### 5. Filter common noise symbols

High-frequency generic names (`__init__`, `setUp`, `tearDown`, `self`, `cls`,
`test`, `mock`, `patch`) are excluded from the symbol cross-reference. They
appear in every test file and match nothing meaningful in source tags.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Python files modified | 1 | `tools/repo_map.py` — add `--emit-test-map` |
| Shell files modified | 2 | `lib/test_audit.sh`, `lib/indexer.sh` |
| Config modified | 1 | `lib/config_defaults.sh` — new key |
| Python tests added | 1 | `tools/tests/test_repo_map.py` — test map tests |
| Shell tests added | 1 | `tests/test_audit_symbol_orphan.sh` |

## Implementation Plan

### Step 1 — tools/repo_map.py: add --emit-test-map

Add a new CLI flag `--emit-test-map PATH`. When set:

1. After the normal file walk, perform a second pass over test files only
   (matched by the same patterns as `_discover_all_test_files` in `test_audit.sh`:
   `tests?/`, `__tests__/`, `_test.`, `.test.`, `.spec.`, `_spec.`, `test_`).
2. For each test file, call `_extract_tags()` (reuses cache — free if already
   warm). Collect the `references` list from the returned tags.
3. Filter reference names through a noise-symbol exclusion list:
   `NOISE_SYMBOLS = {"__init__", "setUp", "tearDown", "self", "cls", "test",
   "mock", "patch", "Mock", "MagicMock", "call", "ANY", "assert", "assertTrue",
   "assertEqual", "expect", "describe", "it", "beforeEach", "afterEach"}`.
4. Build output dict: `{relative_path: [name, ...]}` — only files with at least
   one non-noise reference are included.
5. Write atomically to PATH (write to `.tmp`, `os.replace`).

The flag does not affect normal stdout output — it is additive.

```python
if args.emit_test_map:
    test_map = _build_test_symbol_map(root, files, cache)
    _write_test_map(test_map, args.emit_test_map)
```

New function `_build_test_symbol_map(root, all_files, cache)`:
- Filters `all_files` to test files by path pattern
- Calls `_extract_tags` for each, collects `references`
- Returns `{filepath: [name, ...]}` after noise filtering

New function `_write_test_map(test_map, path)`:
- Writes JSON atomically
- Includes metadata: `{"version": 1, "generated": ISO_TIMESTAMP, "files": {...}}`

### Step 2 — lib/indexer.sh: emit_test_symbol_map()

Add `emit_test_symbol_map()` function:

```bash
emit_test_symbol_map() {
    if [[ "${TEST_AUDIT_SYMBOL_MAP_ENABLED:-true}" != "true" ]]; then
        return 0
    fi
    if [[ "${REPO_MAP_ENABLED:-false}" != "true" ]]; then
        return 0
    fi
    if [[ "$INDEXER_AVAILABLE" != "true" ]]; then
        return 0
    fi

    local venv_python cache_dir test_map_file
    venv_python=$(_indexer_find_venv_python) || return 0
    cache_dir=$(_indexer_resolve_cache_dir)
    test_map_file="${cache_dir}/test_map.json"

    "$venv_python" "${TEKHTON_HOME}/tools/repo_map.py" \
        --root "$PROJECT_DIR" \
        --cache-dir "$cache_dir" \
        --languages "${REPO_MAP_LANGUAGES:-auto}" \
        --emit-test-map "$test_map_file" \
        > /dev/null 2>&1 || {
        warn "[indexer] Failed to emit test symbol map (non-fatal)."
        return 0
    }

    log "[indexer] Test symbol map written to ${test_map_file}."
}
```

Call `emit_test_symbol_map` from `run_repo_map()` after the main invocation,
and from `warm_index_cache()` in `lib/indexer_history.sh` after cache warming.

Export `TEST_SYMBOL_MAP_FILE` so `test_audit.sh` can locate it without
duplicating the cache-dir resolution logic.

### Step 3 — lib/test_audit.sh: symbol-level orphan detection

Add `_detect_stale_symbol_refs()` — called from `_detect_orphaned_tests` when
the symbol map is available:

```bash
_detect_stale_symbol_refs() {
    local test_map_file="${TEST_SYMBOL_MAP_FILE:-}"
    local tags_file  # resolved from cache dir

    [[ -z "$test_map_file" ]] && return
    [[ ! -f "$test_map_file" ]] && return
    [[ -z "${_AUDIT_TEST_FILES:-}" ]] && return

    # Resolve tags.json (sibling to test_map.json)
    tags_file="$(dirname "$test_map_file")/tags.json"
    [[ ! -f "$tags_file" ]] && return

    while IFS= read -r test_file; do
        [[ -z "$test_file" ]] && continue

        # Extract referenced symbols for this file from test_map.json
        local symbols
        symbols=$(python3 -c "
import json, sys
data = json.load(open('${test_map_file}'))
files = data.get('files', data)
syms = files.get('${test_file}', [])
print('\n'.join(syms))
" 2>/dev/null || true)

        [[ -z "$symbols" ]] && continue

        while IFS= read -r sym; do
            [[ -z "$sym" ]] && continue
            # Check if sym appears as a definition name in tags.json
            if ! grep -qF "\"name\": \"${sym}\"" "$tags_file" 2>/dev/null; then
                _AUDIT_ORPHAN_FINDINGS="${_AUDIT_ORPHAN_FINDINGS}
STALE-SYM: ${test_file} references '${sym}' not found in any source definition"
            fi
        done <<< "$symbols"
    done <<< "$_AUDIT_TEST_FILES"
}
```

Call `_detect_stale_symbol_refs` at the end of `_detect_orphaned_tests` when
`TEST_AUDIT_SYMBOL_MAP_ENABLED=true`.

Update `_AUDIT_ORPHAN_FINDINGS` string to include `STALE-SYM` prefix so the
M20 LLM audit prompt sees it as a distinct pre-verified signal.

### Step 4 — lib/config_defaults.sh

Add one new key adjacent to the existing `TEST_AUDIT_*` block:

```bash
: "${TEST_AUDIT_SYMBOL_MAP_ENABLED:=true}"
```

Add to the validation block in `lib/config.sh` (boolean check alongside
`TEST_AUDIT_ENABLED`).

### Step 5 — Python tests

Extend `tools/tests/test_repo_map.py` with a `TestEmitTestMap` class:

- `test_emit_test_map_creates_file` — run with `--emit-test-map`, verify JSON
  file is created
- `test_emit_test_map_captures_references` — fixture test file calling a known
  function; assert function name in map output
- `test_emit_test_map_excludes_noise` — fixture test file using `setUp`/`tearDown`;
  assert those names excluded
- `test_emit_test_map_only_test_files` — source file in same fixture; assert it
  is NOT in the map output

### Step 6 — Shell tests

Create `tests/test_audit_symbol_orphan.sh`:

- `test_stale_sym_detected` — construct a fake `test_map.json` referencing `OldFunc`
  and a `tags.json` where `OldFunc` is absent; run `_detect_stale_symbol_refs`;
  assert `_AUDIT_ORPHAN_FINDINGS` contains `STALE-SYM`
- `test_live_sym_not_flagged` — same setup but `NewFunc` present in `tags.json`;
  assert no `STALE-SYM` finding
- `test_skips_when_no_map` — no `test_map.json` present; assert no finding
  and no error
- `test_skips_when_map_disabled` — `TEST_AUDIT_SYMBOL_MAP_ENABLED=false`; assert
  `_detect_stale_symbol_refs` returns without populating findings

## Files Touched

### Added
- `tests/test_audit_symbol_orphan.sh` — shell tests for symbol-level detection

### Modified
- `tools/repo_map.py` — `--emit-test-map PATH` flag + `_build_test_symbol_map()` +
  `_write_test_map()`
- `lib/indexer.sh` — `emit_test_symbol_map()` + call sites after warm/generate
- `lib/test_audit.sh` — `_detect_stale_symbol_refs()` called from
  `_detect_orphaned_tests`
- `lib/config_defaults.sh` — `TEST_AUDIT_SYMBOL_MAP_ENABLED=true`
- `lib/config.sh` — boolean validation for new key
- `tools/tests/test_repo_map.py` — `TestEmitTestMap` class

## Acceptance Criteria

- [ ] `repo_map.py --emit-test-map PATH` creates a valid JSON file at PATH
- [ ] The JSON contains entries only for test files (no source files)
- [ ] Each entry is a list of referenced symbol names, noise symbols excluded
- [ ] `emit_test_symbol_map()` runs without error when `REPO_MAP_ENABLED=true`
  and the indexer is available
- [ ] `emit_test_symbol_map()` exits 0 (non-fatal) when indexer is unavailable
- [ ] `TEST_SYMBOL_MAP_FILE` is exported so test_audit.sh can locate the map
- [ ] `_detect_stale_symbol_refs` flags a test referencing a symbol absent from
  `tags.json` with a `STALE-SYM:` prefixed finding
- [ ] `_detect_stale_symbol_refs` does NOT flag a test referencing a symbol
  present in `tags.json`
- [ ] `_detect_stale_symbol_refs` is silently skipped when
  `TEST_AUDIT_SYMBOL_MAP_ENABLED=false`
- [ ] `_detect_stale_symbol_refs` is silently skipped when `test_map.json`
  does not exist (REPO_MAP_ENABLED=false projects)
- [ ] **Behavioral:** In the Tekhton test fixture, `_detect_stale_symbol_refs`
  produces zero false positives against current source tags
- [ ] `python -m pytest tools/tests/test_repo_map.py -k TestEmitTestMap` passes
- [ ] `bash tests/test_audit_symbol_orphan.sh` passes
- [ ] `bash tests/run_tests.sh` passes (no regressions)
- [ ] `shellcheck lib/indexer.sh lib/test_audit.sh` reports zero warnings
- [ ] `python -m pytest tools/tests/` passes (no Python regressions)
- [ ] No change in behavior when `REPO_MAP_ENABLED=false`

## Watch For

- The `tags.json` grep for `"name": "sym"` is intentionally simple but prone to
  false negatives on symbols containing regex-special characters. Symbols like
  `__init__` are already filtered by noise exclusion; the remaining set is
  identifiers that are safe for substring grep. If edge cases appear, switch to
  `python3 -c "import json; ..."` for the source-side check too.
- False positives are the key risk. A referenced symbol that is genuinely
  external (stdlib, third-party package) will appear in the test map but not in
  `tags.json`. The noise filter covers the most common cases; the LLM audit has
  context to dismiss the rest. Prefer false positives (LLM dismisses) over false
  negatives (stale test survives).
- `_detect_stale_symbol_refs` calls `python3` directly for JSON parsing. This
  assumes Python 3 is available in `$PATH` when the indexer is enabled (safe
  assumption: the indexer venv requires Python 3.8+). Use the venv python for
  the JSON read to avoid any path mismatch.

## Seeds Forward

- M89 (Rolling Test Audit Sampler) consumes `test_map.json` to identify which
  test files are candidates for freshness sampling — files whose symbol sets have
  changed since last audit become priority candidates.
- The test symbol map is the foundation for a future "dead symbol" detector:
  symbols defined in source but referenced nowhere (not even in tests) are strong
  candidates for removal.
- The noise exclusion list is project-agnostic today. A future enhancement lets
  `pipeline.conf` extend it with project-specific utility names.
