# Reviewer Report — Milestone 18: Documentation Site (MkDocs + GitHub Pages)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `tests/test_docs_site.sh:260` — First arm of the `||` chain uses `grep -q ... | grep -q ...`. The `-q` flag suppresses stdout, so the second grep always receives empty input and returns 1. The test still passes via the third fallback condition (`grep '\-\-docs' "$TEKHTON" | grep -q 'documentation'`), but the first arm is dead logic that could confuse future maintainers.
- `mkdocs.yml` `repo_name` uses `GeoffGodwin/tekhton` (capital G) while the milestone spec template shows lowercase `geoffgodwin/tekhton`. Both are equivalent on GitHub, but the inconsistency is worth noting if the canonical display name matters.
- Watchtower guide (`docs/guides/watchtower.md`) references screenshots per the milestone "Watch For" note, but no `docs/assets/screenshots/` directory was created. The spec notes these should come from a real dashboard — this is a known deferred item, not a correctness issue.

## Coverage Gaps
- None

## ACP Verdicts
None present in CODER_SUMMARY.md.

## Drift Observations
- `docs.yml` workflow adds `contents: read` permission not in the milestone template — this is correct and follows GitHub's least-privilege Pages deployment pattern. No concern, just noting it diverges from the spec template intentionally.
