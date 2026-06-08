# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-06-02 | "unknown"] `resilience.go:309` â `projectFilePath` is defined but never called; the comment says "used by the preflight rule below" but `resilience_preflight.go` uses `projectPath` instead. Dead code; can be deleted.
- [ ] [2026-05-31 | "unknown"] `resilience.go:309` â `projectFilePath` is defined but never called; the comment says "used by the preflight rule below" but `resilience_preflight.go` uses `projectPath` instead. Dead code; can be deleted.
- [ ] [2026-05-31 | "unknown"] `UIPhase` has a `Now func() time.Time` struct field AND accepts `in.Now` from `PhaseInput`. Both are checked in sequence (`p.Now` preferred, `in.Now` as fallback). Other phases (`AnalyzePhase`, `CompilePhase` in `phases.go`) only use `in.Now`. The redundancy is harmless but creates an inconsistency in the Phase API.
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
