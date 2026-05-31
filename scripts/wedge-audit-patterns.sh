#!/usr/bin/env bash
# scripts/wedge-audit-patterns.sh — pattern table for scripts/wedge-audit.sh.
#
# Extracted from wedge-audit.sh per CLAUDE.md Rule 8 (data-only exemption):
# this file contains a single array assignment, no function bodies, and no
# conditional logic. The audit script sources it after declaring the
# allowlist.
#
# Each pattern targets a known direct-write shape. Patterns are deliberately
# loose (they err toward catching, not toward false negatives) — any false
# positive can be added to the allowlist with a justification.
#
# 1. `>>` or `>` redirection into the wedge-owned path variables.
# 2. `mv …` into the wedge-owned path variables (atomic-write completion).
# 3. In-process counter assignments that Go now owns.
# 4. m10 cutover: inline `python3 -c "...json..."` parses anywhere in lib/ —
#    the supervisor wedge replaced these with structured agent.response.v1
#    fields. Multi-line python3 invocations are caught by an additional
#    pass below that scans for `python3 -c "$` followed by `import json`.
# 5. m10 cutover: a regression here would be a re-introduction of one of
#    the deleted bash supervisor files. We can't grep for the absence of
#    a file, but we can flag any source line that names one.

# shellcheck disable=SC2034  # PATTERNS is consumed by wedge-audit.sh after sourcing.
PATTERNS=(
    # Redirection (append or overwrite) into the variable.
    '>[[:space:]]*"?\$\{?CAUSAL_LOG_FILE\b'
    '>[[:space:]]*"?\$\{?PIPELINE_STATE_FILE\b'
    # mv/cp tmpfile into the path.
    '\b(mv|cp)[[:space:]].*"?\$\{?CAUSAL_LOG_FILE\b'
    '\b(mv|cp)[[:space:]].*"?\$\{?PIPELINE_STATE_FILE\b'
    # In-process counters owned by the Go side.
    '^[[:space:]]*_LAST_EVENT_ID='
    '^[[:space:]]*_CAUSAL_EVENT_COUNT='
    # m10: single-line inline JSON parses via python.
    'python3[[:space:]]+-c[[:space:]].*json'
    # m10: re-source of any deleted bash supervisor module. Anchored on the
    # `source`/`.` builtin so comments documenting the m10 cutover (which
    # legitimately name the files) don't trip the audit.
    '^[[:space:]]*(source|\.)[[:space:]]+.*/(agent_monitor[^"[:space:]]*|agent_retry[^"[:space:]]*)'
    # m12 (Phase 4): regression guard against re-introducing the round-trip
    # orchestrate-globals pair that lib/agent.sh used to populate. The
    # orchestrate loop now reads supervisor results through LAST_AGENT_*
    # directly; a re-introduction would silently re-instate the bash↔Go
    # round-trip the m12 wedge eliminated.
    '^[[:space:]]*export[[:space:]]+_RWR_'
    '^[[:space:]]*_RWR_[A-Z_]+='
    # m12 (Phase 4): direct `tekhton supervise` calls outside the agent shim
    # bypass the orchestrate-loop recovery dispatch. Only lib/agent.sh and
    # lib/agent_shim.sh (allowlisted above) may shell to it. lib/orchestrate.sh
    # would be a regression — orchestrate now consumes the supervisor result
    # via the shim, never directly. Patterns are literal regex strings; the
    # `[$]` character class matches a literal `$` without tripping shellcheck
    # SC2016 (the equivalent `\$` form in single-quotes would).
    '"[$]_bin"[[:space:]]+supervise'
    "'tekhton'[[:space:]]+supervise"
    # m18 (Phase 4 batch 2): the per-attempt scheduler and build/completion
    # gates moved to internal/pipeline. Hand-rolled bash JSON envelopes for
    # tekhton.stage.result.v1 outside lib/stage_envelope.sh would fork the
    # contract — emit_stage_envelope is the only authorized writer.
    '"proto":[[:space:]]*"tekhton\.stage\.result\.v1"'
    # m19 (Phase 4 batch 2): the outer retry loop and run-level save-state
    # writer moved to internal/runner. The legacy bash function names
    # (run_complete_loop, _save_orchestration_state) and the deleted file
    # paths (orchestrate_main.sh, orchestrate_state.sh) must not reappear in
    # lib/ or stages/.
    '\brun_complete_loop\b'
    '\b_save_orchestration_state\b'
    'orchestrate_main\.sh'
    'orchestrate_state\.sh'
    # m20 (Phase 4 batch 2): the run-level pipeline-stages dispatcher moved
    # to internal/pipeline + internal/runner. The bash entry point body
    # (which used to live in tekhton.sh and called _run_pipeline_stages
    # directly) is now reachable only via tekhton-legacy.sh, which is the
    # transition file Phase 5 absorbs. Re-introducing _run_pipeline_stages
    # in lib/ or stages/ would mean someone is rebuilding the bash
    # orchestrator outside tekhton-legacy.sh — block at audit time.
    '\b_run_pipeline_stages\b'
    # m20: orchestrate_complete.sh and orchestrate_save.sh are bash
    # transition artifacts retained only because tekhton-legacy.sh sources
    # them. New `lib/` files should not source them — the canonical complete
    # loop is internal/runner.RunCompleteLoop. (The wedge-audit allowlist
    # below lets the existing lib/orchestrate*.sh files reference each
    # other; this pattern blocks new sources.)
    '^[[:space:]]*(source|\.)[[:space:]]+.*/orchestrate_complete\.sh'
    '^[[:space:]]*(source|\.)[[:space:]]+.*/orchestrate_save\.sh'
    # m21 (Phase 5): the finalize orchestrator + hook registry moved to
    # internal/finalize.Orchestrator. lib/finalize.sh is the legacy
    # compatibility shim that delegates to `tekhton finalize`; it must not
    # re-introduce register_finalize_hook or the FINALIZE_HOOKS array, and
    # no other lib/ or stages/ file may define them. Catching this at audit
    # time keeps the Go orchestrator the single source of registration
    # truth.
    '\bregister_finalize_hook\b'
    '\bFINALIZE_HOOKS\b'
    # m22 (Phase 5): the preflight subsystem ported to internal/preflight.
    # The six lib/preflight*.sh files were deleted; only the legacy
    # compatibility shim `run_preflight_checks` survives, defined inline
    # in tekhton-legacy.sh and execing `tekhton preflight`. Re-defining
    # any of the six deleted bash function families in lib/ or stages/
    # would silently fork the preflight contract. The internal helper
    # names below were the bash entry points exposed by the deleted
    # files; any reappearance is a regression to be caught at audit.
    '\b_preflight_check_dependencies\b'
    '\b_preflight_check_tools\b'
    '\b_preflight_check_generated_code\b'
    '\b_preflight_check_env_vars\b'
    '\b_preflight_check_runtime_version\b'
    '\b_preflight_check_ports\b'
    '\b_preflight_check_lock_freshness\b'
    '\b_preflight_check_docker\b'
    '\b_preflight_check_services\b'
    '\b_preflight_check_dev_server\b'
    '\b_preflight_check_ui_test_config\b'
    '\b_pf_record\b'
    '\b_pf_try_fix\b'
    '\b_pf_uitest_playwright\b'
    '\b_pf_infer_from_compose\b'
    '\b_PF_REPORT_LINES\b'
    # m23 (Phase 5): the TUI writer subsystem ported to internal/tui/. All
    # six bash files (tui.sh, tui_helpers.sh, tui_liveness.sh, tui_ops.sh,
    # tui_ops_pause.sh, tui_ops_substage.sh) were deleted; the small
    # remaining bash residue (Python sidecar spawn/kill + the `_tui_call`
    # helper that execs `tekhton tui ...`) lives in lib/sidecar_lifecycle.sh.
    # The names below were the bash internal entry points exposed by the
    # deleted files; any reappearance is a regression.
    '\b_tui_json_build_status\b'
    '\b_tui_json_stage\b'
    '\b_tui_recent_events_json\b'
    '\b_tui_check_sidecar_liveness\b'
    '\b_tui_autoclose_substage_if_open\b'
    '\b_tui_alloc_lifecycle_id\b'
    '\b_TUI_RECENT_EVENTS\b'
    '\b_TUI_STAGES_COMPLETE\b'
    '\b_TUI_STAGE_CYCLE\b'
    '\b_TUI_CLOSED_LIFECYCLE_IDS\b'
    # m24 (Phase 5): the notes subsystem ported to internal/notes/. All
    # 14 lib/notes*.sh files were deleted; the small remaining bash
    # residue (line-based helpers for the --human mode loop) lives in
    # lib/human_mode_notes.sh and exec's `tekhton note <subcommand>`.
    # The names below were the bash entry points exposed by the
    # deleted files; any reappearance is a regression — both as a
    # function definition or as a call site.
    '\badd_human_note\b'
    '\bextract_human_notes\b'
    '\bmark_note_done\b'
    '\bclaim_note\b'
    '\bresolve_note\b'
    '\brun_notes_triage\b'
    '\bmigrate_notes_v2\b'
    '\bclaim_human_notes\b'
    '\bresolve_human_notes\b'
    '\bclear_completed_human_notes\b'
    '\bclear_completed_notes\b'
    '\bshould_claim_notes\b'
    '\bcount_human_notes\b'
    '\blist_human_notes_cli\b'
    '\bcomplete_human_note\b'
    '\bclaim_notes_batch\b'
    '\bresolve_notes_batch\b'
    # m25 (Phase 5): the drift, clarify, and failure_context bash
    # subsystems ported to internal/drift/, internal/clarify/, and
    # internal/failure_context/. All seven bash files deleted
    # (lib/drift.sh, lib/drift_artifacts.sh, lib/drift_cleanup.sh,
    # lib/drift_prune.sh, lib/clarify.sh, lib/failure_context.sh, plus
    # the _hook_drift_artifacts body in lib/finalize_core_hooks.sh).
    # The names below were the *load-bearing* bash entry points whose
    # reintroduction in lib/ or stages/ would silently fork the
    # contract — they are detected as either function definitions
    # (`fn_name()`) or direct call sites. Defensive `command -v` /
    # `declare -f` guards for these names are still acceptable
    # transitional state (the bodies they target are gone, so the
    # guards safely no-op). Cobra subcommand files
    # (cmd/tekhton/drift.go, cmd/tekhton/clarify.go) are not scanned —
    # this audit covers lib/ and stages/ only.
    '\bappend_drift_observations\s*\(\)'
    '\bprocess_drift_artifacts\s*\(\)'
    '\bappend_architecture_decision\s*\(\)'
    '\bappend_human_action\s*\(\)'
    '\bdetect_clarifications\s*\(\)'
    '\bhandle_clarifications\s*\(\)'
    '\breset_failure_cause_context\s*\(\)'
    '\bset_primary_cause\s*\(\)'
    '\bset_secondary_cause\s*\(\)'
    '\bemit_cause_objects_json\s*\(\)'
    '\bload_clarifications_content\s*\(\)'
    '\b_ensure_drift_log\s*\(\)'
    '\b_ensure_adl\s*\(\)'
    '\b_ensure_human_action\s*\(\)'
    '\b_ensure_nonblocking_log\s*\(\)'
    '\b_fc_emit_cause_object\s*\(\)'
    '\b_fc_json_escape\s*\(\)'
    '\bresolve_alias_category\s*\(\)'
    '\bresolve_alias_subcategory\s*\(\)'
    '\bformat_failure_cause_summary\s*\(\)'
    # m30.1 + m30.2 (Phase 5): the crawler + rescan ported to
    # internal/crawler/. All six lib/crawler*.sh files were deleted at
    # m30.1; lib/rescan.sh and lib/rescan_helpers.sh retired at m30.2.
    # Sourcing any of them from lib/, stages/, or tekhton-legacy.sh
    # would silently fork the contract. lib/init.sh exec's
    # `tekhton crawler crawl`; tekhton-legacy.sh exec's
    # `tekhton crawler rescan`.
    '^[[:space:]]*(source|\.)[[:space:]]+.*/(crawler|crawler_inventory|crawler_inventory_emitters|crawler_content|crawler_deps|crawler_emit|rescan|rescan_helpers)\.sh'
    # The bash crawler / rescan function names whose reintroduction in
    # lib/ or stages/ would mean someone is rebuilding the bash crawler
    # outside the Go boundary. Function-definition shape only (`fn_name()`).
    '\bcrawl_project\s*\(\)'
    '\b_list_tracked_files\s*\(\)'
    '\b_crawl_directory_tree\s*\(\)'
    '\b_emit_tree_txt\s*\(\)'
    '\b_emit_inventory_jsonl\s*\(\)'
    '\b_emit_dependencies_json\s*\(\)'
    '\b_emit_configs_json\s*\(\)'
    '\b_emit_tests_json\s*\(\)'
    '\b_emit_sampled_files\s*\(\)'
    '\b_emit_meta_json\s*\(\)'
    '\b_annotate_package\s*\(\)'
    '\b_is_binary_file\s*\(\)'
    '\b_read_sampled_file\s*\(\)'
    # m30.2: rescan-specific functions retired with lib/rescan*.sh.
    '\brescan_project\s*\(\)'
    '\b_update_index_sections\s*\(\)'
    '\b_get_changed_files_since_scan\s*\(\)'
    '\b_detect_significant_changes\s*\(\)'
    '\b_is_manifest_file\s*\(\)'
    '\b_is_config_file\s*\(\)'
    '\b_extract_sampled_files\s*\(\)'
    '\b_record_scan_metadata\s*\(\)'
    # m31.1: build + completion gate functions ported to internal/gates/.
    # Their reintroduction in lib/ or stages/ would mean someone forked the
    # canonical Go gate. The bash compatibility shims `run_build_gate` and
    # `run_completion_gate` live in tekhton-legacy.sh as `tekhton gate …`
    # execs; they are intentionally NOT matched here so the shim stays
    # valid. The UI gate (`_run_ui_test_phase`, gates_ui*.sh) is still bash
    # through m31.2 and is also not matched.
    '^[[:space:]]*(source|\.)[[:space:]]+.*/(gates|gates_phases|gates_completion)\.sh'
    '\b_gate_check_timeout\s*\(\)'
    '\b_gate_effective_timeout\s*\(\)'
    '\b_gate_phase_analyze\s*\(\)'
    '\b_gate_phase_compile\s*\(\)'
    '\b_gate_try_remediation\s*\(\)'
    '\b_gate_run_analyze\s*\(\)'
    '\b_gate_run_compile\s*\(\)'
    '\b_gate_write_analyze_errors\s*\(\)'
    '\b_gate_write_compile_errors\s*\(\)'
    '\b_warn_summary_drift\s*\(\)'
)
