# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-05-04 | "M01"] [.github/workflows/go-build.yml:76] `golangci/golangci-lint-action@v6` uses `version: latest` — downloads an unpinned binary at CI run time. Pin to a specific semver (e.g. `v1.64.5`) in a follow-up wedge.
- [ ] [2026-05-04 | "M01"] [.github/workflows/go-build.yml] All four action refs (`actions/checkout@v4`, `actions/setup-go@v5`, `actions/upload-artifact@v4`, `golangci/golangci-lint-action@v6`) use mutable major-version tags rather than commit SHAs. Pin to SHAs in a future cleanup pass; bounded by the `permissions: contents: read` declaration.
- [ ] [2026-05-04 | "M01"] [docs/go-build.md:68] The ldflags documentation example shows `$(cat VERSION)` but the Makefile correctly uses `tr -d '[:space:]' < VERSION`. Both produce the correct result (because `version.String()` calls `strings.TrimSpace`), but the doc example could mislead a future contributor who copies it into a script that bypasses `version.String()`.
- [ ] [2026-05-04 | "M01"] [.tekhton/CODER_SUMMARY.md] `README.md` is mentioned in the "Docs Updated" section at the bottom of the summary but is absent from the primary "Files Modified" table. Minor summary incompleteness — no action needed.

## Resolved
