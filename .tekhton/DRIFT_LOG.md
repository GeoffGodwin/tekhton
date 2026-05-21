# Drift Log

## Metadata
- Last audit: 2026-05-18
- Runs since audit: 95

## Unresolved Observations
- [2026-05-18 | "unknown"] [internal/preflight/ui_audit.go:255] — Dead `strings.Join` call with incorrect "satisfy import" comment; should be deleted in the next cleanup pass.
- [2026-05-18 | "unknown"] [tests/] — V4 migration is accumulating skip-guarded bash tests faster than Go-native replacements are being written. Five more at m22 close; `test_plan_browser` still pending from m21. Drift observation to trigger a dedicated test-migration sweep before the accumulation becomes untrackable.
- [2026-05-18 | "unknown"] [tests/testdata/preflight_parity/green_path/expected/] — The `green_path` fixture has an empty `expected/` directory (the `no_report` mode asserts absence rather than a baseline file). This is correct behavior, but the pattern is inconsistent with `env_only_fail` and `ui_config_autopatch` which both have explicit baseline files. A README note in `green_path/` explaining why there is no baseline file would reduce future confusion.
- [2026-05-18 | "unknown"] The two DRIFT_LOG.md staleness fixes (ADL-36 sub-items A and B) are factually correct. `TestDefaultLibHelpersParityWithLegacy` is confirmed at `internal/stagerunner/parity_test.go:42`. `scriptFor` is confirmed absent from `internal/stagerunner/adapter.go` and `adapter_test.go` (grep returns no matches). The resolved entries in DRIFT_LOG.md accurately describe both dispositions.
- [2026-05-18 | "unknown"] Scope was cleanly bounded. Only `.tekhton/DRIFT_LOG.md` was modified; no code files were touched. No scope creep.
- [2026-05-18 | "unknown"] The senior coder's no-op pass is correct — the Simplification section of the architect plan is empty, and the deferred item (drift_cleanup.sh non-blocking router sentinel) is properly documented as m24 work.

## Resolved
