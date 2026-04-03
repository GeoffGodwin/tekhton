# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-03 | "M53"] `gates.sh` Phase 2 (compile errors): when Phase 1 passes and only Phase 2 fails, `BUILD_ERRORS.md` is created via `>>` with no `# Build Errors` header or `## Stage` section — only the `## Error Classification (compile)` and `## Compile Errors` blocks. Inconsistent structure versus Phase 1 failure path where `annotate_build_errors()` writes the canonical header. Low impact (file is still readable by build-fix agent) but worth aligning in a cleanup pass.
- [ ] [2026-04-03 | "M53"] `classify_build_errors_all`: multiple distinct unmatched input lines produce multiple identical `code|code||Unclassified build error` output lines (deduplication key is line-specific but output value is not). Downstream consumers cannot distinguish "one unrecognized error" from "five unrecognized errors" without counting lines. Harmless for current use, but worth noting for M54 auto-remediation consumption.
- [ ] [2026-04-03 | "M52"] `lib/gates.sh` remains at 477 lines (pre-existing; already logged in prior cycle). No action required this cycle.
- [ ] [2026-04-02 | "M53"] `lib/error_patterns.sh` is 337 lines, exceeds the 300-line soft ceiling. The registry heredoc accounts for the bulk; consider splitting the registry data from the classification engine if it grows further.
- [ ] [2026-04-02 | "M53"] `lib/errors.sh` is 304 lines, marginally over the ceiling — acceptable but worth noting for future cleanup.

## Resolved
