# Drift Log

## Metadata
- Last audit: 2026-04-15
- Runs since audit: 3

## Unresolved Observations
- [2026-04-15 | "Fix 10 failing shell tests. All failures are stale test expectations from the b3b6aff CLI flag refactor. Modify ONLY files under tests/. Run bash run_tests.sh to verify — must exit 0."] `tests/test_review_cache_invalidation.sh` and `tests/test_run_memory_emission.sh` — no established convention across the test suite for whether test files should be self-contained (use `${VAR:-.default}`) or rely on the test runner to export variables. Three of the five modified files are self-contained; two are not. Worth settling on a single pattern in a future cleanup pass.

## Resolved
