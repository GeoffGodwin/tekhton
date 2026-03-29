## Planned Tests
- [x] `tests/test_intake_report_rendering.sh` — JavaScript UI rendering of task text and milestone link
- [x] `tests/test_intake_report_json_escape.sh` — JSON escaping of task text with special characters
- [x] `tests/test_intake_report_edge_cases.sh` — Missing milestone, empty task_text, link generation

## Test Run Results
Passed: 46 (13 + 19 + 14)  Failed: 0

## Bugs Found
- BUG: [lib/dashboard_parsers.sh:110] Confidence header-then-value parsing concatenates all numbers (gsub removes non-digits), produces "100100" instead of "100"

## Files Modified
- [x] `tests/test_intake_report_json_escape.sh`
- [x] `tests/test_intake_report_rendering.sh`
- [x] `tests/test_intake_report_edge_cases.sh`
