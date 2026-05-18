# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-05-18 | "unknown"] **Stop condition diverges from architect spec but is correct.** The plan said to stop at "the first line sourcing a `stages/` script, i.e. line 964." The JR coder stopped at the `# Stage helpers and implementations` comment on line 961 instead. This is actually better: stopping at the comment avoids capturing `lib/intake_helpers.sh` (line 962) and `lib/intake_verdict_handlers.sh` (line 963), which would have made the extracted count 111 vs `DefaultLibHelpers` 109 and caused a spurious test failure. The JR coder correctly recognized the spec was off by one semantic unit and fixed it silently.
- [ ] [2026-05-18 | "unknown"] `EmitRunMemory.buildRecord` reads task text via `os.Getenv("TASK")` directly rather than from `in.Result` or an `Input` field. This is a faithful port of the bash behavior (which also read `$TASK`), but future hook ports that need task text should carry it in `Input` rather than relying on the ambient env. Drift observation for when the `Input` struct is extended.

## Resolved
- [RESOLVED 2026-05-18 | m21 closeout] `firstInt` in `internal/finalize/emit_run_summary.go` renamed to `lastInt` to reflect bash `tail -1` semantics. Three call sites + unit test updated.
- [RESOLVED 2026-05-18 | m21 closeout] `parseInt` helper removed; `lastInt` now delegates to `strconv.Atoi`.
- [RESOLVED 2026-05-18 | m21 closeout] `_ = exit` dead capture in `emit_run_summary.go` removed along with the unused `exit := in.ExitCode` declaration in `build()`.
- [RESOLVED 2026-05-18 | m21 closeout] `absoluteUnder` in `archive_reports.go` hardened: relative paths are cleaned and asserted to resolve under `projectDir` (traversal collapses to `projectDir`); absolute paths are cleaned only, preserving bash-parity for env-driven absolute paths like `LOG_DIR` and `CAUSAL_LOG_FILE`. Covers all three call sites (`archive_reports.go`, `archive_milestone.go`, `causal_log_finalize.go`) via the shared helper.
- [RESOLVED 2026-05-18 | m21 closeout] `runner.go` `Finalize` docstring updated to list all 8 pure-Go hooks (adds `emit_run_summary`, `emit_timing_report`).
- [RESOLVED 2026-05-18 | m21 closeout] `TestHookOrder_MatchesBashRegistration` comment in `orchestrator_test.go` updated — the hookOrder list in `orchestrator.go` is now the canonical source; `lib/finalize.sh` no longer carries a registration list.
- [RESOLVED 2026-05-18 | m21 closeout] `TestDefaultLibHelpersFilesExist` failure resolved by restoring `lib/milestone_archival.sh` + `lib/milestone_archival_helpers.sh` as transition artifacts (real bash callers still exist: `milestone_split.sh:138,226`, `tekhton-legacy.sh:2208`). Drift observation recorded for proper retirement in future milestones.
- [RESOLVED 2026-05-18 | m21] `emit_run_summary.go` at soft target (636 lines). Cohesive around one concept; collector split deferred to a future cleanup pass.
- [RESOLVED 2026-05-18 | m21] Duplicate parity test (`TestDefaultLibHelpersMatchesLegacySourceBlock` vs `TestDefaultLibHelpersParityWithLegacy`). Harmless — complementary path-resolution strategies provide defense in depth. Architect-agent recommendation logged in DRIFT_LOG.
- [RESOLVED 2026-05-18 | m21] CODER_SUMMARY.md staleness about `lib/milestone_archival*.sh` resolved via closeout restore; both files now exist again with documented transition purpose.
- [RESOLVED 2026-05-18 | m21] `goNativeHooks` map comment + `test_finalize_shim.sh:29` updated to "8 pure-Go bodies".
- [RESOLVED 2026-05-18 | m21] `_shim_load_finalize_bodies()` over-sourcing acknowledged as intentional for per-hook isolation; flag carried forward for m24 (notes/drift port) when the dependency map sharpens.
