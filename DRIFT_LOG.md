# Drift Log

## Metadata
- Last audit: 2026-04-06
- Runs since audit: 1

## Unresolved Observations
- [2026-04-06 | "architect audit"] **Observation: `NON_BLOCKING_LOG.md` not updated mid-run** The observation itself states: "the pipeline marks them resolved post-run via the hooks mechanism, so this is expected mid-pipeline state, not an omission." There is no defect. The observation documents expected pipeline behavior. No code change is warranted. Mark RESOLVED.

## Resolved
- [RESOLVED 2026-04-06] `platforms/mobile_native_android/detect.sh:60,65,87` — The security agent flagged the `echo "$gradle_files" | xargs grep -l ...` pattern as LOW/fixable (A03: space-separated paths silently mishandled). The fix was not applied. This is a low-risk internal path (filenames come from `find` within `PROJECT_DIR`), but the loop pattern used in `_detect_android_component_dir` (`while IFS= read -r d`) is the correct idiom — the material-version functions should be harmonized to the same pattern.
- [RESOLVED 2026-04-06] `lib/metrics.sh` now has two separate read blocks for `_STAGE_DURATION` within `record_run_metrics()` — the primary block (lines 93-105) reads coder/reviewer/tester/scout/security/cleanup durations, and the extended block (lines 107-117) reads test_audit/analyze_cleanup/specialist durations via `_collect_extended_stage_vars()`. The split is intentional but the overlap (lines 103-104 vs lines 109-110) creates confusion. A future cleanup could merge both blocks into a single `_collect_extended_stage_vars()` call or document the boundary explicitly.
- [RESOLVED 2026-04-06] The five addressed notes remain `[ ]` in `NON_BLOCKING_LOG.md` — the pipeline marks them resolved post-run via the hooks mechanism, so this is expected mid-pipeline state, not an omission.
- [RESOLVED 2026-04-06] `lib/dashboard_parsers_runs.sh:250-254`: The bash fallback injects `"cycles":N` and `"rework_cycles":N` into the JSON string using `sed` pattern replacement after the `stages_json` loop. If any future field is added before `"reviewer":{` or `"security":{` that also starts with `"reviewer":` or `"security":`, the injection point could shift. Consider a builder approach instead of post-hoc string surgery.
- [RESOLVED 2026-04-06] `stages/tester.sh:355-393`: The test_audit sub-step tracking block appears twice — once in the continuation path (line 355-361) and once in the clean-completion path (line 387-393). The code is identical. Consider extracting to a shared helper `_record_test_audit_substep` to avoid future divergence.
