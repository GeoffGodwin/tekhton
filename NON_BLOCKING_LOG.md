# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-24 | "Implement Milestone 18: Documentation Site (MkDocs + GitHub Pages)"] `tests/test_docs_site.sh:260` — The first condition `grep -q '--docs' "$TEKHTON" | grep -q 'documentation' 2>/dev/null` pipes a quiet (no-output) grep into a second grep, making the second grep receive empty input and always fail. The test still passes because the `||` chain falls through to working alternatives, but the first clause is effectively dead code. Simplify to just the third clause: `grep '--docs' "$TEKHTON" | grep -q 'documentation'`.
- [ ] [2026-03-24 | "Implement Milestone 18: Documentation Site (MkDocs + GitHub Pages)"] `docs/guides/watchtower.md` — No screenshots present. The milestone's Watch For section explicitly called out that screenshots need to be generated from a real dashboard with sample data in `docs/assets/screenshots/`. The guide is textually complete but visual aids would improve it.

## Resolved
