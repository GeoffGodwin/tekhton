## Summary
M01 adds a Go module foundation: a Cobra CLI stub, Makefile build targets, a GitHub Actions CI workflow, and a shell smoke-test harness. No authentication, cryptography, user input handling, or network communication is introduced. The shell script (`scripts/self-host-check.sh`) is well-formed with `set -euo pipefail` and fully quoted variables. The Go source is minimal and safe. The two findings are both LOW-severity supply chain hygiene issues in the CI workflow — mutable action refs and an unpinned linter version. Neither is exploitable under the workflow's `contents: read` permission scope.

## Findings
- [LOW] [category:A08] [.github/workflows/go-build.yml:76] fixable:yes — `golangci/golangci-lint-action@v6` passes `version: latest`, downloading an unpinned golangci-lint binary at CI run time. A future upstream version change can silently alter lint behavior; a compromised release could execute arbitrary code in the runner. Pin to a specific semver, e.g. `version: v1.64.5`.
- [LOW] [category:A08] [.github/workflows/go-build.yml] fixable:yes — All four action refs (`actions/checkout@v4`, `actions/setup-go@v5`, `actions/upload-artifact@v4`, `golangci/golangci-lint-action@v6`) are pinned to mutable major-version tags rather than immutable commit SHAs. If a tag is forcibly moved (maintainer compromise or accident), the next CI run executes the replacement code. Mitigation: pin each ref to its full commit SHA with a comment naming the human-readable tag. Risk is bounded here by the `permissions: contents: read` declaration on the workflow.

## Verdict
FINDINGS_PRESENT
