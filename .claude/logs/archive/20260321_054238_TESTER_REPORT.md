## Planned Tests
- [x] `tests/test_init_addenda_dedup.sh` — _append_addenda: same-filename addendum not appended twice when two languages resolve to the same addendum file

## Test Run Results
Passed: 4  Failed: 1

## Bugs Found
- BUG: [lib/init.sh:238-244] _append_addenda has no deduplication: when the same language name appears twice in the languages list, its addendum file is appended twice to the target role file

## Files Modified
- [x] `tests/test_init_addenda_dedup.sh`
