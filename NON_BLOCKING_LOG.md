# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-22 | "Fix the outstanding observations in the NON_BLOCKING_LOG.md"] `SX-1` (`lib/mcp.sh`): Cache implementation is correct. The sentinel pattern (`"1"` / `"0"` / `""`) handles all three states cleanly: unset, supported, not-supported. Early returns at lines 145–149 are correctly ordered (positive check before negative) so `return 0`/`return 1` align with what the caller expects. No behavior change when called once.
- [ ] [2026-03-22 | "Fix the outstanding observations in the NON_BLOCKING_LOG.md"] `SX-2` (`tools/tree_sitter_languages.py` + `tools/repo_map.py`): `extensions_for_languages()` is correctly added as a public function at line 107–109. The import in `repo_map.py:31` now includes `extensions_for_languages` and the call site at `_filter_by_extension():114` uses it correctly. Private import of `_EXT_TO_LANG` is gone. Function signature matches the plan exactly.
- [ ] [2026-03-22 | "Fix the outstanding observations in the NON_BLOCKING_LOG.md"] `SF-1` (`tools/setup_serena.sh`): Warning added at lines 248–250. Condition `[ "$detected_servers" != "none" ]` is correct — the warning only fires when servers were actually detected. Plain `[` (POSIX) rather than `[[` is consistent with the rest of the script which uses POSIX-style conditionals throughout. `_warn` helper is used as directed by the plan.
- [ ] [2026-03-22 | "Implement Milestone 2: Sliding Window & Plan Generation Integration"] `lib/milestone_archival.sh:43` (carried from cycle 1) — hardcodes `initiative="Milestone DAG"` for DAG-path archival; all DAG-mode archived milestones get the same section header regardless of which initiative they belong to.
- [ ] [2026-03-21 | "Resolve all observations in NON_BLOCKING_LOG.md. For each unresolved item, apply the fix, then mark it resolved. Continue until no unresolved observations remain."] `stages/init_synthesize.sh` is 533 lines — well over the 300-line ceiling. Pre-existing from Milestone 21, not introduced here, but a cleanup pass was a natural opportunity to split it.

## Resolved
