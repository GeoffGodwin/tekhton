# Reviewer Report — M133 Diagnose Rule Enrichment for Resilience Arc Failure Modes

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `diagnose_rules.sh` is 299 lines and `diagnose_rules_resilience.sh` is 298 lines — both are one line from the 300-line ceiling. Any future rule addition to either file will immediately require extraction.
- `_rule_build_fix_exhausted()` header comment numbers sources 1/2/3 in the conventional order, but the code evaluates them 2→1→3 (RUN_SUMMARY first, then BUILD_FIX_REPORT, then LAST_FAILURE_CONTEXT). The inline comment "most reliable when present" clarifies the intent, but the mismatch between the source-numbering and evaluation order could confuse a future reader.
- Source 3 in `_rule_ui_gate_interactive_reporter` uses `grep -rqlE` to scan the full `.claude/logs/` directory without a depth or file-count limit. Acceptable for a manually-invoked diagnostic tool; worth a comment acknowledging the trade-off for large log archives.
- The `# shellcheck disable=SC2034` annotations before each `DIAG_*` assignment in `_rule_preflight_interactive_config` (lines 281–285) are absent from the two sibling rules in the same file. Inconsistent but harmless — shellcheck passes clean either way.

## Coverage Gaps
- None — T1–T12 cover all four new rules and the `_rule_max_turns` upgrade, including both confidence levels, both `no_progress`/`exhausted` branches, the stale-report guard, backward compatibility with v1 fixtures, and both priority-ordering assertions.

## ACP Verdicts
No Architecture Change Proposals present in CODER_SUMMARY.md.

## Drift Observations
- `diagnose_rules.sh:280–299` — The `DIAGNOSE_RULES` array grew from 14 to 18 entries in this milestone alone. If growth continues at this rate, the primary-rule file will require re-splitting before M134. Consider a thin registry file (`diagnose_rules_registry.sh`) to decouple rule ordering from the primary-rule bodies, matching the `pipeline_order_policy.sh` precedent.
- `diagnose_rules_resilience.sh:281–285` — Three successive `# shellcheck disable=SC2034` lines where sibling rules in the same file use none. Since the top-level declarations in `diagnose_rules.sh` already carry the disable comment, the per-assignment suppression here may be unnecessary. Worth verifying with `shellcheck --enable=all` to confirm whether the lines are load-bearing.
