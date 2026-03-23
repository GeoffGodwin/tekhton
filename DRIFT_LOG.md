# Drift Log

## Metadata
- Last audit: 2026-03-22
- Runs since audit: 1

## Unresolved Observations
- [2026-03-22 | "Fix the outstanding observations in the NON_BLOCKING_LOG.md"] None — all three drift log entries (SX-1, SX-2, SF-1) have been fully addressed. The out-of-scope item (`&&`-chained seen-set pattern in `lib/indexer_helpers.sh`) was correctly left untouched.
- [2026-03-22 | "architect audit"] **`lib/indexer_helpers.sh` — `&&`-chained seen-set pattern (two occurrences)** The drift observation explicitly characterizes this as "approaching the threshold where a style sweep would be warranted *if it spreads further*." Two occurrences is below the threshold for a sweep. No files added in this run expand the pattern. No action is warranted now; the observation should remain open in the drift log and be re-evaluated if a third occurrence appears.

## Resolved
- [RESOLVED 2026-03-22] `lib/mcp.sh:143` — `_cli_supports_mcp_config()` shells out to `claude --help | grep` on every `start_mcp_server()` call. If Claude CLI is slow to start or the help text grows, this adds latency on every pipeline run where `SERENA_ENABLED=true`. Consider caching the result in a module-level variable (`_CLI_SUPPORTS_MCP_CONFIG=""`) after the first check.
- [RESOLVED 2026-03-22] `tools/setup_serena.sh` language-server detection enumerates by binary name (`pyright`, `typescript-language-server`, etc.) but does not validate that Serena actually knows how to configure those servers. If Serena's config schema differs from the detected server name, the generated `serena_mcp_config.json` may be syntactically valid but functionally broken. Worth adding a note in the setup summary output.
- [RESOLVED 2026-03-22] `lib/indexer_helpers.sh` — The `&&`-chained seen-set pattern is now present in both `indexer.sh` (original) and `indexer_helpers.sh` (extracted copy). Two occurrences of the non-standard pattern — approaching the threshold where a style sweep would be warranted if it spreads further.
- [RESOLVED 2026-03-22] `repo_map.py:113` — direct import of `_EXT_TO_LANG` (private module-level dict in `tree_sitter_languages.py`) creates hidden coupling: if the internal data structure ever changes name or format, `repo_map.py` will break with an `ImportError` rather than a clear AttributeError at the call site. Consider exporting a public API function from `tree_sitter_languages.py` for this use.
