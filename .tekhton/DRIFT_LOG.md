# Drift Log

## Metadata
- Last audit: 2026-05-04
- Runs since audit: 1

## Unresolved Observations
- [2026-05-04 | "Implement Milestone 3: Pipeline State Wedge"] `lib/state_helpers.sh:190-220` — No `# REMOVE IN m05` annotation on the legacy markdown branch in `_state_bash_read_field`. When `legacy_reader.go` is deleted in m05 this dead branch is likely to survive the cleanup pass. Adding the annotation now keeps the two removal targets in sync.

## Resolved
- [RESOLVED 2026-05-04] `lib/crawler.sh` — defines `_json_escape` with a body byte-identical to `lib/common.sh`. After m02 this is a shadowing duplicate: `common.sh` is always sourced first, so `crawler.sh`'s definition is dead. Coder already noted it as out of scope; cleanup candidate for the next drift-sweep pass.
- [RESOLVED 2026-05-04] `internal/proto/causal_v1.go:127` — `Itoa` is exported dead code (see Non-Blocking Notes above). Consolidate or remove in a future cleanup pass.
- [RESOLVED 2026-05-04] [docs/go-build.md:68 vs Makefile:11] Illustrative ldflags example in the doc uses raw `cat VERSION` while the Makefile correctly strips whitespace with `tr`. Cosmetic — `version.String()` saves both callers — but the discrepancy could confuse the next wedge author who reads the doc before the Makefile.
