# Coder Summary

## Status: COMPLETE

## What Was Implemented

m37.1 — Review Helpers and Parser. Pure-logic Go port landing the
`internal/review/` package: parser, cycle budget bookkeeping, and
specialist-block helpers — the pieces the M37.2 stage loop will consume.

### Goal 1 — Parser API surface (`internal/review/parser.go`)

- `Verdict` four-token vocabulary: `VerdictApproved`,
  `VerdictApprovedWithNotes`, `VerdictChangesRequired`,
  `VerdictReplanRequired`, plus `VerdictUnknown` zero value.
- `ACPDecision` ACCEPT / REJECT / MODIFY constants.
- `Report` struct: `Verdict`, `ComplexBlockers`, `SimpleBlockers`,
  `NonBlockingNotes`, `CoverageGaps`, `ACPVerdicts`, `DriftObservations`,
  `SpecialistSection`, `RawBody`.
- `ParseReviewerReport(path string) (*Report, error)` reads from disk;
  `ParseReader(io.Reader)` is the in-memory variant tests use. Both
  populate `RawBody` with the byte-for-byte file contents so downstream
  forensics consumers (dashboard subsystem, the accepted-ACP echo at
  bash review.sh:246) keep working.
- Accessor methods: `HasComplexBlockers() int`, `HasSimpleBlockers() int`,
  `IsApproved() bool`, `AcceptedACPs() []ACPVerdict`.
- Verdict extraction matches bash priority precisely. The heading-anchored
  extraction takes the first non-blank line after `## Verdict`; the inline
  fallback scans the body for the four tokens in REPLAN_REQUIRED >
  APPROVED_WITH_NOTES > CHANGES_REQUIRED > APPROVED priority order. The
  fixture `inline_verdict_fallback.md` and the dedicated
  `TestInlineVerdictFallback_Priority` / `TestInlineVerdictFallback_ReplanWins`
  tests lock in the priority precedence.
- "None" sentinel detection mirrors bash `grep -qE "^\-?\s*None\s*$"`
  byte-for-byte: case-sensitive, optional leading dash, optional
  surrounding whitespace. Lower-case "none" does NOT match.
  `TestNoneSentinelRE_CaseSensitive` and
  `TestNoneSentinel_OptionalDashAndWhitespace` lock this in.
- ACP rows lenient on em-dash vs hyphen delimiter but REQUIRE whitespace
  around the delimiter — without that, the non-greedy capture
  mis-segments names like "parser-leaf-discipline".
  `TestParseACPRows_LenientOnDashes` covers both delimiter forms plus
  malformed rows being dropped.

### Goal 2 — `CycleBudget` (`internal/review/cycle.go`)

- Value type with `Current` and `Max` fields. "Current == 0 before first
  cycle" convention matches bash review.sh:39.
- `Increment()` (pointer receiver) advances; `Remaining() int`,
  `IsLastCycle() bool`, `IsExhausted() bool` (value receivers) report state.
- `BumpFromUsage(used, limit, cap int) (newLimit, bumped bool)`
  encapsulates review.sh:130-148 — at ≥85% usage, bump 25%, clamped to
  `cap` (defaults to 60 if 0 passed). Returns the new limit + a
  bumped flag; DOES NOT mutate the receiver (the test
  `TestCycleBudget_BumpFromUsage` asserts receiver invariance).

### Goal 3 — Specialist helpers (`internal/review/specialist.go`)

- `HasSpecialistBlockers(env string) bool` — true when env contains a
  non-blank, non-"None" line. Lenient on case for the sentinel and on
  "- None" bullet shapes.
- `FormatSpecialistSection(env string) string` — emits the bash-byte-
  identical `"\n## Specialist Blockers\n<env>\n"` block from
  review_helpers.sh:11-17. When env already ends with `\n`, we don't
  double it. `TestFormatSpecialistSection_BashByteParity` locks all
  four shapes (trailing/no-trailing newline, multi-line, empty).
- `SpecialistDecision` enum (Passthrough/Rework/Exhausted) +
  `RouteSpecialistRework(env, budget)` returns the three-branch
  classification mapping 1:1 to bash review_helpers.sh.

### Goal 4 — Testdata fixtures (`internal/review/testdata/`)

Ten fixtures cover the parser's behaviour space:

| Fixture | Asserts |
|---------|---------|
| `approved.md` | Verdict=APPROVED, 0 blockers |
| `approved_with_notes.md` | APPROVED_WITH_NOTES, ≥3 notes |
| `changes_complex_only.md` | 2 complex, 0 simple |
| `changes_simple_only.md` | 0 complex, 3 simple |
| `changes_mixed.md` | 2 complex + 2 simple |
| `replan_required.md` | REPLAN_REQUIRED + 1 complex (scope drift) |
| `inline_verdict_fallback.md` | Inline-fallback path → APPROVED |
| `acp_verdicts_present.md` | 3 ACP rows ACCEPT/REJECT/MODIFY |
| `specialist_blockers_present.md` | SpecialistSection populated |
| `synthesized_at_max.md` | Byte-for-byte bash synthesize template |

### Goal 5 — Coverage + tests

Three test files (`parser_test.go`, `cycle_test.go`, `specialist_test.go`)
yield **96.3% line coverage** for the package — well above the 85% target.

`go test ./internal/review/...` passes; `go vet ./internal/review/...`
clean; `gofmt -l internal/review/` empty. Full `go test ./internal/...`
suite passes without regression (36 packages all green).

## Root Cause (bugs only)

N/A — m37.1 is a pure port milestone (creates a new Go package; deletes
no bash). No bug fix component.

## Files Modified

### Created (NEW)

- `internal/review/parser.go` (NEW, 330 lines) — `Report`, `Verdict`,
  `ACPVerdict`, `ParseReviewerReport`, `ParseReader`, accessor methods,
  internal parser state machine.
- `internal/review/parser_test.go` (NEW, 336 lines) — table-driven
  fixture tests + RawBody round-trip + inline-fallback priority +
  "None"-sentinel case sensitivity + ACP-row delimiter leniency.
- `internal/review/cycle.go` (NEW, 67 lines) — `CycleBudget` value type
  with `Increment` (pointer receiver), `Remaining`, `IsLastCycle`,
  `IsExhausted`, `BumpFromUsage` methods.
- `internal/review/cycle_test.go` (NEW, 163 lines) — per-method tests
  + 10-row `BumpFromUsage` table + receiver-invariance assertion.
- `internal/review/specialist.go` (NEW, 82 lines) — `HasSpecialistBlockers`,
  `FormatSpecialistSection`, `RouteSpecialistRework`,
  `SpecialistDecision` enum.
- `internal/review/specialist_test.go` (NEW, 131 lines) — per-function
  tables covering empty/None/content branches + byte-parity check on
  `FormatSpecialistSection`.
- `internal/review/testdata/approved.md` (NEW)
- `internal/review/testdata/approved_with_notes.md` (NEW)
- `internal/review/testdata/changes_complex_only.md` (NEW)
- `internal/review/testdata/changes_simple_only.md` (NEW)
- `internal/review/testdata/changes_mixed.md` (NEW)
- `internal/review/testdata/replan_required.md` (NEW)
- `internal/review/testdata/inline_verdict_fallback.md` (NEW)
- `internal/review/testdata/acp_verdicts_present.md` (NEW)
- `internal/review/testdata/specialist_blockers_present.md` (NEW)
- `internal/review/testdata/synthesized_at_max.md` (NEW)

### Modified

- `VERSION` — 4.45.1 → 4.45.2 (patch bump per m37.1 dogfood precedent).
- `.tekhton/CODER_SUMMARY.md` — this file.

## Docs Updated

None — no public-surface changes in this task.

The new `internal/review/` package is an internal Go-only surface
consumed in-process by the m37.2 stage port; no CLI subcommands, no
config keys, no prompt template variables, no exported `pkg/api/`
surface. The ARCHITECTURE.md "## System Map" entry for `internal/review/`
is m37.2's responsibility (added together with the stage port and the
bash deletes), per the wedge discipline that ARCHITECTURE.md entries
land with the milestone that retires the bash they describe.

## Human Notes Status

N/A — no human notes injected this run.

## Acceptance Criteria Verification

- [x] `parser.go` exports `Report`, `Verdict`, `ACPVerdict`,
      `ParseReviewerReport`, methods `HasComplexBlockers`,
      `HasSimpleBlockers`, `IsApproved`, `AcceptedACPs` — verified by
      `grep -nE '^func' parser.go` (13 funcs) and `go doc ./internal/review`.
- [x] `approved.md` → `Verdict=Approved`, `HasComplexBlockers()==0` —
      passes in `TestParseReviewerReport_Fixtures/approved`.
- [x] `inline_verdict_fallback.md` → `Verdict=Approved` (fallback path) —
      passes in `TestParseReviewerReport_Fixtures/inline_verdict_fallback`.
- [x] `changes_mixed.md` → 2 complex AND 2 simple — passes in
      `TestParseReviewerReport_Fixtures/changes_mixed`.
- [x] `acp_verdicts_present.md` → 3 ACPVerdicts in ACCEPT/REJECT/MODIFY
      order; `AcceptedACPs()` returns the single ACCEPT — passes in
      `TestParseReviewerReport_AcceptedACPs` and
      `TestParseReviewerReport_ACPVerdictsOrder`.
- [x] `cycle.go` exports `CycleBudget` with 5 methods — verified by
      `grep -nE '^func \(c \*?CycleBudget\)'` returning 5 lines.
- [x] `CycleBudget{0,3}` after 3 `Increment()` → `IsExhausted()==true`
      AND `IsLastCycle()==true` — passes in `TestCycleBudget_Increment`.
- [x] `BumpFromUsage(17, 20, 60) == (25, true)` AND
      `BumpFromUsage(58, 60, 60) == (60, false)` — both rows pass in
      `TestCycleBudget_BumpFromUsage`.
- [x] `specialist.go` exports `HasSpecialistBlockers`,
      `FormatSpecialistSection`, `RouteSpecialistRework` — verified by
      `grep -nE '^func '` returning 3 lines.
- [x] `HasSpecialistBlockers("None") == false` AND
      `HasSpecialistBlockers("- broken auth on /admin") == true` —
      passes in `TestHasSpecialistBlockers`.
- [x] `FormatSpecialistSection("- broken auth") ==
      "\n## Specialist Blockers\n- broken auth\n"` byte-for-byte —
      passes in `TestFormatSpecialistSection_BashByteParity`.
- [x] `RouteSpecialistRework` branches: Exhausted at {3,3}, Rework at
      {1,3}, Passthrough at "None"/{0,3} — passes in
      `TestRouteSpecialistRework`.
- [x] `go test -cover ./internal/review/...` reports **96.3%**
      (>= 85% required).
- [x] All ten fixture files exist and are referenced in the table-driven
      tests — verified by `ls internal/review/testdata/` and the
      `TestParseReviewerReport_Fixtures` table.
- [x] `internal/stages/review/` does NOT exist (m37.2 deliverable) —
      verified by `test -d ...` returning false.
- [x] `stages/review.sh` and `stages/review_helpers.sh` remain on disk
      untouched — verified by `git status --porcelain | grep stages/review`
      returning empty.
- [x] No imports from `internal/orchestrate` or `internal/stagerunner` —
      verified by `go list -deps ./internal/review/...` returning only
      the package itself (no other internal/* deps).
- [x] `go vet ./internal/review/...` exits 0; `gofmt -l internal/review/`
      empty.
- [x] No regression in `internal/intake/` tests — passes in cached
      `go test ./internal/intake/...`.

## Watch For Items Addressed

- **Self-driving dogfood:** Not a testable post-condition; the run is
  driven by Tekhton (per the milestone's own Watch For note).
- **Completion-gate false-halt exposure:** m45 is already done (current
  branch `theseus/Phase2`, HEAD includes the m45 commit), so this
  Watch For is now a non-issue per the milestone's own observation.
- **Inline-fallback verdict priority order:** locked in by
  `TestInlineVerdictFallback_Priority` (CHANGES_REQUIRED beats APPROVED)
  and `TestInlineVerdictFallback_ReplanWins` (REPLAN_REQUIRED beats both).
- **"None" sentinel case + shape sensitivity:** locked in by
  `TestNoneSentinelRE_CaseSensitive` and
  `TestNoneSentinel_OptionalDashAndWhitespace`. Lower-case "none" is NOT
  matched as the sentinel (matches bash regex byte-for-byte).
- **`Report.RawBody` byte-for-byte preservation:** `ParseReviewerReport`
  uses `os.ReadFile` then stores the result in `RawBody` before parsing.
  `TestParseReviewerReport_RawBody_RoundTrip` asserts byte equality
  against three fixtures.
- **Leaf-package discipline:** `go list -deps` returns only the package
  itself; no orchestrate/stagerunner imports.
- **ACP-row delimiter leniency:** both em-dash AND hyphen forms parse;
  whitespace REQUIRED around the delimiter so "parser-leaf-discipline"
  names don't mis-segment. Both shapes covered in the fixture
  `acp_verdicts_present.md` (rows 1 and 2 use different delimiters).
- **`BumpFromUsage` does not mutate receiver:**
  `TestCycleBudget_BumpFromUsage` asserts post-call `c.Current`/`c.Max`
  unchanged.
- **`FormatSpecialistSection` byte parity:**
  `TestFormatSpecialistSection_BashByteParity` locks the four expected
  byte sequences.

## Observed Issues (out of scope)

None. The work is narrowly scoped to the new `internal/review/` package
and a one-line VERSION bump; no drive-by cleanup was performed.

## Architecture Change Proposals

None. The new `internal/review/` package is a leaf addition following
the m36.2 → m36.3 / m17 → m22 wedge pattern: pure-logic helpers land in
their own milestone, the stage orchestrator port (m37.2) consumes them
and retires the bash. No new cross-package dependencies; no changes to
the prompt template engine, the proto contracts, or the bash↔Go seam.
ARCHITECTURE.md updates land with m37.2 alongside the bash deletes
(consistent with the convention used by m17, m22, m30 — the architecture
entry describes the closed wedge, not the open one).

## Design Observations

The milestone design says to "import M36.2's verdict-token helpers" for
case-insensitive token matching. On inspection, the M36.2 helpers
(`internal/intake/verdict.go`, `helpers.go`) are tightly bound to the
intake verdict vocabulary (PASS / TWEAKED / SPLIT_RECOMMENDED /
NEEDS_CLARITY) and the token classification logic is not exported in a
shape `internal/review/` can consume — the helpers `scanSectionFirstNonEmpty`,
`extractSection`, and `stripSpace` are package-private; the public
`Helpers.ParseVerdict` parses intake verdicts only.

Re-implementing the parsing inline in `internal/review/parser.go` is the
cleanest path: the review parser needs different vocabulary anchors
(four review tokens, not four intake tokens), different priority order
in the fallback, different section names, and a different "None"
sentinel predicate. The shared concept here is "scan for tokens in
priority order" — that's three lines of Go and not worth a shared
package for two consumers with different vocabularies.

This matches the milestone's own Seeds Forward note: "Shared
verdict-classifier package (post-M39 candidate): M36.2's
`internal/intake/` verdict helpers and M37.1's `internal/review/` parser
share token classification logic. After all stage ports complete (M39),
an extraction into a shared `internal/verdict/` package is reasonable."
The aspirational sharing is recorded as a Seeds Forward, not enforced
in m37.1.
