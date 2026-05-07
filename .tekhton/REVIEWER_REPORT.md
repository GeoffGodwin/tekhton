# Reviewer Report — m16 Config Loader Wedge

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `rangeCheck(cfg, "QUOTA_MAX_PAUSE_DURATION", 300, 86400, "14400")` uses a fallback of `14400` (4 h) but the documented default is `18900` (5h15m, per CLAUDE.md). The fallback fires only when a user has an explicitly invalid value below 300; the base default (18900) applies when the key is absent. Low-impact but inconsistent with the documented contract.
- `printDiagnostics` in `cmd/tekhton/config.go:215` accepts an anonymous `interface{ Write([]byte) (int, error) }` instead of `io.Writer`. Semantically equivalent, but the idiomatic form is `io.Writer`.
- The `EmitJSON` envelope (`"envelope_ver": "tekhton.config.v1"`) is declared inline in an anonymous struct rather than through `internal/proto/`. Every other cross-language envelope in the codebase registers its type in `internal/proto/` (e.g. `internal/proto/manifest_v1.go`). The shell-emit seam (the actual runtime cross-language boundary) is correct; only the JSON path is inconsistent. A follow-up milestone should add `internal/proto/config_v1.go` for consistency.
- `lateDefaults` is an empty `[]defaultRule{}`. The comment says "currently empty — kept as a hook." An empty slice that drives a full `applyLateDefaults` pass on every `Load` call is harmless now but silently wastes a loop iteration. Add a `// TODO(m17+)` comment or collapse into `applyDefaults` once it's clear no late-phase keys are needed.
- The milestone design (Goal 1) described a nested typed `Config` struct with struct tags (e.g. `Limits.MaxReviewCycles int \`conf:"MAX_REVIEW_CYCLES"\``). The implementation uses `map[string]string` throughout. The flat-map approach is a defensible and arguably better choice for this port (direct parity with bash env vars, no field-name mapping), but the deviation from the design document is worth recording so future in-process callers (m17+ orchestrate/prompt/dag) know they'll be reading a map, not a struct.

## Coverage Gaps
- `config_test.go::TestAllKeys` only exercises a 2-key map. Edge cases (duplicate keys from pipeline.conf, keys set only via env, `LoadDefaultsOnly` with non-empty `KeysSet`) have no unit test.
- `findInlineComment` is tested via `TestParse_FindInlineComment` with 6 cases. No test for a value that contains embedded single quotes followed by a comment (the apostrophe-escape path interacts with comment stripping).
- No test verifies that `EmitShell` + `eval` round-trips a value containing both a single quote and a newline (unusual but possible in e.g. `ANALYZE_CMD`).

## ACP Verdicts
None — no `## Architecture Change Proposals` section in CODER_SUMMARY.md.

## Drift Observations
- `internal/config/defaults.go:599` — `AGENT_ACTIVITY_TIMEOUT` carries an explicit comment explaining it "lives in lib/agent_monitor.sh today (not in config_defaults.sh)" and mirrors the operative default so milestone-mode math works. This workaround should be removed once `agent_monitor.sh` is ported (its wedge should add the key to `baseDefaults` with authority, not as a shadow copy).
- `cmd/tekhton/config.go:215` — `printDiagnostics` is defined as a package-level function that takes an anonymous writer interface. The other Cobra command handlers (causal, state, dag, etc.) consistently use `cmd.ErrOrStderr()` inline. The helper is 3 lines; inlining it at the two call sites would be consistent with the rest of the package.
