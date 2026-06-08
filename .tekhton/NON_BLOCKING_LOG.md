# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
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
