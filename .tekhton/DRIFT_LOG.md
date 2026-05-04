# Drift Log

## Metadata
- Last audit: 2026-04-30
- Runs since audit: 4

## Unresolved Observations
- [2026-05-04 | "M01"] [docs/go-build.md:68 vs Makefile:11] Illustrative ldflags example in the doc uses raw `cat VERSION` while the Makefile correctly strips whitespace with `tr`. Cosmetic — `version.String()` saves both callers — but the discrepancy could confuse the next wedge author who reads the doc before the Makefile.

## Resolved
