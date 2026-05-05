# Security Notes

Generated: 2026-05-04 22:51:01

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A08] [.github/workflows/go-build.yml:76] fixable:yes — `golangci/golangci-lint-action@v6` passes `version: latest`, downloading an unpinned golangci-lint binary at CI run time. A future upstream version change can silently alter lint behavior; a compromised release could execute arbitrary code in the runner. Pin to a specific semver, e.g. `version: v1.64.5`.
- [LOW] [category:A08] [.github/workflows/go-build.yml] fixable:yes — All four action refs (`actions/checkout@v4`, `actions/setup-go@v5`, `actions/upload-artifact@v4`, `golangci/golangci-lint-action@v6`) are pinned to mutable major-version tags rather than immutable commit SHAs. If a tag is forcibly moved (maintainer compromise or accident), the next CI run executes the replacement code. Mitigation: pin each ref to its full commit SHA with a comment naming the human-readable tag. Risk is bounded here by the `permissions: contents: read` declaration on the workflow.
