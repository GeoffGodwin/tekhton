## Planned Tests
- [x] `tests/test_plan_generate_integration.sh` — Integration test for run_plan_generate() post-processing: mock _call_planning_batch, verify CLAUDE.md written + milestones extracted into DAG files + pointer inserted
- [x] `tests/test_find_next_milestone_dag.sh` — DAG-aware ordering in find_next_milestone(): respects dependency edges, falls back to inline when no manifest

## Test Run Results
Passed: 25  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_plan_generate_integration.sh`
- [x] `tests/test_find_next_milestone_dag.sh`
