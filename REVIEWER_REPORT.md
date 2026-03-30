# Reviewer Report

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/plan_server.sh` is 370 lines, exceeding the 300-line ceiling. This is pre-existing (the fix touched only one line). Flag for a future extraction pass.

## Coverage Gaps
- None

## Drift Observations
- None

---

## Review Notes

Both fixes are correct.

**Port detection (`lib/plan_server.sh:41-43`):** The old pattern `:${port} ` required a trailing space, which `ss -tlnp` does not guarantee (output may use tabs or have the port at end-of-line). The new pattern `:${port}([^0-9]|$)` with `-qE` correctly anchors to non-digit or end-of-line, preventing both false positives (prefix matching) and false negatives (non-space delimiters). The test harness now uses a Python-bound socket with a ready-poll loop plus a graceful skip path when the dummy port cannot be occupied — this avoids the orphaned-process leak described in the test file comment.

**Awk `&` escaping (`lib/plan_browser.sh:141-146`):** The root cause was correct: in awk's `gsub()`, `&` in the replacement string means "the matched text". When `pname` or `ptype` held HTML-escaped values like `&amp;`, the `&` was expanded to `{{PROJECT_NAME}}`, producing `{{PROJECT_NAME}}amp;` in the output. The `BEGIN` block's `gsub(/&/, "\\\\&", pname)` replaces each `&` with `\&` in the awk variable (four shell-literal backslashes in the awk source → two awk-string backslashes → awk gsub replacement `\\&` → one literal `\` + matched `&` = `\&`). When the main-body gsub then uses `pname` as a replacement, `\&` → literal `&`. Chain is sound.
