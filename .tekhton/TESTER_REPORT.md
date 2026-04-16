## Planned Tests
- [x] `tests/test_audit_sampler.sh` — verify M89 rolling sampler: K-file sampling, history dedup, oldest-first ordering, current-set dedup, disabled toggle, JSONL record append, pruning
- [x] `tests/test_tekhton_dir_root_cleanliness.sh` — fix pre-existing environmental failure: exclude `TEST_SYMBOL_MAP_FILE` (runtime variable, not a config default)

## Test Run Results
Passed: 372  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_audit_sampler.sh`
- [x] `tests/test_tekhton_dir_root_cleanliness.sh`
