# Reviewer Report — m36.2 Intake Helpers Port

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `verdict.go:126` — `os.Setenv("INTAKE_TWEAKS_BLOCK", tweaks)` inside the Go subprocess has no effect on the parent bash process. The comment says "The CLI shim re-exports via env" but no re-export mechanism exists in `cmd/tekhton/intake.go`. Parity is preserved only if `stages/intake.sh` separately calls `_intake_parse_tweaks` to populate `INTAKE_TWEAKS_BLOCK` in the bash environment. If that call does not exist or was removed, the scout prompt's `{{INTAKE_TWEAKS_BLOCK}}` block would silently be empty post-wedge. Recommend adding a comment clarifying that the `os.Setenv` is aspirational (for the M36.3 in-process stage only) and that the bash pipeline relies on the `parse-tweaks` subcommand for env propagation.
- `verdict.go:469-483` — `logf`, `warnf`, `successf`, and `headerf` are four methods with near-identical bodies; only `headerf` differs by writing to stdout rather than stderr. The bash originals carried colored prefix decoration (log/warn/success had visual distinction). For a transition shim this is acceptable, but `headerf`'s stdout vs stderr split is the only surviving semantic distinction and is not documented. A one-line comment noting the intent would prevent it from being collapsed to a single writer in M36.3.
- `verdict.go:198` — `extractSection(..., []string{"## "})` uses a bare two-character prefix as the stop sentinel when rendering the Split Recommendations block for display. This is intentional (display-only) but differs from the precise stop-list used elsewhere in the same call site. A `// display trim only` comment would clarify for future readers.

## Coverage Gaps
- `extractInlineMilestoneBlock` (helpers.go) — the stop regex `^#{1,5}\s` does not match H6 headings (`######`). An H6 inside a milestone block would not terminate the scan and the content would bleed into the next logical section. Unlikely in practice but untested.
- `insertAfterMetaBlock` fallback branch (helpers.go:445) — reached when a `milestone-meta` block has no `-->` terminator. The fallback calls `insertAfterFirstLine` correctly, but no test fixture exercises this path.

## ACP Verdicts
No `## Architecture Change Proposals` section in CODER_SUMMARY.md.

## Drift Observations
- `cmd/tekhton/intake.go:443` — `shimSplit` unconditionally returns an error ("not yet wired (m36.2)"). Correct for scope, but the wiring point is only annotated with the milestone name, not a reference to the M36.3 milestone file. Future contributors may not know where to find the follow-on work.
- `internal/intake/helpers.go:50-52` — `ContentHash` doc comment references `sha256sum` (Linux utility). On macOS the equivalent is `shasum -a 256`. The comment is accurate for CI but could mislead local debugging on macOS. Low impact since the Go implementation is correct on all platforms.
