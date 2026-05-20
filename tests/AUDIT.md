# Test Suite Audit — 2026-05-20

Audit of 508 bash tests + 82 Go test files, conducted by 13 subagents across
3 batches. Methodology and per-bucket reports under `tests/audit/`.

## Headline

| Verdict | Count | Action |
|---|---|---|
| KEEP | 466 | Exercising live bash that hasn't been ported. No action. |
| DELETE-STALE | 20 | Bash target file deleted or shimmed AND Go has its own coverage. **Safe to remove.** |
| PORT-TO-GO | 5 | Behavior still matters; should re-land as Go test. |
| NEEDS-REVIEW | 16 | Policy question. Two clusters; needs human decision before action. |
| **Total** | **507** | One test counted twice (see note below) |

> Note: agent E reported 2 PORT-TO-GO but only one entry (`test_preflight_parity.sh`) appears in its table. I'm treating that as a counting error in the bucket header — actual PORT total is 5.

Go suite: no stale, one cosmetic NEEDS-REVIEW (`internal/version` has 6 trivial tests for `strings.TrimSpace` — mergeable), zero WIP skips.

## DELETE-STALE — 20 tests safe to remove

All have positive evidence (target file deleted/shimmed AND Go covers the contract).

### Already self-documenting skip-stubs (9)
These are `exit 0` placeholders left in place to preserve the test count. Removing them is purely cosmetic but they cost real test runtime via the harness wrapping them.

| Test | Reason |
|---|---|
| `test_preflight.sh` | m22 — superseded by `internal/preflight/*_test.go` |
| `test_preflight_infer_degenerate.sh` | m22 — `_pf_infer_from_compose` helper deleted; covered by `services_infer_test.go` |
| `test_preflight_ui_config.sh` | m22 — `lib/preflight_checks_ui.sh` deleted; covered by `ui_audit_test.go` |
| `test_m118_preflight_deferred_emit.sh` | m22 — preflight bash deleted |
| `test_m131_coverage_gaps.sh` | m22 — UI audit moved to `internal/preflight` |
| `test_m132_run_summary_enrichment.sh` | Auto-skips when `lib/finalize_summary.sh` absent (which it is) |
| `test_m34_data_fidelity.sh` | Same — `lib/finalize_summary.sh` absent |
| `test_finalize_summary_escaping.sh` | `lib/finalize_summary.sh` deleted m21; Go covers via `emit_run_summary_test.go` |
| `test_finalize_summary_tester_guard.sh` | Same as above |

### Targets a shim or deleted file, full Go coverage exists (11)

| Test | Reason |
|---|---|
| `test_timing_cache_hits_display.sh` | `lib/timing.sh` is **orphan dead code** (zero sourcers); Go owns it via `internal/finalize/emit_timing_report.go` |
| `test_timing_deadcode_removal.sh` | Same — dead `lib/timing.sh` |
| `test_timing_repo_map_stats.sh` | Same — dead `lib/timing.sh` |
| `test_timing_report_generation.sh` | Same — superseded by `internal/finalize/emit_timing_report_test.go` |
| `test_archive_reports_behavior.sh` | `archive_reports` ported to `internal/finalize/archive_reports.go` with its own test; no bash callers remain |
| `test_causal_log.sh` | `lib/causality.sh` is m02 shim; `internal/causal/log_test.go` has 19 test funcs |
| `test_errors.sh` | `lib/errors.sh` is m17 shim (pure passthrough to `tekhton diagnose`); `internal/errors` has 6 test files |
| `test_error_patterns.sh` | Same — m17 shim |
| `test_classify_errors_dedup.sh` | Same — m17 shim; `classify_test.go` has 19 funcs |
| `test_config_defaults_claude_standard_model.sh` | `lib/config_defaults.sh` is 45-line m16 shim; `TestDefaults_Derived` covers in Go |
| `test_config_defaults_dedup.sh` | Same — m16 shim; original 250-line file is gone |

### Companion file cleanup recommended

`lib/timing.sh` itself is orphan dead code (no sourcers anywhere in `lib/`, `stages/`, or `tekhton*.sh`). Delete the file alongside the 4 timing tests above. The `_phase_start`/`_phase_end` runtime helpers in `lib/common_timing.sh` are the live timing code and remain sourced.

## PORT-TO-GO — 5 tests where behavior moved but Go coverage is incomplete

| Test | Where to port |
|---|---|
| `test_preflight_parity.sh` | The m22 golden-file parity gate. Should live under `internal/preflight/` or `cmd/tekhton/` using existing `testdata/preflight_parity` fixtures. Functional today but won't survive Phase 5 (no `.sh` files). |
| `test_milestone_dag.sh` | Most behaviors covered by `internal/dag/{validate,migrate}_test.go`; port the gap-fillers (`dag_id_to_number` / `dag_number_to_id` round-trip) and drop. |
| `test_milestone_dag_migrate.sh` | Mostly duplicates `internal/dag/migrate_test.go`; verify parity, then drop. |
| `test_out_complete.sh` | `out_complete` + `_hook_tui_complete` are reduced shims post-m21; M111 wrap-up-pill invariants belong in `internal/finalize/orchestrator_test.go` or `internal/tui/sidecar_test.go`. |
| `test_pin_version_validation.sh` | `TEKHTON_PIN_VERSION` semver validation lives in `internal/config/validate.go`. Confirm `internal/config/config_test.go` covers invalid-pin warning + reset behavior, then port. |

## NEEDS-REVIEW — 16 tests, 4 policy questions

These tests aren't strictly stale but their fate depends on decisions you should make.

### Policy Q1: inline-mode milestone archival (4 tests)

Bash `lib/milestone_archival.sh` (221 lines) handles **both** inline-mode and DAG-mode archival. Go `internal/finalize/archive_milestone.go` only ports DAG mode and explicitly skips inline.

Per V4 §"V4 wedges remove the bash they replace", should inline-mode bash archival be deleted? If yes, all 4 tests below become DELETE-STALE after the corresponding bash logic is removed.

- `test_milestone_archival.sh`
- `test_milestone_archival_dag_rearchive.sh`
- `test_milestone_archival_number_reuse_edge.sh`
- `test_milestone_dag_archival_metadata.sh`

### Policy Q2: orchestrate tests (4 tests)

The bash `lib/orchestrate_*.sh` files contain real logic (NOT shims) and are still callable from `tekhton-legacy.sh:3031,3048` via the legacy `--complete` path. Go (`internal/orchestrate/`) covers the same routing.

These tests stay KEEP-ish until Phase 5 ports `--complete` to dispatch through `tekhton run --complete`, at which point all 4 can be batch-removed alongside the entire `lib/orchestrate_*.sh` tree (orchestrate_classify.sh 257L, orchestrate_complete.sh 212L, orchestrate_iteration.sh 286L, etc.).

- `test_orchestrate.sh`
- `test_orchestrate_integration.sh`
- `test_orchestrate_m12_acceptance.sh`
- `test_orchestrate_recovery.sh`

### Policy Q3: shim-boundary tests (5 tests)

These tests source one or more V4 wedge shims alongside live bash. They still run through the shim's call-through path, but their value is unclear:

| Test | Concern |
|---|---|
| `test_m111_dag_split_bugs.sh` | Mixes m14 DAG shim with live split logic |
| `test_m111_downstream_dep_unblock.sh` | Same — documents a known-broken downstream contract |
| `test_mark_milestone_done.sh` | Mixes m03 state shim + m14 DAG shim + live milestones |
| `test_orch_record_save_state.sh` | Mixes m03 state shim + live orchestrate_aux (m12/m19 boundary) |
| `test_gates_stale_raw_errors.sh` | Mixes live build gate with m17-shimmed error classification |

Decision needed: do shim-boundary integration tests provide enough value as smoke layers to keep, or are they noise to be retired once Go-side coverage is confirmed? `test_pin_version_validation.sh` (above, PORT-TO-GO) is a model of the "good" shim-end-to-end pattern.

### Policy Q4: cosmetic / misnamed (3 tests)

- `test_preflight_fix.sh` — **Misnamed.** Actually tests `lib/orchestrate_preflight.sh::_try_preflight_fix` (live orchestrate-loop logic), NOT the deleted m22 preflight env scanner. Rename to avoid the confusion, OR rewrite to drive the Go config binary directly (currently fragile — asserts bash-defined `PREFLIGHT_FIX_*` defaults that now come from Go).
- `test_prompt_rendering.sh` — Go `internal/prompt/prompt_test.go` covers the engine thoroughly; bash test only exercises the shim's variable-export path. Keep as smoke or delete?
- `test_worktree_gitignore_coverage.sh` — Validates a `.gitignore` pattern not clearly tied to any current V4 subsystem. Confirm whether worktrees are still produced anywhere.

### `internal/version` (Go-side, NEEDS-REVIEW)

`internal/version/version_test.go` has 6 tests for `strings.TrimSpace(Version)`. Three trim-whitespace variants could be one table-driven test. Cosmetic; bundle with any future tidy pass.

## Vestigial self-skips noted (not in DELETE count)

Bucket G flagged 4 `run_memory_*` tests that already self-skip when `lib/run_memory.sh` is missing (m21 deleted it). They're harmless no-ops in the current suite but vestigial — parity coverage lives in `internal/finalize/emit_run_memory_test.go`.

- `test_run_memory_emission.sh`
- `test_run_memory_keyword_filter.sh`
- `test_run_memory_pruning.sh`
- `test_run_memory_special_chars.sh`

These could go in the same sweep as the DELETE-STALE list. Not classified DELETE-STALE because their skip-guards make them safe to leave; agent was being conservative.

## Coverage gaps surfaced

### Bash-side gaps
1. **`lib/plan_server.sh` / `lib/plan_server_script.sh`** — browser-planning HTTP layer, no tests. Flag for m26 port author.
2. **`lib/dashboard_parsers_runs_files.sh`** — only transitively covered via delegation; no targeted unit test.
3. **`out_complete` / `out_reset_pass` in `lib/output.sh`** — uncovered by existing output-bus tests.
4. **`lib/milestone_metadata.sh`** (250L) and **`lib/milestone_progress_helpers.sh`** (218L) — no direct tests.
5. **`lib/detect_doc_quality.sh`** — only coarse high/low score sanity check; breakdown format that `_INIT_DOC_QUALITY` consumers depend on is not asserted.
6. **`lib/detect_workspaces.sh`** — `settings.gradle.kts` (Kotlin-DSL) workspace enumeration not covered, only Groovy path.

### Go-side gaps
1. **`internal/manifest`** — external-writer concurrency between Load and Save; reader-concurrency is covered but not last-writer-wins under external mutation.
2. **`internal/prompt`** — no test for template self-reference cycle detection (recursive `{{IF:X}}` expansion). Probably impossible by design, but worth a confirming test.
3. **`internal/orchestrate`** — `envGateRetried = true` second-attempt path through a fresh `Loop` instance via `SetEnvGateRetried` is only proved by a setter test, not an attempt run.
4. **`internal/supervisor/quota_test.go`** — no regression test for `QUOTA_MAX_PAUSE_DURATION` exceeded mid-pause (M125 hard-cap path).
5. **`internal/runner/hooks_test.go:TestBashHookRunnerFinalizeSkipsMissingScript`** — assertion is weak (returns nil, doesn't verify which hooks ran).
6. **`internal/config`** — drift defaults (`DRIFT_LOG_FILE`, `DRIFT_OBSERVATION_THRESHOLD`, `DRIFT_RUNS_SINCE_AUDIT_THRESHOLD`) not directly asserted; survived only because `test_drift_config.sh` exercises them via the shim.

### Cross-language gaps
1. **`tui_status.json` schema parity** — Go's `initialStatus` struct vs bash's `_tui_json_build_status` could drift silently. No integration test on either side asserts the handoff envelope's field set matches what the bash mid-run writers expect.
2. **m17 routing-decision token vocabulary** — only `test_error_patterns_classify_threshold.sh` asserts the contract. Mirror into `internal/errors` so the shim can eventually be deleted.
3. **m26 `EnvBuilder.AsKV` contract** — `test_v4_env_contract.sh` is the *only* bash-layer enforcement. No Go-side integration test crosses back into bash readers.

## Structural debt noted in passing

- **`lib/indexer.sh`** is at 299 lines — one byte from tripping `test_indexer_line_ceiling.sh` (300-line bash ceiling). Any change will need extraction.
- **`lib/health.sh`** is 441 lines — well over the 300-line ceiling. No Go counterpart. Flag for either extraction or a V5 port milestone.
- The DRIFT_LOG notes an accumulation of skip-guarded bash tests deferred to future V4 ports. The deletes above clear 9 of these; the orchestrate cluster (Policy Q2) is the next four.

## Recommended next steps

1. **Quick wins (low risk, high signal cleanup):**
   - Delete the 20 DELETE-STALE tests + `lib/timing.sh` itself.
   - Delete the 4 vestigial `run_memory_*` self-skips.
   - Rename `test_preflight_fix.sh` to `test_orchestrate_preflight_fix.sh`.
   - **Net: 24 test files removed, 1 lib file removed.**

2. **Policy decisions** before further deletion:
   - Q1 (inline archival): decide whether bash inline-mode archival stays or goes.
   - Q2 (orchestrate): noted as Phase 5 work — no action this cycle.
   - Q3 (shim-boundary): decide on shim-smoke-layer policy as a class.

3. **Coverage backfill priorities** (ranked by risk):
   - tui_status.json cross-language schema parity (cross-language drift is invisible).
   - `internal/orchestrate` envGateRetried second-attempt path (recovery-correctness).
   - m17 routing-decision token vocabulary mirror to Go (blocks shim deletion).
   - Drift defaults assertions in `internal/config`.

4. **Ports queued for upcoming milestones:**
   - `test_preflight_parity.sh` → Go integration test in `internal/preflight`.
   - Plan-browser tests when m26 lands (`test_plan_browser.sh` HTML-escape regression still open).
