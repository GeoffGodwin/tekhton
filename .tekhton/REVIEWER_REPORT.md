# Reviewer Report -- Milestone 17: Error Taxonomy Wedge

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- get_pattern_count() in lib/errors.sh:64 hardcodes 56 but patternSpecs in internal/errors/patterns.go contains 57 entries. Off by one. No test asserts the exact count so there is no runtime failure, but the stale value misleads callers and future audits.
- _is_non_diagnostic_line in lib/errors.sh diverges from Go IsNonDiagnosticLine for pnpm notice and yarn notice lines. Bash filters them as noise via the pattern (npm|pnpm|yarn)+warn|notice; Go noiseLineREs covers npm notice but not pnpm notice or yarn notice. Impact is conservative (those lines fall through to unknown_only routing rather than being silently dropped) and no parity fixture exercises it today, but the seam will widen as the noise-pattern set evolves.

## Coverage Gaps
- None

## ACP Verdicts
- ACP: rename lib/error_patterns_remediation.sh to lib/remediation.sh -- ACCEPT -- Satisfies the glob-based acceptance criterion (git ls-files lib/error_patterns*.sh returns nothing) without orphaning gates.sh::attempt_remediation. Deferring the remediation engine port to Phase 5 is correctly reasoned: the engine writes causal events and HUMAN_ACTION_REQUIRED entries that other Phase 5 wedges own, and expanding scope here would violate Rule 10. The rename also better describes the file role as an executor, not a pattern table.

## Drift Observations
- lib/errors.sh:78-91 -- The inline _is_non_diagnostic_line is a deliberate dual implementation (retained to avoid forking the binary per line in test drivers). It will silently drift from classify.go::IsNonDiagnosticLine as the noise-pattern set evolves. A comment pointing to the canonical Go location would help future authors know which file is authoritative.
