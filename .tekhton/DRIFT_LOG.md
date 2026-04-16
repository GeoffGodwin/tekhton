# Drift Log

## Metadata
- Last audit: 2026-04-15
- Runs since audit: 1

## Unresolved Observations
- [2026-04-16 | "M89"] `lib/test_audit.sh` is 574 lines — well over the 300-line soft ceiling. The sampler extraction into `lib/test_audit_sampler.sh` was the right call, but the parent file still warrants a dedicated refactor milestone to split it further.

## Resolved
- [RESOLVED 2026-04-15] `tests/test_review_cache_invalidation.sh` and `tests/test_run_memory_emission.sh` — no established convention across the test suite for whether test files should be self-contained (use `${VAR:-.default}`) or rely on the test runner to export variables. Three of the five modified files are self-contained; two are not. Worth settling on a single pattern in a future cleanup pass.
