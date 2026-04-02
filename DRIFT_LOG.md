# Drift Log

## Metadata
- Last audit: 2026-04-01
- Runs since audit: 1

## Unresolved Observations
(none)

## Resolved
- [RESOLVED 2026-04-01] `lib/dashboard_parsers.sh` is 465 lines, 55% over the 300-line ceiling. Not introduced by this change, but the file continues to grow as new fallback paths are added. Candidate for splitting when next touched.
- [RESOLVED 2026-04-01] `tests/test_dashboard_parsers_bugfix.sh` header comment (lines 6–8) still references the original bug numbers from a prior fix cycle. The three security items addressed in this task have no corresponding header documentation in the file.
