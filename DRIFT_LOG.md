# Drift Log

## Metadata
- Last audit: 2026-03-23
- Runs since audit: 3

## Unresolved Observations
- [2026-03-23 | "Implement Milestone 17: Pipeline Diagnostics & Recovery Guidance"] `diagnose_rules.sh:299` — `# shellcheck disable=SC2034` is placed above the `_rule_unknown()` function definition line. SC2034 disables apply to the immediately following statement, not the function body, so any suppressed assignment inside the function is not actually covered. Shellcheck reports clean, so benign — but the comment placement may confuse future readers.
- [2026-03-23 | "Implement Milestone 17: Pipeline Diagnostics & Recovery Guidance"] `lib/state.sh:112-119` — `clear_pipeline_state()` uses `[ -f ]` (POSIX single brackets) for both its original check and the new M17 addition. Project standard is `[[ ]]`. Pre-existing inconsistency in the function; M17 added code matches existing local style rather than the project standard.

## Resolved
- [2026-03-22 | RESOLVED 2026-03-22] All three prior drift entries (SX-1, SX-2, SF-1) were fully addressed in commit 58c3ea3.
- [2026-03-22 | RESOLVED 2026-03-22] `lib/indexer_helpers.sh` — `&&`-chained seen-set pattern was refactored to `if/then/fi` style in commit 58c3ea3. No remaining occurrences of this pattern in the codebase.
