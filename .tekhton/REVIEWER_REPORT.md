# Reviewer Report — M123 Indexer Grammar Coverage Audit (Cycle 2)

## Verdict
APPROVED

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `_indexer_run_startup_audit` reads tab-separated fields into `status f2 f3 f4 f5`. The `f2`–`f5` names are opaque; names like `ext module_name lang_name err_msg` would make the MISMATCH/MISSING case arms self-explanatory without needing the Python output-format comment overhead. Minor readability; fix whenever the function is next touched.
- `tools/repo_map.py` is 874 lines, acknowledged as pre-existing in the coder summary. Not introduced by M123.

## Coverage Gaps
- `tests/test_indexer_grammar_audit.sh` skips entirely when `jq` is absent. There is no fallback assertion path for jq-free CI environments. Not a blocker — the Python unit tests cover the classification logic independently.

## Drift Observations
- `lib/indexer_audit.sh:41–66` embeds ~25 lines of inline Python that mirrors the classification logic already in `audit_grammars()`. If the tab-separated output format of the Python snippet ever changes, the `while IFS=$'\t' read` parsing loop in bash must also change, and the two sides are not co-located. A thin Python entry point that emits the classification directly (or reuse of `--audit-grammars` output from `repo_map.py`) would eliminate this coupling. Low priority; flag for the next audit cycle.
