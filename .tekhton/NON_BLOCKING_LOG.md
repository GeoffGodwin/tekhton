# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-06-04 | "unknown"] `lib/project_version.sh:2` â `set -euo pipefail` in a sourced lib file violates the convention (only standalone entry points set this). Pre-existing, not introduced here; carried forward from m43.
- [ ] [2026-06-03 | "unknown"] `CLARIFICATIONS.md` corruption noted in the coder summary (every answer echoes the question verbatim) is worth investigating at the pipeline level before the next invocation so future coders receive usable context.
- [ ] [2026-06-02 | "unknown"] `resilience.go:309` â `projectFilePath` is defined but never called; the comment says "used by the preflight rule below" but `resilience_preflight.go` uses `projectPath` instead. Dead code; can be deleted.
- [ ] [2026-05-31 | "unknown"] `resilience.go:309` â `projectFilePath` is defined but never called; the comment says "used by the preflight rule below" but `resilience_preflight.go` uses `projectPath` instead. Dead code; can be deleted.
- [ ] [2026-05-31 | "unknown"] `UIPhase` has a `Now func() time.Time` struct field AND accepts `in.Now` from `PhaseInput`. Both are checked in sequence (`p.Now` preferred, `in.Now` as fallback). Other phases (`AnalyzePhase`, `CompilePhase` in `phases.go`) only use `in.Now`. The redundancy is harmless but creates an inconsistency in the Phase API.
- [ ] [2026-05-26 | "unknown"] `tests/test_audit_bash_env.sh:9` â `set -euo pipefail` combined with bare `return 1` in `_assert_exit` / `_assert_empty_stdout` / `_assert_contains` means the script aborts on the first failing assertion. The `FAILED_CASES` array and the end-of-test summary ("FAIL: N cases failed") are unreachable when any case fails. The test still exits non-zero (CI catches it), but subsequent fixtures do not run and the failure list is never printed. Consider wrapping each assertion call site with `|| true` and relying solely on `FAILED_CASES` for reporting, or remove `set -e` and gate the final exit on `${#FAILED_CASES[@]}`.
- [ ] [2026-05-25 | "unknown"] (carried from cycle 1) `MANIFEST.cfg` row for m24 lists `depends_on=m23,m26`; the AC specifies `depends_on=m23`. The extra `m26` entry is harmless at runtime (m26 is done) but will fail a literal byte-match against the acceptance criteria.
- [ ] [2026-05-18 | "unknown"] `ui_audit.go:255` — `strings.Join(files, "") // satisfy import; sort below` is dead code with a misleading comment. The `strings` package is already used by `strings.ToLower`, `strings.ReplaceAll`, and `strings.Contains` elsewhere in the file, so no import-satisfaction trick is needed. The line computes and discards a string and should be removed.
<<<<<<< Updated upstream
<<<<<<< Updated upstream
=======
>>>>>>> Stashed changes
=======
- [ ] [2026-05-18 | "unknown"] `ui_audit.go:263-268` — `sortStrings` re-implements stdlib insertion sort. `sort.Strings` from the `sort` package would do the same with one import line. Minor; functionally correct.
>>>>>>> Stashed changes

## Resolved

### Test Audit Concerns (2026-05-25)
#### COVERAGE: Regex-bug acceptance test accommodates rather than exposes the defect
#### COVERAGE: FEAT placement check has no test for root-level new files
