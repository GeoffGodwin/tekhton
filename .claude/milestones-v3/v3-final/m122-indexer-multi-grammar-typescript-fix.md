# M122 - Indexer Multi-Grammar Package Support + Diagnostic Plumbing (TypeScript Fix)

<!-- milestone-meta
id: "122"
status: "done"
-->

## Overview

Issue #181 reports that the indexer silently produces no repo map on
projects where most/all source files are `.ts` or `.tsx`. The only log
line the user sees is:

```
[!] [indexer] repo_map.py failed — falling back to no repo map.
```

The pipeline then proceeds without a repo map, and every downstream
stage that expects `REPO_MAP_CONTENT` degrades to v2 fallback behavior.
TS/TSX projects are a large share of real-world Tekhton targets, so
this bug has been silently hollowing out the indexer's value there.

Two compounding defects produce the silent failure:

1. **Multi-grammar packages aren't recognized.** `tools/tree_sitter_languages.py:63-81`
   calls `getattr(mod, "language")` / `getattr(mod, "LANGUAGE")` on each
   grammar package, but `tree_sitter_typescript` bundles two grammars
   and exposes them as `language_typescript()` and `language_tsx()` —
   no generic `language` export. `get_language()` therefore returns
   `None` for every `.ts`/`.tsx` file, `_extract_tags` in
   `tools/repo_map.py:160-162` returns `None`, `all_tags` stays empty,
   and `repo_map.py` exits 2 with `Warning: no files could be parsed`.
   The `lang_name` already unpacked from `_EXT_TO_LANG` is never used
   in the lookup. Verified on the installed package:

   ```
   $ python -c "import tree_sitter_typescript as m; print([a for a in dir(m) if not a.startswith('_')])"
   ['language_tsx', 'language_typescript']
   ```

2. **The real error never reaches the user.** `lib/indexer.sh:193-201`
   parses stats from `$stderr_output` and then calls
   `rm -f "$stderr_output"`. The fatal-exit warning on line 204 fires
   *after* the file is gone, so the actual diagnostic
   (`Warning: no files could be parsed`) is lost. Users see only the
   generic "falling back" line and cannot self-diagnose.

M122 is the narrow, atomic fix for #181: make the loader multi-grammar
aware, and make the fallback diagnostic actually surface the Python
tool's last words. M123 handles the defence-in-depth work (per-grammar
load audit, coverage tests, and regression prevention for future
grammar packages that adopt the same multi-export convention).

## Design

### Goal 1 — Factory-function probe in `get_language()`

Change `tools/tree_sitter_languages.py:63-71` to try a grammar-specific
factory first, using the `lang_name` field already unpacked from
`_EXT_TO_LANG`. This handles the multi-grammar convention
(`tree_sitter_typescript.language_typescript()`, `...language_tsx()`)
without regressing single-grammar packages that only export `language`
or `LANGUAGE`.

Current code:

```python
mod = importlib.import_module(module_name)
lang_fn = getattr(mod, "language", None)
if lang_fn is None:
    lang_fn = getattr(mod, "LANGUAGE", None)
if lang_fn is None:
    return None
```

New code:

```python
mod = importlib.import_module(module_name)
# Multi-grammar packages (e.g. tree_sitter_typescript) expose grammar-
# specific factories like language_typescript() / language_tsx(). Probe
# the specific name first, then fall back to the single-grammar
# conventions.
lang_fn = getattr(mod, f"language_{lang_name}", None)
if lang_fn is None:
    lang_fn = getattr(mod, "language", None)
if lang_fn is None:
    lang_fn = getattr(mod, "LANGUAGE", None)
if lang_fn is None:
    return None
```

No change to the rest of the function: the PyCapsule → `tree_sitter.Language`
wrap, caching of the resolved `Language` object, and the `(ImportError,
OSError, AttributeError)` catch-all all continue to work unchanged. The
cache key (`f"{module_name}.{lang_name}"`) already disambiguates
`typescript` vs `tsx` within the same module, so two separate
`Language` objects are cached correctly.

### Goal 2 — Preserve stderr until the warning has fired

In `lib/indexer.sh`, two changes inside `run_repo_map` (~lines 167-207):

**Change A** — move the `rm -f "$stderr_output"` out of the stats-parse
block. Delete it from line 200 and place it at the end of the function,
after both the fatal-exit path and the partial-exit path have had a
chance to inspect it.

**Change B** — on fatal exit, append the tail of stderr to the warning
so the user sees the actionable Python-side error:

```bash
if [[ "$exit_code" -eq 2 ]] || [[ -z "$REPO_MAP_CONTENT" ]]; then
    warn "[indexer] repo_map.py failed — falling back to no repo map."
    if [[ -s "$stderr_output" ]]; then
        # Surface the last few lines of Python stderr so users can
        # self-diagnose (missing grammars, parse errors, etc.).
        local stderr_tail
        stderr_tail=$(tail -n 5 "$stderr_output" 2>/dev/null | \
            sed 's/^/[indexer]   /')
        if [[ -n "$stderr_tail" ]]; then
            warn "[indexer] Last lines of repo_map.py stderr:"
            while IFS= read -r _line; do
                warn "$_line"
            done <<< "$stderr_tail"
        fi
    fi
    rm -f "$stderr_output" 2>/dev/null || true
    REPO_MAP_CONTENT=""
    return 1
fi

# Partial exit / success path also cleans up.
if [[ "$exit_code" -eq 1 ]]; then
    log "[indexer] Partial repo map generated (some files could not be parsed)."
fi
rm -f "$stderr_output" 2>/dev/null || true
```

Keep the existing stats-parse (`grep -E '^\{' "$stderr_output"`) at its
current location — it already reads the file before these exit
branches. Just remove the inner `rm -f` and rely on the single
end-of-function cleanup.

### Goal 3 — Unit tests: TypeScript / TSX grammar loading

Extend `tools/tests/test_tree_sitter_languages.py` with:

- `test_get_language_typescript_returns_object` — calls
  `get_language(".ts")` and asserts the result is a non-None object
  with the `tree_sitter.Language` attribute path expected by
  `tree_sitter.Parser(lang)`. Skip with `pytest.importorskip` if
  `tree_sitter_typescript` isn't installed (keeps the test suite
  green in minimal environments).
- `test_get_language_tsx_returns_object` — same for `.tsx`, asserting
  the returned object is *not* the same cached instance as the `.ts`
  one (different factories → different `Language` objects).
- `test_get_language_typescript_tsx_are_distinct` — explicit assertion
  that `get_language(".ts") is not get_language(".tsx")`.
- `test_get_parser_typescript_parses_simple_source` — acquire the
  parser, feed it a trivial `const x: number = 1;` snippet, assert the
  resulting tree's root node has no ERROR node at the top level.

All four tests gate on `importorskip("tree_sitter_typescript")` so the
default `tools/tests/` run still succeeds on machines without the TS
grammar installed.

### Goal 4 — Fixture coverage: TS/TSX files

`tests/fixtures/indexer_project/` today contains only `.py`, `.js`, and
`.sh` files — a TS regression would not be caught by any integration
test. Add two small files:

- `tests/fixtures/indexer_project/web/client.ts` — a minimal TypeScript
  module with an exported function (`export function fetchUser(id:
  string): Promise<User>`) and a simple `interface User`. Enough AST
  structure that `_walk_tree` produces at least one definition and one
  reference.
- `tests/fixtures/indexer_project/web/component.tsx` — a minimal React
  component with a typed prop, enough to exercise the TSX parser
  independently from the plain-TS parser.

Then add one integration test in `tools/tests/test_extract_tags_integration.py`:

- `test_extract_tags_typescript_file` — runs `_extract_tags` on
  `web/client.ts` against the fixture project, asserts the returned
  `tags` dict has at least one definition with name `fetchUser`. Skip
  with `importorskip` if `tree_sitter_typescript` is missing.
- `test_extract_tags_tsx_file` — same for `web/component.tsx`, asserting
  the component name appears as a definition.

The existing `test_repo_map.py` tests that enumerate all fixture files
will pick up the new `.ts`/`.tsx` files automatically — no list edits
needed.

### Goal 5 — End-to-end smoke: TS-only project doesn't silently fail

One new bash-level test in `tests/test_indexer_typescript_smoke.sh`:

1. Create a temp directory with three `.ts` files and a `.gitignore`
   (no other supported extensions).
2. `git init` + `git add` so `git ls-files` has something to emit.
3. Source `lib/indexer.sh` with a stub `PROJECT_DIR` pointing at the
   temp dir, and with the test venv's `tree_sitter_typescript` on
   path.
4. Invoke `run_repo_map "some task" 2048 false`.
5. Assert exit code 0, `REPO_MAP_CONTENT` non-empty, and at least one
   `## web/...` heading in the output.
6. Negative path: replace the `get_language` call path with a
   deliberately-broken grammar (e.g. monkey-patch `_EXT_TO_LANG` in a
   subprocess to point `.ts` at a non-existent module). Assert that
   `run_repo_map` returns non-zero **and** that the warning includes
   the `[indexer] Last lines of repo_map.py stderr:` block from Goal 2.

Gate the whole test on `command -v python` plus availability of
`tree_sitter_typescript` in the indexer venv; skip cleanly (exit 0,
print SKIP line) if the grammar isn't present.

### Goal 6 — Register new tests

- `tools/tests/test_tree_sitter_languages.py` and
  `tools/tests/test_extract_tags_integration.py` are already picked up
  by pytest discovery; no registration needed.
- `tests/test_indexer_typescript_smoke.sh` must be added to
  `tests/run_tests.sh`.

## Files Modified

| File | Change |
|------|--------|
| `tools/tree_sitter_languages.py` | In `get_language()`, probe `language_<lang_name>` before falling back to `language` / `LANGUAGE`. |
| `lib/indexer.sh` | In `run_repo_map()`, move `rm -f "$stderr_output"` out of the stats block to a single end-of-function cleanup; on fatal exit, emit a tail-of-stderr warning before cleanup. |
| `tools/tests/test_tree_sitter_languages.py` | Add four TS/TSX loader tests gated on `importorskip("tree_sitter_typescript")`. |
| `tools/tests/test_extract_tags_integration.py` | Add `_extract_tags` tests for the new `.ts` and `.tsx` fixtures. |
| `tests/fixtures/indexer_project/web/client.ts` | **New file.** Minimal TS module with an exported function and an interface. |
| `tests/fixtures/indexer_project/web/component.tsx` | **New file.** Minimal TSX React component with a typed prop. |
| `tests/test_indexer_typescript_smoke.sh` | **New file.** End-to-end smoke test for a TS-only project + negative path asserting the stderr-tail warning is visible. |
| `tests/run_tests.sh` | Register the new smoke test. |

## Acceptance Criteria

- [ ] `get_language(".ts")` and `get_language(".tsx")` return non-None
      `tree_sitter.Language` objects when `tree_sitter_typescript` is
      installed. Prior behavior (returning `None` on missing grammar)
      is preserved when the module is absent.
- [ ] `get_language(".ts") is not get_language(".tsx")` — distinct
      cached `Language` objects, so a `.ts` file and a `.tsx` file
      produce independently-parsed ASTs.
- [ ] All other declared extensions (`.py`, `.js`, `.go`, `.rs`,
      `.java`, `.c`, `.cpp`, `.rb`, `.sh`, `.dart`, `.swift`, `.kt`,
      `.cs`) continue to load via their existing `language()` /
      `LANGUAGE` fallbacks. Verified by a parametrized "all grammars
      that import cleanly return a Language" test.
- [ ] Running `tekhton` on a TS-only project (three+ `.ts` files, no
      other supported languages) produces a non-empty repo map on
      stdout via `REPO_MAP_CONTENT`, exits 0 from `run_repo_map`, and
      does not emit the "falling back to no repo map" warning.
- [ ] When `run_repo_map` encounters a fatal exit (exit 2 or empty
      content), the warning block includes a `[indexer] Last lines of
      repo_map.py stderr:` section with the Python tool's actual
      diagnostic output. Hand-test: point `REPO_MAP_LANGUAGES` at a
      non-existent language, rerun, confirm the new block appears with
      the `Warning: no files could be parsed` line.
- [ ] `$stderr_output` is cleaned up exactly once, at the end of
      `run_repo_map`, regardless of which branch (fatal / partial /
      success) was taken. No stale files accumulate under `/tmp`.
- [ ] `tools/tests/test_tree_sitter_languages.py` passes all new TS/TSX
      cases when `tree_sitter_typescript` is installed. Cases
      `pytest.skip` cleanly when it isn't.
- [ ] `tools/tests/test_extract_tags_integration.py` passes the new
      `.ts` and `.tsx` fixture tests, with at least one definition
      extracted from each file.
- [ ] `tests/test_indexer_typescript_smoke.sh` passes both the
      positive path (repo map generated) and the negative path
      (stderr-tail block visible on failure). Registered in
      `tests/run_tests.sh` and picked up by the runner.
- [ ] Shellcheck clean for `lib/indexer.sh` and the new smoke test.
- [ ] No existing tests need edits to continue passing.

## Non-Goals

- Auditing every installed grammar package at startup, or refusing to
  start when one is broken. That's M123.
- Adding fixture files for every extension in `_EXT_TO_LANG`. M122
  adds only `.ts` and `.tsx` — the two extensions whose regression is
  documented in issue #181. Broader fixture coverage is M123.
- Changing the shape of `_EXT_TO_LANG` (e.g. to a dataclass or to
  include per-package import hints). The two-tuple layout works once
  the loader knows to use the second field.
- Rewriting `_walk_tree` to handle TypeScript-specific AST node types
  (`type_alias_declaration`, `interface_declaration`, etc.) beyond what
  the existing definition / reference rules already pick up. The
  existing `class_declaration`, `function_declaration`, and
  `arrow_function` handlers already produce useful tags for the common
  TS idioms; specialized TS-only extraction is a separate concern if
  it ever proves necessary.
- Changing the "falling back to no repo map" wording or the severity
  level (`warn`). M122 only augments the message with the stderr tail.
