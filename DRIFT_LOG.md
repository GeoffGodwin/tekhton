# Drift Log

## Metadata
- Last audit: 2026-04-09
- Runs since audit: 4

## Unresolved Observations
- [2026-04-09 | "Address all 5 open non-blocking notes in NON_BLOCKING_LOG.md. Fix each item and note what you changed."] `index_view.sh` — `_view_render_dependencies` now uses `${#output}` inline for budget checks while sibling functions maintain a dedicated `used` running counter. Functionally equivalent, but the style inconsistency remains. Low priority; address in a future cleanup pass.
- [2026-04-09 | "M69"] `crawler.sh:136` — Comment references `_truncate_section` which was deleted in this milestone. Same item as Non-Blocking Note above; surfacing here for drift log accumulation.
- [2026-04-09 | "architect audit"] **Observation 2 — Duplicated test/coverage detection logic** (`_emit_tests_json` in `crawler_inventory_emitters.sh:86-153` and `_crawl_test_structure` in `crawler_inventory.sh:183-258`): The observation itself documents the correct disposition: "Both are needed for now (one emits JSON, one emits markdown for the legacy bridge), but the duplication will compound in M69 when the markdown producer is retired." De-duplicating now would require introducing an abstraction that serves two callers with incompatible output formats (JSON vs markdown). That abstraction would be speculative — the right fix is to retire `_crawl_test_structure` when the legacy bridge is removed in M69. Deferring. Note: The drift log cites `crawler_emit.sh:300-366` for `_emit_tests_json`, but that file is only 276 lines. The function lives in `crawler_inventory_emitters.sh:86-153`. **Observation 3 — Redundant `_crawl_directory_tree` call in `_generate_legacy_index`** (`crawler_emit.sh:231-275`, specifically line 237): `_emit_tree_txt` already called `_crawl_directory_tree` and wrote the result to `tree.txt` before `_generate_legacy_index` runs (see `crawler.sh:87-96` call order). The legacy bridge at `crawler_emit.sh:237` repeats the traversal instead of reading `tree.txt`. The observation is correct, but also correctly defers the fix: `_generate_legacy_index` is a temporary bridge scheduled for removal in M69. Patching it to read `tree.txt` instead adds code to a function that will be deleted. Deferring to M69. Note: The drift log cites `crawler_emit.sh:476-520` for this function, but the actual range is `crawler_emit.sh:231-275`.

## Resolved
