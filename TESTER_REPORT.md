## Planned Tests
(none)

## Test Run Results
Passed: 200  Failed: 0

## Bugs Found
- BUG: [lib/ui_validate_report.sh:13] duplicate set -euo pipefail statement appears at lines 2 and 13
- BUG: [lib/ui_validate.sh:19] duplicate set -euo pipefail statement appears at lines 2 and 19
- BUG: [lib/dashboard_emitters.sh:162] dep_arr variable used in read -ra but not declared local alongside other loop locals on line 162

## Files Modified
(none)
