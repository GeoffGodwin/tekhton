## Planned Tests
- [x] `tests/test_plan_browser.sh` — Verify port detection and HTML escaping fixes

## Test Run Results
Passed: 26  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_plan_browser.sh` — Added/updated tests for port detection and HTML escaping fixes
- [x] `lib/plan_server.sh:41-43` — Bug 1 fix: Changed grep pattern from `:${port} ` to `:${port}([^0-9]|$)` to correctly skip occupied ports
- [x] `lib/plan_browser.sh:141-146` — Bug 2 fix: Added awk BEGIN block to escape `&` in replacement variables before gsub()

## Verification Summary

### Bug 1: Port Detection (lib/plan_server.sh:41-43)
**Status:** VERIFIED FIXED
- **Test:** "Port finding (occupied port)" (line 263-318)
- **Verification:** Test correctly skips an occupied port (58432) and finds an alternative (58433)
- **Fix Validation:** Regex pattern `:${port}([^0-9]|$)` with `-qE` flag correctly matches port delimiters regardless of spacing/tabs/EOL

### Bug 2: HTML Escaping (lib/plan_browser.sh:141-146)
**Status:** VERIFIED FIXED
- **Test:** "HTML escaping works for special characters" (line 321-329)
- **Verification:** Test confirms `&`, `<`, `>`, `"` are properly escaped to `&amp;`, `&lt;`, `&gt;`, `&quot;`
- **Fix Validation:** Awk BEGIN block escapes `&` in replacement variables before gsub() uses them, preventing double-encoding

### Test Coverage
All 26 tests in the planning form test suite pass, including:
- Form generation and structure validation
- Port detection (free and occupied)
- HTML escaping for special characters
- Python server script syntax validation
- Pre-population and resume functionality
- Browser interview mode selection
- Ampersand single-encoding verification (Bug 2 fix validation)
- Awk BEGIN block double-encoding prevention (Bug 2 fix integration)

## Audit Rework

### INTEGRITY: Implementation files undeclared in report
- [x] Fixed: Updated TESTER_REPORT.md "Files Modified" section to explicitly list `lib/plan_server.sh:41-43` and `lib/plan_browser.sh:141-146` with descriptions of each change. An auditor can now read the report and understand implementation changes without consulting git diff.

### EXERCISE: HTML escaping test does not exercise actual Bug 2 fix
- [x] Fixed: Added test "Awk BEGIN block prevents double-encoding in form" (test_plan_browser.sh:340-350) that:
  - Sets project type to "web & mobile" (contains ampersand)
  - Generates a full form via `_generate_plan_form`
  - Verifies form HTML contains `web &amp; mobile` (single-encoded) not `web &amp;amp; mobile` (double-encoded)
  - This directly exercises the awk BEGIN block fix path at lib/plan_browser.sh:141-146

### COVERAGE: Occupied-port test soft-passes when socket bind fails
- [x] Fixed: Replaced soft-pass with neutral skip at test_plan_browser.sh line 311. Now outputs "SKIP: could not bind dummy port" without incrementing PASS count, making infrastructure failures visible while not blocking the pipeline.

### COVERAGE: HTML escape test omits ampersand
- [x] Fixed: Added test "Ampersand encodes to &amp; (single-encoded)" at test_plan_browser.sh:335-337 that verifies `_html_escape 'a & b'` produces exactly `a &amp; b`.
