# Bucket B Audit — TUI (bash sidecar manager + Python render)

Audited 26 tests. Verdict counts: KEEP=26, DELETE-STALE=0, PORT-TO-GO=0, NEEDS-REVIEW=0.

The entire TUI orchestration surface remains in bash. `internal/tui` (Go) covers
only spawn/stop/PID-file management and the initial+final `tui_status.json`
envelopes (see `internal/tui/sidecar.go` header comment: "mid-run status writers
stay in bash"). All mid-run writers (`lib/tui_ops.sh`, `lib/tui_ops_pause.sh`,
`lib/tui_ops_substage.sh`, `lib/tui_liveness.sh`, `lib/tui_helpers.sh`,
`lib/tui.sh`) and the Python renderer (`tools/tui*.py`) are still live with
real logic — none are shims, all 300+ LOC. Every function asserted by the
bucket's tests resolves to a real definition in those files.

## Verdicts

| Test | Verdict | Reason |
|---|---|---|
| test_tui_action_items.sh | KEEP | Exercises `lib/tui_helpers.sh::_tui_json_build_status` action_items wiring via `_OUT_CTX`; both bash files live |
| test_tui_active_path.sh | KEEP | Exercises `lib/tui.sh` active-path globals + atomic status writes; still primary status-write path |
| test_tui_attempt_counter.sh | KEEP | Exercises `_OUT_CTX[attempt]` → `_tui_json_build_status` in `lib/tui_helpers.sh`; live |
| test_tui_attribution.sh | KEEP | Exercises `_out_emit`→TUI recent_events `source` field in `lib/output.sh`+`lib/tui.sh`; live |
| test_tui_complete_hold_loop.sh | KEEP | Exercises `tui_complete` hold loop in `lib/tui.sh:240`; live |
| test_tui_fallback.sh | KEEP | Exercises `_tui_should_activate` gating in `lib/tui.sh:98`; same gates Go side mirrors but bash still owns its own callers |
| test_tui_lifecycle_invariants.sh | KEEP | Quality-gate suite for the substage API + lifecycle V2 (M113/115/116/117/118); all targeted functions live in `lib/tui*.sh` |
| test_tui_liveness_probe.sh | KEEP | Exercises `lib/tui_liveness.sh::_tui_check_sidecar_liveness`; live |
| test_tui_liveness_sampling.sh | KEEP | Same target as liveness_probe — sampling interval guard in `lib/tui_liveness.sh`; live |
| test_tui_multipass_lifecycle.sh | KEEP | Exercises `_hook_tui_complete` in `lib/finalize_dashboard_hooks.sh:166`; live |
| test_tui_no_dead_weight.sh | KEEP | Exercises `lib/tui_helpers.sh::_tui_json_build_status` JSON shape; live |
| test_tui_ops_idle_ordering.sh | KEEP | Exercises `run_op` substage ordering in `lib/tui_ops.sh:118`; live |
| test_tui_orphan_lifecycle_integration.sh | KEEP | End-to-end test spawning real `tools/tui.py` + driving `tui_stop`; Python sidecar + bash glue both live |
| test_tui_pid_validation.sh | KEEP | Exercises `_tui_kill_stale` PID-regex validation in `lib/tui.sh:135`; live (Go `killStale` is independent, doesn't replace bash callers) |
| test_tui_project_dir_display.sh | KEEP | Exercises `lib/tui_helpers.sh::_tui_json_build_status` PROJECT_DIR field; live |
| test_tui_quota_pause.sh | KEEP | Exercises `tui_enter_pause`/`tui_update_pause`/`tui_exit_pause` in `lib/tui_ops_pause.sh`; live (Go quota only emits causal events, doesn't drive TUI) |
| test_tui_render_timings_comment.sh | KEEP | Grep-style assertion on `tools/tui_render_timings.py` comment; Python renderer still live |
| test_tui_set_context.sh | KEEP | Exercises `tui_set_context` (`lib/tui.sh:272`) + `_tui_stage_order_json` (`lib/tui_helpers.sh:138`); both live |
| test_tui_stage_completion.sh | KEEP | Exercises `tui_stage_end` elapsed/turns recording in `lib/tui_ops.sh:278`; live |
| test_tui_stage_wiring.sh | KEEP | Exercises `tui_stage_begin`/`tui_stage_end` label contract across `tekhton.sh`, stage scripts; bash stage scripts still owners |
| test_tui_stop_orphan_recovery.sh | KEEP | Exercises `tui_stop` pidfile-fallback in `lib/tui.sh:206`; live |
| test_tui_stop_silent_fds.sh | KEEP | Exercises `tui_stop` fd-silence contract in `lib/tui.sh:206`; live |
| test_tui_substage_api.sh | KEEP | Exercises `tui_substage_begin`/`tui_substage_end` in `lib/tui_ops_substage.sh`; live |
| test_tui_substage_json_clear.sh | KEEP | Exercises end-to-end JSON clear for `tui_substage_end`; live |
| test_tui_substage_unused_args.sh | KEEP | Exercises `tui_substage_begin`/`tui_substage_end` arg-binding contract; live |
| test_tui_write_suppression.sh | KEEP | Exercises `_TUI_SUPPRESS_WRITE` semaphore around `tui_stage_end` auto-close (`lib/tui_ops.sh:225,244`); live |

## Coverage gaps noted

- `internal/tui` has Go tests for the spawn/stop/PID-file boundary but no
  parity test asserting the Go-emitted `tui_status.json` initial envelope
  matches the schema fields bash writers later mutate (e.g., new fields
  added to `_tui_json_build_status` could drift the Go `initialStatus`
  struct without any test catching it).
- No bash test directly verifies the handoff between the Go-written initial
  status envelope and the first bash-side mid-run write (the schema-shape
  contract crosses the language boundary but has no integration test on
  either side).
