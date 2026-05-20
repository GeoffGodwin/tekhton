# Bucket A Audit — planning phase

Audited 39 tests. Verdict counts: KEEP=39, DELETE-STALE=0, PORT-TO-GO=0, NEEDS-REVIEW=0.

The planning subsystem (`lib/plan*.sh`, `lib/replan*.sh`, `stages/plan_*.sh`,
`prompts/plan_*.prompt.md`) is fully bash. No Go package under `internal/`
duplicates planning logic — `grep -l 'plan_interview|plan_generate|run_plan|_call_planning' internal/**/*.go`
returns empty. The two indirect Go-side dependencies these tests touch
(`lib/prompts.sh` m15 shim and `lib/milestone_dag*.sh` m13/m14 shims) are
called through their public bash API, so the tests now exercise the Go
binary via the shim — an integration-test bonus, not a stale concern.

## Verdicts

| Test | Verdict | Reason |
|---|---|---|
| test_plan_answers.sh | KEEP | Exercises `lib/plan_answers.sh` `_yaml_escape_dq`/`_yaml_unescape_dq` round-trip — live bash. |
| test_plan_answers_completeness.sh | KEEP | Exercises answer-file completeness checks in `lib/plan_answers.sh` + `lib/plan.sh` — live bash. |
| test_plan_answers_import_guard.sh | KEEP | Exercises `import_answer_file` template-overwrite guard in `lib/plan_answers.sh` — live bash. |
| test_plan_browser.sh | KEEP | Self-skip placeholder for the HTML-escape regression deferred to m26 plan-browser Go port; `lib/plan_browser.sh` still exists as live bash. |
| test_plan_codebase_summary.sh | KEEP | Exercises `_generate_codebase_summary` in `lib/replan_brownfield.sh` — live bash. |
| test_plan_completeness.sh | KEEP | Exercises `_is_section_incomplete` + `check_design_completeness` in `lib/plan_completeness.sh` — live bash. |
| test_plan_completeness_loop.sh | KEEP | Exercises `run_plan_completeness_loop` orchestration in `lib/plan_completeness.sh` — live bash. |
| test_plan_config_defaults.sh | KEEP | Exercises planning config defaults in `lib/plan.sh` — live bash. |
| test_plan_config_loader.sh | KEEP | Exercises M121 empty-slate self-heal in `lib/plan.sh` + `lib/artifact_defaults.sh` — live bash. |
| test_plan_config_loading.sh | KEEP | Exercises pipeline.conf override of plan vars in `lib/plan.sh` — live bash. |
| test_plan_constants.sh | KEEP | Exercises `PLAN_PROJECT_TYPES`/`PLAN_PROJECT_LABELS` constants in `lib/plan.sh` — live bash. |
| test_plan_design_generation.sh | KEEP | Exercises `_call_planning_batch` `--dangerously-skip-permissions` flag in `lib/plan_batch.sh` — live bash. |
| test_plan_docs_section.sh | KEEP | Exercises Documentation Strategy REQUIRED marker via `lib/plan_completeness.sh` + `templates/plans/*.md` — live bash. |
| test_plan_empty_slate.sh | KEEP | Exercises M121 `--init` → `--plan` self-heal via `lib/plan.sh` + `stages/plan_interview.sh` — live bash. |
| test_plan_generate_integration.sh | KEEP | Exercises `run_plan_generate` post-processing in `stages/plan_generate.sh` — live bash. |
| test_plan_generate_marker_idempotency.sh | KEEP | Exercises `run_plan_generate` pointer-marker idempotency in `stages/plan_generate.sh` — live bash. |
| test_plan_generate_preamble_trim.sh | KEEP | Exercises `_trim_document_preamble` in `stages/plan_generate.sh` — live bash. |
| test_plan_generate_prompt.sh | KEEP | Greps `prompts/plan_generate.prompt.md` for required section headings — prompt file is live. |
| test_plan_generate_stage.sh | KEEP | Exercises `run_plan_generate` log creation + exit codes in `stages/plan_generate.sh` — live bash. |
| test_plan_generate_tool_write_guard.sh | KEEP | Exercises tool-write guard in `stages/plan_generate.sh` — live bash. |
| test_plan_interview_preamble_trim.sh | KEEP | Exercises `_trim_document_preamble` in `stages/plan_interview.sh` — live bash. |
| test_plan_interview_prompt.sh | KEEP | Renders `prompts/plan_interview.prompt.md` via `render_prompt`; now an integration test against the m15 Go template engine — still meaningful. |
| test_plan_interview_stage.sh | KEEP | Exercises `run_plan_interview` log/exit/DESIGN.md handling in `stages/plan_interview.sh` — live bash. |
| test_plan_interview_tool_write_guard.sh | KEEP | Exercises tool-write guard in `stages/plan_interview.sh` — live bash. |
| test_plan_milestone_review_pattern.sh | KEEP | Exercises `_display_milestone_summary` regex in `lib/plan_milestone_review.sh` — live bash. |
| test_plan_permission_request_rejection.sh | KEEP | Exercises permission-request rejection in `lib/plan_batch.sh` — live bash. |
| test_plan_phase_context.sh | KEEP | Exercises `_build_phase_context` in `stages/plan_interview.sh` — live bash. |
| test_plan_phase_transitions.sh | KEEP | Exercises phase-header firing in `run_plan_interview` (`stages/plan_interview.sh`) — live bash. |
| test_plan_replan_done_milestones.sh | KEEP | Exercises `_apply_brownfield_delta` `[DONE]` preservation in `lib/replan_brownfield_apply.sh` — live bash. |
| test_plan_resume_flow.sh | KEEP | Exercises `write_plan_state`/`clear_plan_state` resume boundaries in `lib/plan_state.sh` — live bash. |
| test_plan_review.sh | KEEP | Exercises completeness display in `lib/plan_review.sh` — live bash. |
| test_plan_review_functions.sh | KEEP | Exercises milestone-review helpers in `lib/plan_milestone_review.sh`; pulls in milestone_dag shims but exits via the public bash query API. |
| test_plan_review_loop.sh | KEEP | Exercises milestone review loop in `lib/plan_milestone_review.sh` — live bash. |
| test_plan_state_clear.sh | KEEP | Exercises `clear_plan_state` in `lib/plan_state.sh` — live bash. |
| test_plan_state_resume_offer.sh | KEEP | Exercises `_offer_plan_resume` in `lib/plan_state.sh` — live bash. |
| test_plan_state_write_read.sh | KEEP | Exercises `write_plan_state`/`read_plan_state` round-trip in `lib/plan_state.sh` — live bash. |
| test_plan_templates.sh | KEEP | Greps `templates/plans/*.md` for REQUIRED-marker counts — template files are live. |
| test_plan_trap_restore.sh | KEEP | Exercises trap save/restore in `_call_planning_batch` (`lib/plan_batch.sh`) — live bash. |
| test_plan_type_selection.sh | KEEP | Exercises `select_project_type` in `lib/plan.sh` — live bash. |

## Coverage gaps noted

- `test_plan_browser.sh` is a self-skip stub waiting on the m26 Go port of
  `lib/plan_browser.sh`; the underlying HTML-escape regression remains
  unfixed and there is no parity test on the Go side yet. Flag for the
  m26 port author.
- The DRIFT_LOG notes that V4 migration is accumulating skip-guarded bash
  tests faster than Go replacements; `test_plan_browser` is the only
  bucket-A example, but the pattern is worth tracking.
- `lib/replan.sh` is a 20-line dispatcher; tests reference `lib/replan.sh`
  in comments but actually exercise functions defined in
  `lib/replan_brownfield*.sh` and `lib/replan_midrun.sh`. Comments are
  stale but tests are accurate — cosmetic only.
- No test exercises `lib/plan_server.sh` / `lib/plan_server_script.sh`
  (the browser-planning HTTP layer). Coverage gap noted for the m26 port.
