#### [DONE] Milestone 4: Tree-Sitter Repo Map Generator
<!-- milestone-meta
id: "4"
status: "done"
-->
Implement the Python tool that parses source files with tree-sitter, extracts
definition and reference tags, builds a file-relationship graph, ranks files by
PageRank relevance to the current task, and emits a token-budgeted repo map
containing only function/class/method signatures — no implementations.

Files to create:
- `tools/repo_map.py` — main entry point. CLI: `repo_map.py --root <dir>
  --task "<task string>" --budget <tokens> --cache-dir <path> [--files f1,f2]`.
  Steps: (1) walk project tree respecting `.gitignore`, (2) parse each file with
  tree-sitter to extract tags (definitions: class, function, method; references:
  call sites, imports), (3) build a directed graph: file A → file B if A references
  a symbol defined in B, (4) run PageRank with personalization vector biased toward
  files matching task keywords, (5) emit ranked file entries with signatures only,
  stopping when token budget is exhausted. Output format: markdown with
  `## filename` headings and indented signatures.
- `tools/tag_cache.py` — disk-based tag cache using JSON. Key: file path +
  mtime. On cache hit, skip tree-sitter parse. Cache stored in
  `REPO_MAP_CACHE_DIR/tags.json`. Provides `load_cache()`, `save_cache()`,
  `get_tags(filepath, mtime)`, `set_tags(filepath, mtime, tags)`.
- `tools/tree_sitter_languages.py` — language detection and grammar loading.
  Maps file extensions to tree-sitter grammars. Provides `get_parser(ext)` which
  returns a configured parser or `None` for unsupported languages. Initial
  language support: Python, JavaScript, TypeScript, Java, Go, Rust, C, C++,
  Ruby, Bash, Dart, Swift, Kotlin, C#.
- `tools/requirements.txt` — pinned dependencies: `tree-sitter>=0.21`,
  `tree-sitter-languages>=1.10` (or individual grammar packages),
  `networkx>=3.0`.

Files to modify:
- `lib/indexer.sh` — implement `run_repo_map()` to invoke
  `tools/repo_map.py` via the project's indexer virtualenv Python. Parse
  exit code: 0 = success (stdout is the map), 1 = partial (some files
  failed, map is best-effort), 2 = fatal (fall back to 2.0). Write output
  to `REPO_MAP_CACHE_DIR/REPO_MAP.md`.

Output format example:
```markdown
