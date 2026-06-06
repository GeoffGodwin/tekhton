# Reviewer Report — m37.1 Review Helpers and Parser (Cycle 2)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `ParseReader` is exported (uppercase P) while the milestone design showed a package-private `parseReader`. Harmless in an `internal/` package — no outside-module caller can reach it, and the test package uses `package review` so it can access unexported names equally well. No functional impact.
- `extractVerdictFromAccum` skips blank lines when searching for the verdict token, making it subtly more robust than bash's `grep -A1 | tail -1` (which takes the immediately-next line regardless of whether it's blank). The implementation comment on the heading-anchored path should note this deliberate parity deviation so future readers understand it. Not a regression — a behavioral improvement.

## Coverage Gaps
- None

## Drift Observations
- `synthesized_at_max.md` uses `"None (reviewer did not report)"` as the sentinel text in both blocker sections. This does NOT match `noneSentinelRE` (`^-?\s*None\s*$` requires no trailing text), so `HasComplexBlockers()` returns 1 for this fixture. The test explicitly exempts `synthesized_at_max` from blocker count assertions. Worth confirming the bash synthesizer template and the parser sentinel are aligned — if the bash template uses this exact phrasing, the bash `grep -c "^- "` count would also treat it as a blocker.
