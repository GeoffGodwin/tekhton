# M123 - Indexer Grammar Coverage Audit & Silent-Failure Prevention

<!-- milestone-meta
id: "123"
status: "pending"
-->

## Overview

M122 fixes the specific TypeScript bug in issue #181: the loader learns
to call `language_typescript()` / `language_tsx()`, and the indexer
fallback warning stops eating the Python tool's stderr. But the
underlying bug class is broader — it's a *silent-failure* class:

- `tools/tree_sitter_languages.py:get_language()` catches
  `(ImportError, OSError, AttributeError)` and returns `None`. There's
  no distinction between "grammar package is not installed" (expected,
  benign), "grammar package's API doesn't match the loader's
  assumptions" (the #181 bug), and "grammar is broken in some other
  way" (unknown, unobserved).
- `_extract_tags` in `tools/repo_map.py:160-162` silently drops any
  file whose parser is `None`, and the run-level aggregation only
  raises its voice when **every** file failed (`if not all_tags:`).
  Single-language projects happen to produce the loud "no files could
  be parsed" signal; mixed-language projects with one broken grammar
  just quietly lose fidelity.
- No test in the repo exercises all declared extensions in
  `_EXT_TO_LANG`. A future grammar package that adopts the multi-export
  convention (or any other API drift) will reproduce #181 exactly.

M123 is the defence-in-depth pass. Goal: the *next* grammar package
that doesn't fit our loader's assumptions surfaces loudly at install /
test / startup time — not silently at repo-map time on an end user's
project.

M123 depends on M122 semantically: the audit in Goal 1 would light up
`.ts` / `.tsx` in red if M122 hasn't landed yet. Land M122 first, then
M123 flips the audit from "shiny new diagnostic that documents an
existing bug" to "regression gate against future bugs of the same
shape".

## Design

### Goal 1 — Grammar audit helper in `tree_sitter_languages.py`

Add a new public function in `tools/tree_sitter_languages.py`:

```python
def audit_grammars() -> dict[str, dict[str, object]]:
    """Probe every (module, lang_name) pair in _EXT_TO_LANG.

    Returns a dict keyed by extension with:
      - "module": module name attempted
      - "lang_name": language name attempted
      - "module_importable": bool
      - "language_loaded": bool
      - "error": str | None  (class + message if load failed)

    Intended for startup diagnostics, not for hot paths. Does not raise.
    """
```

Implementation: iterate `_EXT_TO_LANG.items()`, try `importlib.import_module`,
then try the same three-way probe as `get_language` (factory first,
then `language`, then `LANGUAGE`). Capture failure reasons with
`type(e).__name__: str(e)` so the downstream reporter can distinguish
"module missing" (benign, grammar just not installed) from "module
imported but no language factory found" (the M122-class bug).

Unit-test the helper in `tools/tests/test_tree_sitter_languages.py`:

- `test_audit_grammars_returns_entry_per_extension` — asserts the
  returned dict has exactly `len(_EXT_TO_LANG)` keys.
- `test_audit_grammars_marks_missing_module_cleanly` — monkey-patch
  `_EXT_TO_LANG` with a fake extension pointing at a non-existent
  module, assert `module_importable=False` and `error` contains
  `ImportError` or `ModuleNotFoundError`.
- `test_audit_grammars_marks_bad_api_cleanly` — inject a fake module
  (via `sys.modules`) with no `language*` exports, assert
  `module_importable=True`, `language_loaded=False`, and `error`
  mentions `AttributeError` or equivalent.
- `test_audit_grammars_all_installed_grammars_load` — for every
  extension where `module_importable` is true, assert `language_loaded`
  is also true. This is the regression gate that catches future
  multi-grammar packages.

### Goal 2 — CLI surface: `repo_map.py --audit-grammars`

Add a new flag to `tools/repo_map.py`:

```
--audit-grammars     Print grammar load status as JSON to stdout and exit 0.
                     Does not walk the project. Intended for diagnostics.
```

In `main()`, when `args.audit_grammars` is set, call `audit_grammars()`,
dump the result as JSON to stdout, and return 0. No side effects, no
cache touched, no project walk. This is the machine-readable surface
for shell-level consumers.

### Goal 3 — Shell surface: `check_indexer_available` runs the audit

Extend `lib/indexer.sh:check_indexer_available` (~line 69) so that
*after* the `tree_sitter` / `networkx` availability checks pass, it
runs `python repo_map.py --audit-grammars`, parses the JSON, and:

- At verbose log level, emits a one-line summary
  (`[indexer] Grammars: 14/18 loaded (4 modules missing)`).
- At warn level, emits one line per extension whose
  `module_importable=True` but `language_loaded=False` — this is the
  "API mismatch" class that #181 belongs to, and it should never be
  silent. Message format:

  ```
  [indexer] Grammar API mismatch: .ts ({module}) imported but no language factory found ({error}). Run 'tekhton --setup-indexer' to reinstall, or report this as a bug.
  ```

- At verbose log level, emits one line per extension whose module is
  missing. These are benign (grammar isn't installed, project
  presumably doesn't need it), so they stay at verbose.

The audit adds one additional subprocess call at startup (~50ms cold).
Gate it behind a new config key `INDEXER_STARTUP_AUDIT` (default:
`true`) for users who want to skip it. The audit's cost amortizes over
the whole run and catches the #181-class bug before the user sees a
single repo-map-failed warning.

Add the new key to `lib/config_defaults.sh` and document it in the
template table in `CLAUDE.md`.

### Goal 4 — Fixture coverage: at least one file per commonly-installed grammar

Today `tests/fixtures/indexer_project/` has `.py`, `.js`, and `.sh`.
M122 adds `.ts` and `.tsx`. M123 expands this to cover the
commonly-installed grammars so the integration tests catch any future
API drift:

- `tests/fixtures/indexer_project/services/server.go` — small Go file
  with an exported function.
- `tests/fixtures/indexer_project/services/handler.rs` — small Rust
  file with a struct and an impl block.
- `tests/fixtures/indexer_project/services/Worker.java` — small Java
  file with a class and a method.
- `tests/fixtures/indexer_project/native/engine.cpp` — small C++ file
  with a class.
- `tests/fixtures/indexer_project/scripts/helper.rb` — small Ruby
  file.

Do *not* add `.swift` / `.kt` / `.dart` / `.cs` fixtures — those
grammars are more fragile across platforms and CI environments, and
M122's coverage proves the multi-grammar fix works; the broader audit
(Goal 1) is enough regression protection for those.

Extend `tools/tests/test_extract_tags_integration.py` with a
parametrized test that iterates every fixture file and asserts
`_extract_tags` returns non-None when the corresponding grammar module
is importable (`pytest.importorskip` per file). This is one small
parametrized function, not one test per extension.

### Goal 5 — Bash-level regression test for the audit

New file `tests/test_indexer_grammar_audit.sh`:

1. Invoke `python tools/repo_map.py --audit-grammars` via the venv
   Python.
2. Parse the JSON with `jq` (gate the whole test on `command -v jq`).
3. Assert every extension in `_EXT_TO_LANG` has an audit entry.
4. Assert that for extensions where `module_importable` is true,
   `language_loaded` is also true. A failure here means a newly-added
   grammar has a novel API convention and needs a loader update.
5. Register in `tests/run_tests.sh`.

This test is the CI-level regression gate. If a future grammar
package's release changes its API, this test fails loudly with the
offending extension + error message, instead of users seeing silent
no-repo-map behavior weeks later.

### Goal 6 — Documentation

Update `CLAUDE.md` template-variables table to include
`INDEXER_STARTUP_AUDIT`. Add a short note in the indexer docs
(`docs/` — whichever page currently describes `--setup-indexer`)
explaining that a grammar API mismatch will now surface at startup
with an actionable warning, and pointing users at
`--audit-grammars` for manual diagnosis.

## Files Modified

| File | Change |
|------|--------|
| `tools/tree_sitter_languages.py` | Add `audit_grammars()` public function. |
| `tools/repo_map.py` | Add `--audit-grammars` flag that prints JSON and exits 0. |
| `lib/indexer.sh` | In `check_indexer_available`, run the audit after tree-sitter/networkx checks. Warn on API-mismatch extensions, log verbose on missing-module extensions. |
| `lib/config_defaults.sh` | Add `INDEXER_STARTUP_AUDIT` default (`true`). |
| `CLAUDE.md` | Document `INDEXER_STARTUP_AUDIT` in the template-variables table. |
| `tools/tests/test_tree_sitter_languages.py` | Add four `audit_grammars` unit tests. |
| `tools/tests/test_extract_tags_integration.py` | Add parametrized fixture-file test gated per-grammar. |
| `tests/fixtures/indexer_project/services/server.go` | **New file.** Minimal Go fixture. |
| `tests/fixtures/indexer_project/services/handler.rs` | **New file.** Minimal Rust fixture. |
| `tests/fixtures/indexer_project/services/Worker.java` | **New file.** Minimal Java fixture. |
| `tests/fixtures/indexer_project/native/engine.cpp` | **New file.** Minimal C++ fixture. |
| `tests/fixtures/indexer_project/scripts/helper.rb` | **New file.** Minimal Ruby fixture. |
| `tests/test_indexer_grammar_audit.sh` | **New file.** Bash-level CI gate against API-mismatch regressions. |
| `tests/run_tests.sh` | Register the new grammar-audit test. |

## Acceptance Criteria

- [ ] `audit_grammars()` returns a dict with one entry per extension
      in `_EXT_TO_LANG`. Each entry has the four documented fields
      populated, with `error` being `None` on success and a
      `ClassName: message` string on failure.
- [ ] `audit_grammars()` distinguishes three cases cleanly: (a) module
      not importable → `module_importable=False`, `language_loaded=False`,
      `error` mentions `ImportError`/`ModuleNotFoundError`; (b) module
      importable but no language factory → `module_importable=True`,
      `language_loaded=False`, `error` mentions `AttributeError`; (c)
      success → both booleans true, `error` is `None`.
- [ ] `python repo_map.py --audit-grammars` prints valid JSON to
      stdout and exits 0 without walking the project, without touching
      the cache, and without any stderr output on the success path.
- [ ] `check_indexer_available` emits a `warn`-level line for every
      extension where `module_importable=True` and `language_loaded=False`,
      containing the extension, the module name, and the captured
      error class/message. Hand-test: temporarily revert M122, run
      `tekhton --validate` or any command that triggers
      `check_indexer_available`, confirm a warning for `.ts` and
      `.tsx` appears.
- [ ] `check_indexer_available` emits only verbose-level lines for
      extensions whose grammar module is simply not installed — no
      warnings for the benign case.
- [ ] Setting `INDEXER_STARTUP_AUDIT=false` in `pipeline.conf` skips
      the audit entirely; `check_indexer_available` behaves exactly
      as it did pre-M123. No subprocess spawned.
- [ ] The five new fixture files exist and are parseable by their
      respective grammars when those grammars are installed. Missing
      grammars cause `pytest.skip` (not failure) in the parametrized
      integration test.
- [ ] `tests/test_indexer_grammar_audit.sh` passes: every extension
      whose module is importable also reports `language_loaded=True`.
      Test fails loudly (with the offending extension + error
      message) if a future grammar package introduces an API drift.
- [ ] `CLAUDE.md` documents `INDEXER_STARTUP_AUDIT` in the template-
      variables table with its default value.
- [ ] Shellcheck clean for `lib/indexer.sh` and the new grammar-audit
      shell test.
- [ ] No existing tests need edits to continue passing.
- [ ] Startup cost overhead measured: audit adds ≤ 200ms on a warm
      venv. If measured cost exceeds that, land with the audit behind
      a lazy wrapper that only runs when `check_indexer_available`
      has not run in the last 10 minutes (cache result in a state file
      under `.tekhton/`).

## Non-Goals

- Auto-reinstalling broken grammars. The audit warns and points users
  at `tekhton --setup-indexer`; it does not mutate the venv.
- Adding fixtures for `.swift`, `.kt`, `.dart`, `.cs`. Those grammars
  are less portable across CI environments; the audit alone is
  sufficient regression protection, and the loader is already shape-
  correct for them thanks to M122's factory probe.
- Changing `get_language()` to surface errors instead of returning
  `None`. The hot-path contract ("None on any failure") is used by
  `_extract_tags` and has to stay that way. The audit is a separate,
  cold-path diagnostic surface.
- Distinguishing "grammar version pinned wrong in `requirements.txt`"
  from "grammar's API changed upstream" in the warning message. Both
  resolve to the same user action (`--setup-indexer`), so the warning
  lumps them together.
- Expanding `_EXT_TO_LANG` to cover new languages. If a new language
  needs to be added, it's a separate milestone; M123 is purely about
  preventing silent failures for the languages we already claim to
  support.
