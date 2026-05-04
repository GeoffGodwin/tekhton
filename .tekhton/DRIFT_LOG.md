# Drift Log

## Metadata
- Last audit: 2026-04-30
- Runs since audit: 5

## Unresolved Observations
- [2026-05-04 | "Implement Milestone 2: Causal Log Wedge"] `lib/crawler.sh` — defines `_json_escape` with a body byte-identical to `lib/common.sh`. After m02 this is a shadowing duplicate: `common.sh` is always sourced first, so `crawler.sh`'s definition is dead. Coder already noted it as out of scope; cleanup candidate for the next drift-sweep pass.
- [2026-05-04 | "Implement Milestone 2: Causal Log Wedge"] `internal/proto/causal_v1.go:127` — `Itoa` is exported dead code (see Non-Blocking Notes above). Consolidate or remove in a future cleanup pass.
- [2026-05-04 | "M01"] [docs/go-build.md:68 vs Makefile:11] Illustrative ldflags example in the doc uses raw `cat VERSION` while the Makefile correctly strips whitespace with `tr`. Cosmetic — `version.String()` saves both callers — but the discrepancy could confuse the next wedge author who reads the doc before the Makefile.

## Resolved
