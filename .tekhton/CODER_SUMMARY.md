# Coder Summary

## Status: COMPLETE

## What Was Implemented
All 8 open non-blocking notes addressed:

1. `lib/errors.sh:64` — `get_pattern_count()` now returns `57` (matches `patternSpecs` row count in `internal/errors/patterns.go`).
2. `internal/errors/classify.go` — added `pnpm notice` and `yarn notice` regexes to `noiseLineREs` so the Go classifier filters the same noise lines as the bash `_is_non_diagnostic_line` helper.
3. `internal/config/validate.go:166` — `rangeCheck` fallback for `QUOTA_MAX_PAUSE_DURATION` changed from `"14400"` to `"18900"` to match the documented default.
4. `cmd/tekhton/config.go` — `printDiagnostics` parameter switched from anonymous `interface{ Write([]byte) (int, error) }` to `io.Writer` (added `io` to imports).
5. `internal/config/emit.go` — `EmitJSON` payload now uses `proto.ConfigV1` and `proto.ConfigProtoV1` from `internal/proto/config_v1.go` (the proto file already exists). Inline anonymous struct removed.
6. `internal/config/defaults.go` — `applyLateDefaults` short-circuits when `lateDefaults` is empty; added `// TODO(m17+)` comment on the slice declaration.
7. `internal/config/config.go` — `Config` struct doc comment now records the m16 design deviation (flat `map[string]string` vs nested typed struct) so future in-process callers know what shape to expect.
8. `cmd/tekhton/prompt.go` — `resolvePromptsDir` now uses `filepath.Join(home, "prompts")` instead of string concatenation; added `path/filepath` to imports.

`.tekhton/NON_BLOCKING_LOG.md` updated: all 8 items moved from `## Open` to `## Resolved`.

## Root Cause (bugs only)
N/A — task was non-blocking-debt cleanup, not a bug fix.

## Files Modified
- `lib/errors.sh` — get_pattern_count returns 57.
- `internal/errors/classify.go` — added pnpm notice and yarn notice noise REs.
- `internal/config/validate.go` — QUOTA_MAX_PAUSE_DURATION fallback 18900.
- `internal/config/defaults.go` — empty-slice fast path + TODO comment.
- `internal/config/emit.go` — uses proto.ConfigV1 envelope; added internal/proto import.
- `internal/config/config.go` — added design-deviation paragraph to Config doc.
- `cmd/tekhton/config.go` — printDiagnostics now takes io.Writer; added io import.
- `cmd/tekhton/prompt.go` — uses filepath.Join; added path/filepath import.
- `.tekhton/NON_BLOCKING_LOG.md` — all 8 items moved Open → Resolved.

## Docs Updated
None — no public-surface changes in this task. Items 1–8 are internal-only refinements (parity tweaks, idiomatic Go, doc-comment additions). The `tekhton config`/`tekhton prompt` CLI surfaces, the `tekhton.config.v1` envelope shape, the `pipeline.conf` keys, and the bash function names (`get_pattern_count`, `printDiagnostics`, `EmitJSON`) all keep their existing contracts.

## Human Notes Status
All 8 notes from `.tekhton/NON_BLOCKING_LOG.md`:
- Note 1 (get_pattern_count off-by-one) — COMPLETED
- Note 2 (pnpm/yarn notice noise REs) — COMPLETED
- Note 3 (QUOTA_MAX_PAUSE_DURATION fallback) — COMPLETED
- Note 4 (printDiagnostics → io.Writer) — COMPLETED
- Note 5 (EmitJSON → proto.ConfigV1) — COMPLETED
- Note 6 (lateDefaults empty-slice waste) — COMPLETED
- Note 7 (Config map vs typed struct doc) — COMPLETED
- Note 8 (filepath.Join in prompt.go) — COMPLETED
