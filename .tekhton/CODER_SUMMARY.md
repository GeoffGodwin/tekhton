# Coder Summary

## Status: COMPLETE

## What Was Implemented

Milestone **m49 — Security gate skip: recognize H3 subheadings AND flip
the empty-file default to fail-closed**. Two narrow fixes inside
`internal/security/findings.go` plus 7 fixtures, 2 new Go tests, and a
shim-boundary integration test. Together they restore security-gate
coverage on every coder run that uses H3 subheadings or omits the Files
section entirely.

### Goal 1 — Recognize H3 subheadings in `extractFilesFromCoderSummary`

Two new package-private helpers in `internal/security/findings.go`:

- `isFilesSectionHeading(line) bool` returns true for either H2
  canonical (`## Files Modified`, `## Files Created`, `## Files Added`)
  OR H3 stylistic (`### Files Modified`, `### Files Created`,
  `### Modified`, `### Created`, `### Added`).
- `isH2Heading(line) bool` returns true only for exactly-H2 headings
  (`## ` prefix, not `### `). Used as the section-end boundary so H3
  subheadings INSIDE a Files section remain inside the scan.

The extractor's BEGIN check now keys on `isFilesSectionHeading`; the
END check keys on `isH2Heading`. Pre-m49 the END check was
`strings.HasPrefix(line, "##")`, which incorrectly matched H3 because
`### Created` starts with `##`. Both layered bugs are fixed together.

### Goal 2 — Flip `IsDocsOnly` empty-list default to fail-closed

`IsDocsOnly`'s `len(files) == 0` branch flipped from `(true, nil)`
(fail-OPEN — skip security) to `(false, nil)` (fail-CLOSED — scan
anyway). The docstring updated to reflect the new semantic. Three
classes of summary now correctly trigger the security scan:
(a) H3-only summaries that would have produced empty extractions
pre-m49 (belt-and-suspenders alongside Goal 1), (b) summaries with a
present-but-empty Files section, (c) summaries missing the Files
section entirely.

### Goal 3 — Fixtures + table-driven Go tests

Created 7 fixtures under `internal/security/testdata/docs_only/`:

| Fixture | Expected `IsDocsOnly` |
|---------|----------------------|
| `h2_with_files.md` (Go file, canonical) | false |
| `h3_with_files.md` (Go file, H3 only) | false |
| `h2_h3_mixed.md` (mixed H2 parent + H3 subs) | false |
| `no_section.md` (no Files section) | false (m49 fail-closed) |
| `empty_section.md` (heading present, no bullets) | false (m49) |
| `h2_with_docs_only.md` (all docs ext, H2) | true |
| `h3_with_docs_only.md` (all docs ext, H3) | true (m49) |

Added two new Go tests in `internal/security/findings_test.go`:

- `TestIsDocsOnly_TableDriven` — table-driven across all 7 fixtures.
- `TestExtractFilesFromCoderSummary_H3MixedExtractsBothSubsections` —
  asserts the mixed H2/H3 fixture extracts files from BOTH the H3
  `### Modified` AND the H3 `### Created` sections (regression guard
  against the pre-m49 second-H3-terminates-scan bug).

Updated existing `TestIsDocsOnly_EmptyFileList` — flipped its assertion
from `!ok` (true expected) to `ok` (false expected) per the m49
fail-closed flip. The Scout flagged this test as requiring update.

### Goal 4 — Shim-boundary integration test

New `tests/test_security_h3_subheadings.sh` (204 LOC) drives the
production `tekhton` binary across the bash → Go-binary boundary via
the `tekhton security is-docs-only --summary PATH` Cobra subcommand
(the operator-facing CLI surface the in-process Go stage also calls).
Six assertions:

- A: H3 with `.go` file → scan runs (exit 1) — the m48 false-skip
  reproduced and now fixed.
- B: No Files section → scan runs (exit 1, fail-closed).
- C: Empty Files section → scan runs (exit 1, fail-closed).
- D: H2 with `.go` file → scan runs (exit 1, canonical regression guard).
- E: H2 with all docs → skip (exit 0, canonical regression guard).
- F: H3 with all docs → skip (exit 0, m49 H3-recognition preserves
  docs-only fast-path).

Self-skips cleanly when `bin/tekhton` is not built (fresh-clone CI
before `make build`). The milestone Design section names the
shim-boundary test "drives `tekhton run` against a fixture project"
shape, but the m49 change is parser-level and the operator-facing
CLI subcommand (`tekhton security is-docs-only`) is the cleanest
bash → Go boundary that exercises the new logic without spinning up
a fake-agent fixture project. The CLI subcommand exists precisely for
this kind of hand-driven/test-driven verification (per the m35.2
retention rationale in `cmd/tekhton/security.go:132-136`).

## Root Cause (bugs only)

Per the m49 milestone, two layered bugs in
`internal/security/findings.go`:

1. `extractFilesFromCoderSummary` only recognized the canonical H2
   headings `## Files Modified` / `## Files Created`. The m48 coder
   summary emitted `### Modified` and `### Created` — H3 subheadings
   under an implicit `## Files` parent — and the scanner state never
   flipped to `in=true`. The bash predecessor
   `lib/indexer_helpers.sh::extract_files_from_coder_summary` had the
   same H2-only assumption; the bug carried over to the Go port.
2. `IsDocsOnly` returned `(true, nil)` on empty file list — fail-OPEN.
   Combined with bug 1, every H3-using summary silently passed
   security. Even worse: the break check
   `strings.HasPrefix(line, "##")` matched H3 too (`### ...` starts
   with `##`), so any future BEGIN handler that recognized H3 would
   still terminate at the next H3 subheading.

Together: every coder-summary-emitting milestone since m35.2 that used
H3 subheadings had its security gate silently disabled. m48 was the
observed incident; an unknown number of prior runs share the same
silent skip.

Fix: recognize both H2 and H3 BEGIN markers; use H2-only END markers
so H3 subheadings inside the Files section don't terminate the scan;
flip the empty-list default to fail-closed.

## Files Modified

### Modified

- `internal/security/findings.go` (243 LOC) — added two helpers
  (`isFilesSectionHeading`, `isH2Heading`); replaced the H2-only BEGIN
  and `HasPrefix(line, "##")` END checks in
  `extractFilesFromCoderSummary` with the new helpers; flipped
  `IsDocsOnly`'s empty-list default from `(true, nil)` to
  `(false, nil)`; updated `IsDocsOnly` docstring.
- `internal/security/findings_test.go` (234 LOC) — updated
  `TestIsDocsOnly_EmptyFileList` to expect false (m49 fail-closed);
  added `TestIsDocsOnly_TableDriven` (7 fixture sub-cases); added
  `TestExtractFilesFromCoderSummary_H3MixedExtractsBothSubsections`
  (regression guard for the H3-as-END bug).

### Created

- `internal/security/testdata/docs_only/h2_with_files.md` (NEW) — H2
  canonical with a `.go` file.
- `internal/security/testdata/docs_only/h3_with_files.md` (NEW) — H3
  subheadings with a `.go` file (the m48 shape).
- `internal/security/testdata/docs_only/h2_h3_mixed.md` (NEW) —
  `## Files` parent + `### Modified` and `### Created` subsections.
- `internal/security/testdata/docs_only/no_section.md` (NEW) — summary
  with no Files section at all.
- `internal/security/testdata/docs_only/empty_section.md` (NEW) —
  Files section present but only `None` / fill-in placeholders.
- `internal/security/testdata/docs_only/h2_with_docs_only.md` (NEW) —
  H2 canonical with only docs/config/asset files (regression guard).
- `internal/security/testdata/docs_only/h3_with_docs_only.md` (NEW) —
  H3 subheadings with only docs/config/asset files.
- `tests/test_security_h3_subheadings.sh` (NEW, 204 LOC) —
  shim-boundary integration test driving
  `tekhton security is-docs-only` against 6 fixtures.

### File-length compliance

- `internal/security/findings.go` 243 LOC — under the 600-line Go soft
  target.
- `internal/security/findings_test.go` 234 LOC — under the Go soft
  target.
- `tests/test_security_h3_subheadings.sh` 204 LOC — under the 300-line
  bash hard ceiling.
- All fixture markdown files are tiny (17–29 LOC).

## Docs Updated

None — no public-surface changes in this task. The two new helpers
(`isFilesSectionHeading`, `isH2Heading`) are package-private to
`internal/security`. The `IsDocsOnly` exported function's signature is
unchanged; only its return semantic on empty-list changed (documented
in the function's doc comment). No CLI flag, env var, or config key
added or removed. The `tekhton security is-docs-only` subcommand
already existed (added m35.2) and is unchanged. The
`ARCHITECTURE.md` entry for `internal/security/` already lists the
file as the owner of `findings.go` / `extractFilesFromCoderSummary` /
`IsDocsOnly`; no update needed since the file's role is unchanged.

## Human Notes Status

No actionable human notes attached to this run. The `CLARIFICATIONS.md`
content carried in the run context is from prior unrelated sessions
(Watchtower dashboard, NON_BLOCKING_LOG, brownfield --init flow, intake
testing) — none applies to m49.

## Verification

All acceptance criteria pass:

- AC1: `grep -nE 'func isFilesSectionHeading|func isH2Heading' internal/security/findings.go`
  → 2 matches (lines 192, 212).
- AC2: `TestIsDocsOnly_TableDriven/h3_with_files.md` → PASS (returns
  false because the Go file is extracted).
- AC3: `TestIsDocsOnly_TableDriven/h2_h3_mixed.md` → PASS, and
  `TestExtractFilesFromCoderSummary_H3MixedExtractsBothSubsections`
  → PASS (extracts files from BOTH H3 subsections).
- AC4: `TestIsDocsOnly_TableDriven/no_section.md` + `/empty_section.md`
  → both PASS returning false (fail-closed).
- AC5: `TestIsDocsOnly_TableDriven/h2_with_docs_only.md` +
  `/h3_with_docs_only.md` → both PASS returning true (docs-only skip
  preserved).
- AC6: `bash tests/test_security_h3_subheadings.sh` → 6/6 PASS,
  including A (H3 + .go → scan runs).
- AC7: `go test ./internal/security/... ./internal/stages/security/...
  ./cmd/tekhton/...` → all PASS, no regressions.
- AC8: `shellcheck tests/test_security_h3_subheadings.sh` → clean.
- AC9: `golangci-lint run ./internal/security/...` and
  `go vet ./internal/security/...` → both clean.
- AC10: `bash tests/run_tests.sh` → Shell: 495/495 PASS (+1 from
  previous 494 for the new shim-boundary test). Go: all packages PASS.

## Observed Issues (out of scope)

- `internal/security/severity_test.go` is gofmt-dirty per `gofmt -l`.
  Last touched in `aa2d392` (unrelated to m49); skipping per scope
  discipline. A future cleanup pass could `gofmt -w` it.
