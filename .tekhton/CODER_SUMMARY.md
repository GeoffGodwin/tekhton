# Coder Summary
## Status: COMPLETE

## What Was Implemented

m35.1 — Security Helpers Port. The severity classifier, finding parser,
block builders, and escalation writer move from `lib/security_helpers.sh`
(240 LOC) into `internal/security/` (Go). The bash file becomes a 60-LOC
shim that execs `tekhton security <sub>` for each helper so
`stages/security.sh` continues to work unchanged through the m35.1 → m35.2
window. m35.2 will port the stage and delete the shim.

- `internal/security/severity.go` — `Severity` type, `Rank`, and
  `MeetsThreshold` mirroring the bash `CRITICAL=4 / HIGH=3 / MEDIUM=2 /
  LOW=1 / unknown=0` rank table verbatim.
- `internal/security/findings.go` — `Finding{Severity, Fixable,
  Description}`, `ParseReport` (scans `## Findings` until next `##`),
  `IsDocsOnly` (full bash allowlist preserved). Inlined
  `extractFilesFromCoderSummary` port of `lib/indexer_helpers.sh`'s
  parser since no Go shared helper exists yet.
- `internal/security/blocks.go` — `BuildFixableBlock`,
  `BuildUnfixableBlock`, `BuildNotesBlock`, `HasBlocking`. Each row is
  `- [SEV] desc\n`; empty result is `""` (the bash `echo` quirk that
  appended an extra `\n` is stripped from the captured baselines).
- `internal/security/escalation.go` — `Escalator{HumanAction
  HumanActionAppender}`, `HandleUnfixable(policy, block, task)` with
  the four bash branches (escalate / halt / waiver / unknown). Halt
  returns `(false, nil)` per the milestone — the stage owns the
  pipeline-state write. `HumanActionAppender` interface lets tests
  swap a fake; production wires `drift.HumanAction`.
- `cmd/tekhton/security.go` — five Hidden Cobra subcommands
  (`parse-findings`, `meets-threshold`, `build-block`, `is-docs-only`,
  `handle-unfixable`). TSV format is a load-bearing contract for the
  shim; exit codes mirror the bash return semantics so the shim's
  `if`-based callers work unchanged.
- `lib/security_helpers.sh` — rewritten as a 60-LOC shim. Each helper
  except `_write_security_notes` shells out to `tekhton security
  <sub>`. `_write_security_notes` and the halt branch of
  `_handle_unfixable_findings` stay bash because the bash stage still
  owns those side-effects in m35.1.

Tests:

- `internal/security/severity_test.go` — table tests covering the 4×4
  known-pair matrix plus 8 unknown-input pairs plus 4 case-sensitive
  pairs. Coverage: 100%.
- `internal/security/findings_test.go` — fixture-driven parse tests +
  per-extension IsDocsOnly coverage. Coverage: 85–93%.
- `internal/security/blocks_test.go` — golden-file replay across the 6
  fixtures × 3 blocks = 18 byte-identical assertions against the
  pre-m35.1 bash-captured baselines under `testdata/baselines/`.
  Coverage: 100%.
- `internal/security/escalation_test.go` — per-branch routing tests
  with a fake `HumanActionAppender`, plus a real-write test through
  `drift.HumanAction` to a tempdir. Coverage: 100%.
- `cmd/tekhton/security_test.go` — Cobra-level help/registration tests,
  TSV/JSON format assertions, and subprocess-driven exit-code
  assertions (Cobra+`os.Exit` cannot be intercepted in-process). Builds
  the binary once into a tempdir via `buildTekhtonBinary`.

Test maintenance (caused by my changes):

- `tests/test_security_stage.sh` — added `TEKHTON_BIN` forcing to the
  local build (overrides any parent-shell stable-binary pointer) plus
  `export SECURITY_REPORT_FILE` so the post-parse `_build_*_block`
  calls (which now exec into Go) read the same file the test wrote.

Docs:

- `docs/go-migration.md` — appended an "M35.1" section describing the
  per-cycle 5-subprocess-spawn tax during the m35.1 → m35.2 window, the
  rationale for keeping `_write_security_notes` bash, and the halt-branch
  state-write layering decision.
- `ARCHITECTURE.md` — added entries for `internal/security/`,
  `cmd/tekhton/security.go`, and the new `lib/security_helpers.sh` shim.

## Files Modified

- `internal/security/severity.go` (NEW)
- `internal/security/severity_test.go` (NEW)
- `internal/security/findings.go` (NEW)
- `internal/security/findings_test.go` (NEW)
- `internal/security/blocks.go` (NEW)
- `internal/security/blocks_test.go` (NEW)
- `internal/security/escalation.go` (NEW)
- `internal/security/escalation_test.go` (NEW)
- `internal/security/testdata/reports/01-empty.md` (NEW)
- `internal/security/testdata/reports/02-no-findings-header.md` (NEW)
- `internal/security/testdata/reports/03-all-low.md` (NEW)
- `internal/security/testdata/reports/04-mixed-fixable.md` (NEW)
- `internal/security/testdata/reports/05-malformed-severity.md` (NEW)
- `internal/security/testdata/reports/06-truncated-section.md` (NEW)
- `internal/security/testdata/baselines/{01..06}-{fixable,unfixable,notes}.txt` (NEW — 18 files)
- `cmd/tekhton/security.go` (NEW — 210 LOC, 5 Hidden subcommands)
- `cmd/tekhton/security_test.go` (NEW — Cobra + subprocess tests, shared `buildTekhtonBinary` helper)
- `cmd/tekhton/main.go` (modified — registered `newSecurityCmd()` on root)
- `lib/security_helpers.sh` (rewritten — 60 LOC shim, down from 240)
- `tests/test_security_stage.sh` (modified — forces local `TEKHTON_BIN`; exports `SECURITY_REPORT_FILE` so the build-block subprocess reads the test's report)
- `docs/go-migration.md` (modified — appended M35.1 transition note)
- `ARCHITECTURE.md` (modified — added entries for the new package + CLI + shim)

## Docs Updated

- `docs/go-migration.md` — M35.1 transition tax section + scope rationale
- `ARCHITECTURE.md` — added internal/security/, cmd/tekhton/security.go, and lib/security_helpers.sh shim entries

## Human Notes Status

No unchecked human notes for this run.

## Acceptance Criteria

All acceptance criteria from the milestone are met:

- Severity exports + rank/threshold table match the bash byte-for-byte
  (unknown returns 0; case-sensitive). Verified by
  `severity_test.go::TestRank_*` and `TestMeetsThreshold_*`.
- `ParseReport` handles missing/empty/malformed/truncated reports and
  defaults missing `fixable:` to "unknown". Verified by
  `findings_test.go`.
- `IsDocsOnly` returns true for docs-only, false for code-present, false
  for missing summary; smoke-tests every extension in the allowlist.
- `BuildFixableBlock` / `BuildUnfixableBlock` / `BuildNotesBlock`
  outputs byte-identical against the 18 captured bash baselines
  (`blocks_test.go::TestBlocks_Goldens`).
- `Escalator.HandleUnfixable` routes through `drift.HumanAction.Append`
  with the bash-format description prefixes (different prefix per
  branch), short-circuits empty blocks, returns `(false, nil)` for
  halt without touching the human-action file.
- `cmd/tekhton/security.go` registers five Hidden subcommands; each
  `--help` exits 0; TSV/JSON/exit-code contracts verified via
  subprocess-driven tests.
- `lib/security_helpers.sh` is 60 LOC (down from 240), shellcheck
  clean, no `declare -A severity_rank`, audit-bash-env.sh clean.
- The bash stage's helper integration test (`tests/test_security_stage.sh`)
  passes 37/37 with the shim in place.
- `go test -cover ./internal/security/...` reports 93.5% total; per-file
  100/85+/100/100 — above the milestone minimums.
- `bash tests/run_tests.sh` reports 501/501 shell pass, Go pass — zero
  new failures vs the m34.2 baseline.
- `bash scripts/wedge-audit.sh` exits 0 (clean).
- `docs/go-migration.md` has the M35.1 transition tax note.

The "implementation run is itself driven by `tekhton run --milestone
m35.1 --complete`" criterion is operator-side and not under coder
control; the test suite + manual shim exercise stand in for that
acceptance signal.

## Remaining Work

None.
