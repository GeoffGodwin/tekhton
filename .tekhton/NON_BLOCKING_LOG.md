# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-05-22 | "unknown"] `lib/project_version_bump.sh` is 301 lines (1 over the 300-line hard ceiling per CLAUDE.md Rule 8). Moving `_max_done_milestone_in_manifest` to `lib/project_version.sh` (the detection/discovery half) would naturally bring both files within ceiling and improve separation of concerns.
- [ ] [2026-05-22 | "unknown"] `compute_next_version` header still says "Pure function — no I/O" but it now calls `_max_done_milestone_in_manifest`, which reads `MANIFEST.cfg` from the filesystem. The comment should drop the "no I/O" claim.
- [ ] [2026-05-22 | "unknown"] `tests/test_project_version_bump.sh` is 445 lines (pre-existing overrun; coder added ~83 lines). Consider splitting into `test_compute_next_version.sh` + `test_bump_version_files.sh` in a follow-up cleanup milestone.
- [ ] [2026-05-22 | "unknown"] `lib/project_version_bump.sh:9` has `set -euo pipefail` — a pre-existing issue. Per reviewer.md and CLAUDE.md, sourced files in `lib/` must NOT set this (they inherit it). Not introduced by this PR, flagged for awareness.
- [ ] [2026-05-20 | "unknown"] Reviewer agent did not produce a report — extra tester scrutiny recommended.
- [ ] [2026-05-20 | "unknown"] Reviewer agent did not produce a report — extra tester scrutiny recommended.
- [ ] [2026-05-18 | "unknown"] `ui_audit.go:255` — `strings.Join(files, "") // satisfy import; sort below` is dead code with a misleading comment. The `strings` package is already used by `strings.ToLower`, `strings.ReplaceAll`, and `strings.Contains` elsewhere in the file, so no import-satisfaction trick is needed. The line computes and discards a string and should be removed.
- [ ] [2026-05-18 | "unknown"] `ui_audit.go:263-268` — `sortStrings` re-implements stdlib insertion sort. `sort.Strings` from the `sort` package would do the same with one import line. Minor; functionally correct.
- [ ] [2026-05-18 | "unknown"] m22 close drops the shell-test count from ~506 to ~502 (five bash preflight tests skip-guarded: `test_preflight.sh`, `test_preflight_ui_config.sh`, `test_m118_preflight_deferred_emit.sh`, `test_preflight_infer_degenerate.sh`, `test_m131_coverage_gaps.sh`; one gate test un-guarded: `test_self_host_dry_run_gate.sh`). Acceptance criterion AC#12 says "preserve that count" but `docs/v4-phase5-stub.md` documents the reduction as deliberate (tests drove the deleted bash API). Flagging so the next milestone's AC can be written with the new baseline rather than the stale 506 figure.
- [ ] [2026-05-18 | "unknown"] **Stop condition diverges from architect spec but is correct.** The plan said to stop at "the first line sourcing a `stages/` script, i.e. line 964." The JR coder stopped at the `# Stage helpers and implementations` comment on line 961 instead. This is actually better: stopping at the comment avoids capturing `lib/intake_helpers.sh` (line 962) and `lib/intake_verdict_handlers.sh` (line 963), which would have made the extracted count 111 vs `DefaultLibHelpers` 109 and caused a spurious test failure. The JR coder correctly recognized the spec was off by one semantic unit and fixed it silently.
- [ ] [2026-05-18 | "unknown"] `EmitRunMemory.buildRecord` reads task text via `os.Getenv("TASK")` directly rather than from `in.Result` or an `Input` field. This is a faithful port of the bash behavior (which also read `$TASK`), but future hook ports that need task text should carry it in `Input` rather than relying on the ambient env. Drift observation for when the `Input` struct is extended.

## Resolved
