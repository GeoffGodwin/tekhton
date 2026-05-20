# Bucket I Audit — human mode, notes pipeline, docs agent

Audited 23 tests. Verdict counts: KEEP=23, DELETE-STALE=0, PORT-TO-GO=0, NEEDS-REVIEW=0.

The three subsystems in this bucket are entirely bash and have not been
touched by V4:

- **Notes pipeline.** `lib/notes_core.sh` (10k), `lib/notes_cli.sh` (8k),
  `lib/notes_cli_write.sh` (6k), `lib/notes_single.sh` (7.5k),
  `lib/notes.sh` (6.7k), `lib/notes_acceptance.sh` (8.5k),
  `lib/notes_acceptance_helpers.sh` (3.5k), `lib/notes_cleanup.sh` (5.3k),
  `lib/notes_core_normalize.sh` (1.7k), `lib/notes_migrate.sh` (4.2k),
  `lib/notes_rollback.sh` (2.6k), `lib/notes_triage*.sh` (~16k combined).
  All real logic, none are shims.
- **Human mode** runtime glue. The notes_* family above plus
  `lib/intake_helpers.sh` (10.5k) and the `--human` arg parser inside
  `tekhton-legacy.sh` (still bash; `tekhton.sh` is just a dispatcher that
  forwards run-flags to Go and everything else to the legacy script).
- **Docs agent.** `lib/docs_agent.sh` (5.8k) and `stages/docs.sh` (3.4k) —
  Haiku-powered optional stage. All real logic.

Two tests have incidental dependencies on V4 wedge shims, but in both cases
the dependency is via a stable bash API the shim keeps callable:

- `test_human_mode_resolve_notes_edge.sh` sources `lib/finalize.sh`
  (m21 shim) to exercise `_hook_resolve_notes`. The hook body lives in
  `lib/finalize_core_hooks.sh:59`, which is sourced from `finalize.sh` for
  exactly this reason — bash callers still see the function defined. Real
  bash logic, not a Go duplicate.
- `test_human_mode_state_resume.sh` sources `lib/state.sh` (m03 shim) and
  `lib/errors.sh` (m17 shim). `state.sh:_build_resume_flag` is still a pure
  bash function defined in the shim itself. `write_pipeline_state` delegates
  to `_state_write_snapshot` in `lib/state_helpers.sh`, which has both a Go
  path (`tekhton state update`) and a bash-fallback writer
  (`_state_bash_write_fields`) so the test works without the Go binary
  built. The test exercises the bash-side resume-flag construction and JSON
  round-trip, not anything Go-only. `internal/state` covers the Go side
  separately.

## Verdicts

| Test | Verdict | Reason |
|---|---|---|
| test_docs_agent_helpers.sh | KEEP | Exercises `_docs_extract_doc_responsibilities` in `lib/docs_agent.sh` — live bash. |
| test_docs_agent_pipeline_order.sh | KEEP | Exercises `get_pipeline_order`/`get_stage_position`/`should_run_stage` in `lib/pipeline_order.sh` (9.5k, live) with `DOCS_AGENT_ENABLED` toggling. |
| test_docs_agent_skip_path.sh | KEEP | Exercises `docs_agent_should_skip` in `lib/docs_agent.sh` — live bash. |
| test_docs_agent_stage_smoke.sh | KEEP | Exercises `run_stage_docs` in `stages/docs.sh` with mocked `run_agent` — live bash stage. |
| test_docs_site.sh | KEEP | Greps `docs/`, `mkdocs.yml`, `.github/workflows/docs.yml`, and `tekhton-legacy.sh` (live) for documentation-site deliverables. |
| test_docs_structure.sh | KEEP | Greps the same documentation-site deliverables; runs `tekhton.sh --docs` which falls through the dispatcher to `tekhton-legacy.sh --docs` (live). |
| test_human_action_consolidation.sh | KEEP | Exercises `consolidate_legacy_human_action` in `lib/drift.sh` + `lib/drift_artifacts.sh` (both ~11k, live) — HUMAN_ACTION_REQUIRED.md migration. |
| test_human_complete_loop_resets.sh | KEEP | Exercises `tui_reset_for_next_milestone` in `lib/tui_ops.sh` and `out_reset_pass` mock — TUI bash glue still live. |
| test_human_flag_arg_parser.sh | KEEP | Re-implements the `--human [TAG]` parser inline and asserts BUG/FEAT/POLISH tag consumption; mirrors the parser still in `tekhton-legacy.sh`. |
| test_human_mode_crash_resume.sh | KEEP | Exercises `pick_next_note`/`extract_note_text`/`claim_single_note` in `lib/notes*.sh` for the [~] crash-recovery guard — live bash. |
| test_human_mode_orchestration.sh | KEEP | Exercises `pick_next_note`/`claim_single_note`/`resolve_single_note`/`count_unchecked_notes` in `lib/notes*.sh` — live bash. |
| test_human_mode_resolve_notes_edge.sh | KEEP | Exercises `_hook_resolve_notes` in `lib/finalize_core_hooks.sh:59` (sourced by m21 shim `lib/finalize.sh`) — bash hook body still live. |
| test_human_mode_state_resume.sh | KEEP | Exercises `_build_resume_flag` (pure bash in m03 shim `lib/state.sh`) and `write_pipeline_state` via bash-fallback writer in `lib/state_helpers.sh`; covers human-mode resume metadata that lives in the bash callers. |
| test_human_notes_lifecycle.sh | KEEP | Exercises `count_human_notes`/`extract_human_notes`/`claim_human_notes`/`resolve_human_notes` in `lib/notes.sh` — live bash. |
| test_human_orchestration_bounds.sh | KEEP | Exercises `MAX_PIPELINE_ATTEMPTS` loop bound (re-implemented inline) + `--human`/`--milestone` flag validation in `tekhton-legacy.sh` (live). |
| test_human_workflow.sh | KEEP | Broad coverage of `_section_for_tag`/`pick_next_note`/`claim_single_note`/`resolve_single_note`/`extract_note_text`/`count_unchecked_notes` in `lib/notes_single.sh` + `_hook_resolve_notes` integration — all live bash. |
| test_notes_acceptance.sh | KEEP | Exercises `check_bug_acceptance`/`check_polish_acceptance`/`check_feat_acceptance`/`should_skip_review_for_polish`/`run_note_acceptance` in `lib/notes_acceptance*.sh` — live bash. |
| test_notes_cli.sh | KEEP | Exercises `get_notes_summary`/`add_human_note` in `lib/notes_cli.sh` + `lib/notes_cli_write.sh` — live bash. |
| test_notes_cli_printf.sh | KEEP | Asserts `printf '%b'` behavior used by `lib/notes_cli_write.sh:143` for ANSI-color prompts — guards a portability fix in live bash. |
| test_notes_migrate_no_heading.sh | KEEP | Exercises `migrate_legacy_notes` in `lib/notes_migrate.sh` for the v1→v2 no-heading edge case — live bash. |
| test_notes_normalization.sh | KEEP | Exercises `_normalize_markdown_blank_runs` (M73) in `lib/notes_core_normalize.sh` + `clear_completed_human_notes` in `lib/notes.sh` — live bash. |
| test_notes_rollback.sh | KEEP | Exercises `snapshot_note_states`/`restore_note_states`/`claim_note` in `lib/notes_core.sh` + `lib/notes_rollback.sh` — live bash. |
| test_notes_triage.sh | KEEP | Exercises `_triage_heuristic_score`/`triage_note`/`run_triage_report`/`triage_bulk_warn`/`promote_note_to_milestone` in `lib/notes_triage*.sh` — live bash. |

## Coverage gaps noted

- `test_docs_site.sh` and `test_docs_structure.sh` overlap heavily — both
  enumerate the same `docs/**` files, the same `mkdocs.yml` fields, and the
  same workflow steps. Not a staleness issue, just redundancy worth folding
  someday.
- `test_human_flag_arg_parser.sh` and `test_human_workflow.sh` Section 10
  both re-implement the `--human` flag-validation logic inline rather than
  invoking the parser in `tekhton-legacy.sh`. `test_human_orchestration_bounds.sh`
  Tests 4–5 actually subprocess `tekhton-legacy.sh` and assert exit codes —
  that is the real coverage; the inline re-implementations could drift
  silently if `tekhton-legacy.sh` changes.
- No Go-side test was found for the m21 `finalize_run` bash shim's
  fallback-when-binary-missing path (`lib/finalize.sh:31-48`). `internal/finalize`
  covers the Go orchestrator but not the bash shim's graceful degradation.
  Not in scope for this bucket; noting it because it surfaced while
  cross-referencing the resolve-notes test.
