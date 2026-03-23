# Drift Log

## Metadata
- Last audit: 2026-03-22
- Runs since audit: 4

## Unresolved Observations
- [2026-03-22 | "Implement Indexer Infrastructure & Setup Command then carry on to future milestones."] `lib/indexer_helpers.sh` — The `&&`-chained seen-set pattern is now present in both `indexer.sh` (original) and `indexer_helpers.sh` (extracted copy). Two occurrences of the non-standard pattern — approaching the threshold where a style sweep would be warranted if it spreads further.
- [2026-03-22 | "Implement Indexer Infrastructure & Setup Command then carry on to future milestones."] `repo_map.py:113` — direct import of `_EXT_TO_LANG` (private module-level dict in `tree_sitter_languages.py`) creates hidden coupling: if the internal data structure ever changes name or format, `repo_map.py` will break with an `ImportError` rather than a clear AttributeError at the call site. Consider exporting a public API function from `tree_sitter_languages.py` for this use.

## Resolved
