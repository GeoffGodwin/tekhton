# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-06-08 | "Implement Milestone m01: Provider Interface and Claude Reference Implementation"] `go.mod:8` â `golang.org/x/sys` is pinned at `v0.13.0` (2023-Q3); run `go get golang.org/x/sys@latest && go mod tidy` to close the stale-dependency gap. LOW severity per security report; no known exploitable CVE in this path.
- [ ] [2026-06-08 | "Implement Milestone m01: Provider Interface and Claude Reference Implementation"] `go.mod:8` â `golang.org/x/sys` appears in the direct require block without an `// indirect` marker, but the security agent describes it as an indirect dependency pulled in by `fsnotify`. If no Go file in the repo directly imports `golang.org/x/sys`, `go mod tidy` should demote it to the indirect block. If later-wedge subcommand implementations do import it directly, the current placement is correct and this note is moot.
- [ ] [2026-06-08 | "Implement Milestone m01: Provider Interface and Claude Reference Implementation"] `internal/version/version_test.go` â tests mutate `version.Version` without `t.Cleanup` restoration. Safe for sequential execution (no `t.Parallel()`), but would introduce a data race if parallel test expansion is added later.
- [ ] [2026-06-08 | "Implement Milestone m01: Provider Interface and Claude Reference Implementation"] `Makefile:lint` â the lint target silently skips if `golangci-lint` is not installed, meaning a contributor without it on PATH will not see lint failures locally. Pre-existing design choice, not introduced by this milestone.
- [ ] [2026-06-08 | "Implement Milestone m50: MANIFEST.cfg is finalize-owned: block stage-agent writes via a pre-commit guard"] `go.mod:8` â `golang.org/x/sys` appears in the direct require block without an `// indirect` marker, but the security agent describes it as an indirect dependency pulled in by `fsnotify`. If no Go file in the repo directly imports `golang.org/x/sys`, `go mod tidy` should demote it to the indirect block. If later-wedge subcommand implementations do import it directly, the current placement is correct and this note is moot.
- [ ] [2026-06-08 | "Implement Milestone m50: MANIFEST.cfg is finalize-owned: block stage-agent writes via a pre-commit guard"] `internal/version/version_test.go` â tests mutate `version.Version` without `t.Cleanup` restoration. Safe for sequential execution (no `t.Parallel()`), but would introduce a data race if parallel test expansion is added later.
- [ ] [2026-06-08 | "Implement Milestone m50: MANIFEST.cfg is finalize-owned: block stage-agent writes via a pre-commit guard"] `Makefile:lint` â the lint target silently skips if `golangci-lint` is not installed, meaning a contributor without it on PATH will not see lint failures locally. Pre-existing design choice, not introduced by this milestone.
- [ ] [2026-05-25 | "unknown"] (carried from cycle 1) `MANIFEST.cfg` row for m24 lists `depends_on=m23,m26`; the AC specifies `depends_on=m23`. The extra `m26` entry is harmless at runtime (m26 is done) but will fail a literal byte-match against the acceptance criteria.
<<<<<<< Updated upstream
<<<<<<< Updated upstream
=======
>>>>>>> Stashed changes
=======
>>>>>>> Stashed changes

## Resolved

### Test Audit Concerns (2026-05-25)
#### COVERAGE: Regex-bug acceptance test accommodates rather than exposes the defect
#### COVERAGE: FEAT placement check has no test for root-level new files

### Test Audit Concerns (2026-06-08)

#### COVERAGE

#### COVERAGE
