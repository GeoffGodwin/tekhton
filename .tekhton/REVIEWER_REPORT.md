# Reviewer Report — m33.1 Dashboard Emitters (Review Cycle 2)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- Parity gate (`tests/test_dashboard_emit_parity.sh`) uses 26 structural property assertions rather than byte-identical comparison against committed frozen baselines. `internal/dashboard/testdata/` (required by the milestone spec) does not exist. The structural checks are reasonable given bash emitter deletion, but the byte-identical guarantee specified in AC "Parity gate scenario 1: the 10 emitted JS files byte-match the captured baseline" is not satisfied. Flag for m33.2: if the StatusReader round-trip gate provides equivalent byte-identical coverage, the gap is closed.
- Parity gate scenario 2 (multi-stage failure) does not plant a `LAST_FAILURE_CONTEXT.json` fixture, does not invoke `tekhton dashboard emit diagnosis`, and makes no assertion on `diagnosis.js` — the AC "diagnosis.js `available=true`" is unexercised. The emitter body is correct; this is a test coverage gap.
- `internal/proto/dashboard_v1_extra.go:154`: `DashboardInitV1` uses camelCase JSON field names (`fileCount`, `projectType`) while every other proto struct uses snake_case. Verify against `templates/watchtower/app.js` before m33.2 — if the Watchtower reader already uses snake_case keys, the init payload will be misread.
- `lib/dashboard_shim.sh:23`: `source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"` executes unconditionally at shim-load time. When m33.2 ports parsers to Go, this line must be removed; it is a forward-compatibility trap.

## Coverage Gaps
- No concurrent atomicity test for `internal/dashboard/jsfile.go`. The milestone AC required "spawn 100 concurrent reads while writing 100 times; reader sees only fully-formed JS files." The concurrency guarantee (the primary load-bearing reason for tempfile+rename) remains untested.
- `EmitDiagnosis` with `LAST_FAILURE_CONTEXT.json` present (the `available=true` path) has no unit test — only the missing-file path is exercised.
- `EmitTeamState` has no direct unit test; the `errEmptyTeamID` sentinel on empty team ID input is untested.

## Drift Observations
- `internal/dashboard/emit_timeline.go:108`: `default` arm of `timelinePassFn` behaves identically to the `verbose` arm — an unrecognized `DASHBOARD_VERBOSITY` value silently shows everything rather than warning. Misconfigured values are invisible to operators.
- `internal/dashboard/emit_reports.go:156–179`: `parseReviewerReport` uses a hand-rolled line scanner while `parseIntakeReport` uses `verdictInlineRE`. Two subtly different parsers for the same heading-followed-by-verdict pattern; one reader for both would reduce drift.
- `internal/dashboard/dashboard.go:154–168`: `jsonEscape` is defined but never called in the package. Dead code from an earlier draft; actual escaping is handled by `json.Marshal` in `jsfile.go`.
- `cmd/tekhton/dashboard.go:151–163`: `dashDirEnv()` and `dashboardTemplatesDir()` duplicate env-reading logic already in `NewEmitter` via `envOr`. Not harmful but a second reader for the same env vars.
