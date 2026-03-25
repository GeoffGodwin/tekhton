## Planned Tests
- [x] `tests/test_init_merge_preserved.sh` — _merge_preserved_values() edge cases: path values with /, pipe, and ampersand
- [x] `tests/test_init_report_dashboard_compat.sh` — emit_init_report_file() metadata block matches emit_dashboard_init() parsing format

## Test Run Results
Passed: 22  Failed: 2

## Bugs Found
- BUG: [lib/init_config.sh:200] _merge_preserved_values() silently no-ops when preserved value contains `|` (extra sed delimiter splits command, sed errors but function returns 0 and leaves config key unchanged)
- BUG: [lib/init_config.sh:200] _merge_preserved_values() silently corrupts preserved value containing `&` (sed expands `&` as backreference to full matched line, producing garbled config value instead of the literal string)

## Files Modified
- [x] `tests/test_init_merge_preserved.sh`
- [x] `tests/test_init_report_dashboard_compat.sh`
