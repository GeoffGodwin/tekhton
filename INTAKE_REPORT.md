## Verdict
TWEAKED

## Confidence
55

## Reasoning
- Core intent is clear: when self-tests fail, auto-seed a fix run rather than exiting
- "trivial" is undefined — two developers would implement this differently (one retries always, one adds heuristics)
- "non-pristine state" is a goal statement, not a testable criterion
- No acceptance criteria, no files-to-modify list, no Watch For section
- Critical edge cases are unspecified: what happens if the fix run also fails? Infinite loop risk
- "self-tests" is ambiguous — tekhton's own `tests/run_tests.sh`, or the target project's test suite?

## Tweaked Content

[BUG] Pipeline exits with "failures detected" when self-tests fail instead of auto-seeding a fix run

**Context:** When the tester stage detects test failures (exit code from `TEST_CMD` or tekhton's own `tests/run_tests.sh`), the pipeline currently terminates with a "failures detected" message. It should instead capture the failure output and immediately invoke a new pipeline run scoped to fixing those failures.

**Scope:**
- Applies to target project test failures detected at the tester stage gate
- [PM: "trivial" is interpreted as: trigger auto-fix unconditionally, cap at 1 auto-fix attempt to prevent infinite loops]
- [PM: "self-tests" clarified to mean the target project's `TEST_CMD` failures, not tekhton's own test suite]

**Behavior:**
1. When the tester stage fails its acceptance gate, capture the test failure output
2. Format the failure output into a task string (e.g., `"Fix failing tests:\n<captured output>"`)
3. Invoke `tekhton.sh "<task>"` in the same project directory
4. If the follow-up run succeeds, the pipeline exits clean (exit 0)
5. If the follow-up run also fails, exit with the original failure (no further recursion)

**Files likely modified:**
- `stages/tester.sh` — detect failure, format task, invoke follow-up run
- `lib/gates.sh` — expose test failure output for capture
- `pipeline.conf.example` — document new config keys [PM: see Migration Impact]

**Acceptance criteria:**
- [PM: added — these were missing] When `TEST_CMD` exits non-zero, pipeline captures stdout+stderr and invokes a new `tekhton.sh` run rather than exiting with "failures detected"
- Follow-up run is invoked with a task string containing the captured failure output
- If follow-up run exits 0, outer pipeline also exits 0
- If follow-up run exits non-zero, outer pipeline exits with original failure code (no recursion)
- A config key `AUTO_FIX_ON_TEST_FAILURE` (default: `false`) gates this behavior — existing pipelines are unaffected
- `AUTO_FIX_MAX_DEPTH` (default: `1`) prevents recursive fix loops
- Existing pipelines with this feature disabled see identical behavior to today

**Watch For:**
- [PM: added] Infinite loop risk: guard with `TEKHTON_FIX_DEPTH` environment variable that the spawned process can detect to block further recursion
- Captured test output may be very large — truncate to a configurable character limit before injecting into the task string (default: 4000 chars)
- The spawned run must inherit the parent's `PROJECT_DIR` and config path, not re-detect from CWD

**Migration Impact:**
- [PM: added — required for new config keys] Two new opt-in config keys in `pipeline.conf`:
  - `AUTO_FIX_ON_TEST_FAILURE=false` — enable the behavior
  - `AUTO_FIX_MAX_DEPTH=1` — max recursive fix attempts
- No changes to existing `pipeline.conf` files are required; keys default to off
