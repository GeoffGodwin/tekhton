## Planned Tests
- [x] `tests/test_dag_advance_parity.sh` — advance cross-process: Go CLI writes MANIFEST, bash _DAG_* arrays read it back correctly
- [x] `cmd/tekhton/dag_test.go` — edge paths: loadDagState via $MILESTONE_MANIFEST_FILE env, defaultManifestName with non-empty override

## Test Run Results
Passed: 20  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_dag_advance_parity.sh`
- [x] `cmd/tekhton/dag_test.go`
