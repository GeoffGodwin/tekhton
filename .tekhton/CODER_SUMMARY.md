# Coder Summary

## Status: COMPLETE

## What Was Implemented

m33.2 — **Watchtower dashboard data-layer READ side ported from Bash to Go.**
The three bash sources (`lib/dashboard_parsers.sh` 165 lines,
`lib/dashboard_parsers_runs.sh` 285 lines, `lib/dashboard_parsers_runs_files.sh`
105 lines — 555 LOC total) are deleted; their behavior now lives under
`internal/dashboard/parse_*.go` behind the `StatusReader` type, addressable
via the new `tekhton dashboard parse <kind>` Cobra subcommand tree. The m33
dashboard arc closes with both children done (1547 bash LOC removed across
m33.1 + m33.2).

### Goal-by-goal coverage

| Goal | Outcome |
|------|---------|
| 1 — `StatusReader` (`internal/dashboard/parse.go`) | Pure dispatcher (ProjectDir + LogDir fields); `NewStatusReader(*Emitter)` constructor. |
| 2 — One `parse_<kind>.go` per parser family | `parse_security.go`, `parse_intake.go`, `parse_coder.go`, `parse_reviewer.go`, `parse_runs.go` — five files, each with a `ParseXyz(path string) (proto.…, error)` method on `*StatusReader`. |
| 3 — Delete the m33.1 transition seams | The "transition seam" m33.1 mentioned never actually shelled out to bash; m33.1 inlined the parsers directly into `emit_security.go` / `emit_reports.go` / `emit_metrics.go`. m33.2 lifts those inlined bodies into the per-kind parser files behind `e.statusReader().ParseXyz(...)`, leaving the emit files lean. |
| 4 — `tekhton dashboard parse <kind>` Cobra arms | `cmd/tekhton/dashboard_parse.go` (140 lines). Five Hidden sub-subcommands; each parses a fixture file and prints the JSON payload to stdout. Smoke tests in `dashboard_parse_test.go`. |
| 5 — Bash file deletions | `lib/dashboard_parsers.sh`, `lib/dashboard_parsers_runs.sh`, `lib/dashboard_parsers_runs_files.sh` all deleted via `git rm`. `lib/dashboard_shim.sh` source line removed. `tekhton-legacy.sh:663` source line removed (the early-exit `--diagnose` branch no longer pulls in any dashboard parser). `lib/diagnose_output_extra.sh` inlines a minimal `_diagnose_write_js_file` helper so the bash diagnose path can still emit `data/diagnosis.js` without the deleted `_write_js_file` from the parser file. |
| 6 — Parser parity gate | `tests/test_dashboard_parse_parity.sh` (180 lines) drives 7 scenarios (security report; intake inline + header; coder summary; reviewer report; runs from metrics.jsonl with zero-turn filter; runs from RUN_SUMMARY_*.json fallback) through `tekhton dashboard parse`. 24 jq-asserted properties, all passing. |
| 7 — VERSION | At `4.33.13`; per spec rule "VERSION = max(current, 4.33.0)" already satisfied. Finalize hook bumps automatically. |
| 8 — Shellcheck cleanliness | `shellcheck -e SC1091 lib/*.sh` exits 0. Pre-existing SC2034/SC2317 warnings in unrelated tests are untouched. |

### Python heredoc collapse (Watch For #1)

The bash `_parse_run_summaries_from_jsonl` had an embedded ~80-line Python
heredoc for JSON parsing plus a sed/awk fallback for the no-Python case. The
Go port collapses both into one `encoding/json` path with a typed
`metricsRecord` input struct. The bash sed/awk fallback's known
depth-counting divergence (documented in `dashboard_parsers_runs.sh:270-276`)
disappears — the Go adopts the **Python primary path semantics** (depth
applies to lines pre-filter), as the milestone spec required. Documented in
`internal/dashboard/parse_runs.go` package comment.

### Proto shape fix

m33.1's `DashboardRunSummary` struct (in `internal/proto/dashboard_v1_extra.go`)
was a placeholder with `Timestamp/Task/Status/Turns/DurationS` fields — these
do NOT match the JSON shape the Watchtower JS reader consumes (which expects
`outcome/total_turns/total_time_s/run_type/task_label/timestamp/team/stages`).
m33.2 rewrites the struct to the canonical bash output shape and verified via
parity gate + grep against `templates/watchtower/app.js`. `stages` becomes a
`map[string]DashboardRunSummaryStage` (not a slice), `DashboardRunSummaryStage`
drops the `Name` field and adds `Cycles`/`ReworkCycles`. `DashboardMetricsV1`
gets a `MarshalJSON` that emits `"runs":[]` for nil slices.

### Adaptation of legacy bash tests

Ten bash tests sourced the deleted parsers; each got a SKIP banner with a
pointer to the new contract gates:

- `test_intake_report_rendering.sh`
- `test_dashboard_parsers_json_escape.sh`
- `test_duration_estimation_jsonl.sh`
- `test_m66_full_stage_metrics.sh`
- `test_intake_report_edge_cases.sh`
- `test_duration_estimation_shell_fallback.sh`
- `test_dashboard_zero_turn_edge_cases.sh`
- `test_dashboard_parsers_delegation.sh` (the whole reason for existing — the
  file-split delegation pattern — disappears with the bash files)
- `test_intake_report_json_escape.sh`
- `test_watchtower_perstage_jsonl.sh`

Two further legacy tests were updated rather than retired:

- `tests/test_diagnose.sh` — the `_write_js_file` mock renamed to
  `_diagnose_write_js_file` to match the inlined helper's new name.
- `tests/test_nonblocking_log_fixes.sh:164-168` — Fix #20 was asserting that
  `lib/dashboard_shim.sh` sources `dashboard_parsers.sh`; updated to instead
  assert the shim execs `tekhton dashboard`.

### Other infrastructure changes

- `internal/dashboard/emit.go` — `Emitter` carries a `reader *StatusReader`
  field; `NewEmitter` constructs one; `e.statusReader()` lazy-init's for
  test-constructed Emitters that bypass NewEmitter.
- `lib/common.sh:226-230` — updated comment to drop the `dashboard_parsers.sh`
  reference from the `_json_escape` consumer list.

## Root Cause (bugs only)
N/A — implementation milestone, not a bug fix.

## Files Modified

### Go — created (NEW)
- `internal/dashboard/parse.go` (NEW) — `StatusReader` type + `NewStatusReader`.
- `internal/dashboard/parse_security.go` (NEW) — `ParseSecurity` + `detectSeverity` + `owaspRE`.
- `internal/dashboard/parse_intake.go` (NEW) — `ParseIntake` + `extractTweakedContent` + `extractAfterHeader` + `atoiSafe`.
- `internal/dashboard/parse_coder.go` (NEW) — `ParseCoder` + `countFilesModified` + `isFilesSectionHeading`.
- `internal/dashboard/parse_reviewer.go` (NEW) — `ParseReviewer` + `mustCompileAnchored`.
- `internal/dashboard/parse_runs.go` (NEW) — `ParseRunSummaries` + `parseMetricsJSONL` + `parseRunSummaryFiles` + `recordToSummary` + `fileToSummary` + `estimateMissingDurations` + `stageMetricsFor` + private `metricsRecord` and `runSummaryFile` types.
- `internal/dashboard/parse_security_test.go` (NEW) — 4 table-driven cases.
- `internal/dashboard/parse_intake_test.go` (NEW) — 5 cases.
- `internal/dashboard/parse_coder_test.go` (NEW) — 5 cases.
- `internal/dashboard/parse_reviewer_test.go` (NEW) — 4 cases.
- `internal/dashboard/parse_runs_test.go` (NEW) — 6 cases.
- `internal/dashboard/testdata/parsers/security/golden.md` (NEW).
- `internal/dashboard/testdata/parsers/intake/inline.md` (NEW).
- `internal/dashboard/testdata/parsers/intake/header.md` (NEW).
- `internal/dashboard/testdata/parsers/coder/golden.md` (NEW).
- `internal/dashboard/testdata/parsers/reviewer/golden.md` (NEW).
- `internal/dashboard/testdata/parsers/runs/metrics.jsonl` (NEW).
- `internal/dashboard/testdata/parsers/runs/RUN_SUMMARY_20260402_120000.json` (NEW).
- `internal/dashboard/testdata/parsers/runs/RUN_SUMMARY_20260402_130000.json` (NEW).
- `cmd/tekhton/dashboard_parse.go` (NEW) — 5 Cobra arms.
- `cmd/tekhton/dashboard_parse_test.go` (NEW) — smoke tests.

### Go — modified
- `internal/proto/dashboard_v1_extra.go` — `DashboardRunSummary` + `DashboardRunSummaryStage` shapes match bash output; `DashboardMetricsV1.MarshalJSON` emits `[]` for nil.
- `internal/proto/dashboard_v1_test.go` — round-trip tests for parse-side structs.
- `internal/dashboard/emit.go` — `reader *StatusReader` field + `statusReader()` accessor; `NewEmitter` constructs reader.
- `internal/dashboard/emit_security.go` — body collapsed to `e.statusReader().ParseSecurity(...)`.
- `internal/dashboard/emit_reports.go` — Intake/Coder/Reviewer parsers replaced with StatusReader calls; per-team fan-out updated similarly. `parseTestAudit` stays inline (no equivalent bash dedicated parser).
- `internal/dashboard/emit_metrics.go` — body collapsed to `e.statusReader().ParseRunSummaries(...)`.
- `cmd/tekhton/dashboard.go` — registers `newDashboardParseCmd()` under the parent.

### Bash — deleted
- `lib/dashboard_parsers.sh` (165 lines)
- `lib/dashboard_parsers_runs.sh` (285 lines)
- `lib/dashboard_parsers_runs_files.sh` (105 lines)

### Bash — modified
- `lib/dashboard_shim.sh` — removed `source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"` line.
- `lib/diagnose_output_extra.sh` — inlines `_diagnose_write_js_file` (replaces deleted `_write_js_file`); diagnose writer call updated.
- `lib/common.sh` — comment update; no behavior change.
- `tekhton-legacy.sh` — removed `dashboard_parsers.sh` source line from the `--diagnose` early-exit branch.

### Tests — created (NEW)
- `tests/test_dashboard_parse_parity.sh` (NEW) — 7-scenario parity gate (24 jq assertions).

### Tests — modified
- `tests/test_diagnose.sh` — `_write_js_file` mock renamed to `_diagnose_write_js_file`.
- `tests/test_nonblocking_log_fixes.sh` — Fix #20 updated to assert shim execs Go binary instead of sourcing parser.
- `tests/test_intake_report_rendering.sh` + 9 others — SKIP banner inserted after `set -euo pipefail`.

### Docs
- `docs/v4-phase5-stub.md` — row #4 (dashboard subsystem) flipped to done; 1547 LOC removed across m33 arc noted; m33.2 read-side highlights captured.

## Docs Updated
- `docs/v4-phase5-stub.md` — dashboard subsystem row done; m33 arc closeout note. The dashboard is internal/developer surface (Hidden Cobra subcommand) — no user-facing README, USAGE.md, or `docs/` page references the parser surface that needs updating.

## Human Notes Status

No applicable items in HUMAN_NOTES.md. The Clarifications block at the top of
the intake prompt contained Q&A pairs from prior unrelated runs (Watchtower
component questions, NON_BLOCKING_LOG questions, --init/--plan flow
confusion). None of them bear on the m33.2 implementation scope, which is a
pure Bash→Go port of the dashboard read side.

## Architecture Change Proposals

None. m33.2 is a Ship-of-Theseus port of the dashboard read side. No layer
boundaries crossed, no new contract dependencies introduced. The `StatusReader`
type extends the existing `Emitter` (which constructs and stores one) so the
emit path uses a one-way reference rather than introducing a circular
dependency. The deletion of `lib/dashboard_parsers*.sh` follows the wedge
discipline of CLAUDE.md Rule 9: when a Go wedge lands, the corresponding bash
either deletes or shims, never co-runs.

## Observed Issues (out of scope)

- `lib/diagnose_output_extra.sh::emit_dashboard_diagnosis` is now bash-self-
  contained (uses inline `_diagnose_write_js_file`) but the Go side has
  `EmitDiagnosis` doing the same job from a different input source
  (`LAST_FAILURE_CONTEXT.json`). Two write paths exist for `data/diagnosis.js`;
  consolidation can happen in a follow-up cleanup milestone.
- `lib/metrics_dashboard.sh` (the `summarize_metrics` bash CLI summary printer
  referenced in the milestone "Watch For" as still-bash) is still bash and
  unchanged by this milestone — out of scope per spec.

## Remaining Work

None — all 12 planned tasks complete. The bash test suite (499 tests) and Go
test suite both pass; the m33.1 emit parity gate (26 assertions), the new
m33.2 parse parity gate (24 assertions), and `tests/test_m33_milestone_structure.sh`
(28 assertions) all pass against the local binary.
