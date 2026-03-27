## Summary
This change modifies `archive_completed_milestone()` in `lib/milestone_archival.sh` to skip initiative-scoped archive lookups when DAG mode is active, passing an empty string to `_milestone_in_archive()` for a global search instead. The change is a focused, single-function logic fix with no authentication, network, or user-input surface. No security concerns were identified.

## Findings
None

## Verdict
CLEAN
