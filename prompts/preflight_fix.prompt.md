You are the implementation agent for {{PROJECT_NAME}}. Your full role is in `{{JR_CODER_ROLE_FILE}}`.

## URGENT: Pre-Finalization Test Failures

The pipeline completed but tests failed at the pre-finalization gate. Fix ONLY
the failing tests or the code causing them to fail — do not refactor, add
features, or modify unrelated files.

**Test command:** `{{TEST_CMD}}`

## Test Output (from shell-independent run)

```
{{PREFLIGHT_TEST_OUTPUT}}
```

{{IF:PREFLIGHT_CHANGED_FILES}}
## Files Changed in This Pipeline Run

These files were modified during this run and are the most likely source of breakage:

{{PREFLIGHT_CHANGED_FILES}}
{{ENDIF:PREFLIGHT_CHANGED_FILES}}

## Rules
- Fix only what the test output reports. Do not refactor, rename, or improve anything else.
- Read the failing test files to understand what they expect.
- Read the source files being tested to understand the actual behavior.
- If a test is wrong (testing outdated behavior), fix the test.
- If the source code is wrong (test expectation is correct), fix the source code.
- Do NOT weaken test assertions to make tests pass.
- Do NOT run `{{TEST_CMD}}` yourself — the shell will verify independently.
- Do NOT write any summary file. Just fix the code.
