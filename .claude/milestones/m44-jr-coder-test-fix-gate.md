# Milestone 44: Jr Coder Test-Fix Gate
<!-- milestone-meta
id: "44"
status: "pending"
-->

## Overview

Even with test-aware coding (M43), some test failures will still slip through to
the pre-finalization gate. Currently, any new test failure at this point triggers
a full pipeline retry (Coder→Reviewer→Tester) — the most expensive recovery
path. This milestone inserts a cheap Jr Coder fix attempt before the full retry,
preventing disproportionate reruns for trivial test breakage.

The lightweight fix agent in `hooks.sh:309-351` (`FINAL_FIX_ENABLED`) already
exists but fires only at finalization — after the orchestration loop is
exhausted. This milestone moves that concept earlier in the flow.

Depends on Milestone 43 (Test-Aware Coding) which addresses the root cause;
this milestone is the safety net.

## Scope

### 1. Pre-Finalization Fix Loop

**File:** `lib/orchestrate.sh` (lines 251-287)

When the pre-finalization test gate detects new failures, insert a Jr Coder fix
loop before the existing full-retry logic:

```
Tests fail → Jr Coder fix attempt (Haiku, ~15-20 turns)
  → Shell independently runs TEST_CMD (agent never sees its own output)
  → Pass? → Proceed to finalization
  → Fail? → Toss back to Jr Coder with shell's test output
  → Still fail after PREFLIGHT_FIX_MAX_ATTEMPTS? → Fall through to full retry
```

**Key design: shell-verified testing.** The Jr Coder fixes code and the shell
independently runs `TEST_CMD`. The Jr Coder never sees test output it generated
itself — only the shell's independent verification. This prevents the agent from
"fixing" tests by weakening assertions.

### 2. Configuration

**File:** `lib/config_defaults.sh`

New config keys:
- `PREFLIGHT_FIX_ENABLED` (default: true)
- `PREFLIGHT_FIX_MAX_ATTEMPTS` (default: 2)
- `PREFLIGHT_FIX_MODEL` (default: `${CLAUDE_JR_CODER_MODEL}`)
- `PREFLIGHT_FIX_MAX_TURNS` (default: `${JR_CODER_MAX_TURNS}`)

### 3. Fix Prompt Template

**File:** `prompts/preflight_fix.prompt.md` (new)

The fix agent receives:
- Test command output (from shell's independent run)
- List of files changed in this pipeline run (from CODER_SUMMARY.md)
- Error details and failure context

Constraints:
- Fix the failing tests or the code causing them to fail
- Do NOT refactor, do NOT add features, do NOT modify unrelated files
- Do NOT weaken test assertions to make them pass

### 4. Helper Function

**File:** `lib/orchestrate_helpers.sh`

New function `_try_preflight_fix()` encapsulating:
- Jr Coder agent invocation with fix prompt
- Shell-side `TEST_CMD` re-run
- Retry loop with attempt counter
- Causal log events for fix attempts

## Acceptance Criteria

- When 1-2 tests fail at run end, Jr Coder fix is attempted before full retry
- Tests are run by the shell, not by the fix agent
- If Jr Coder fixes the issue, no full pipeline retry occurs
- If Jr Coder fails after max attempts, existing retry logic fires unchanged
- `PREFLIGHT_FIX_ENABLED=false` restores existing behavior exactly
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified/new files
- New test covering the fix-before-retry flow

Tests:
- Preflight fix config defaults are set correctly
- `_try_preflight_fix()` returns 0 when fix succeeds, 1 when exhausted
- Shell runs `TEST_CMD` independently after each fix attempt
- Full retry fires only after preflight fix is exhausted
- `PREFLIGHT_FIX_ENABLED=false` skips the fix loop entirely

Watch For:
- The Jr Coder must not have access to run `TEST_CMD` itself — only the shell
  runs tests. The agent's tool allowlist should be `AGENT_TOOLS_BUILD_FIX`
  (Edit, Read, Glob, Grep — no Bash test execution).
- The fix prompt must include enough test output context for the agent to
  diagnose the issue. Last 80-120 lines of test output should suffice.
- Count preflight fix agent calls toward `TOTAL_AGENT_INVOCATIONS` and
  `MAX_AUTONOMOUS_AGENT_CALLS` safety valve.
- If the fix introduces new failures (not just failing to fix the original),
  abort immediately rather than retrying.

Seeds Forward:
- Milestone 46 (Instrumentation) will measure how often the fix gate saves
  a full retry
- This pattern (cheap agent fix before expensive retry) could extend to
  build gate failures in a future milestone
