## Relevant Files

- stages/tester.sh — Contains the SIGKILL retry block (lines 51–66) that needs to be removed. This code was a tester-specific OOM retry that is now redundantly handled by the generic retry envelope from Milestone 13.2.1
- lib/metrics.sh — Needs to add retry_count field to the JSONL record in record_run_metrics() and add retry statistics to the summarize_metrics() output
- lib/agent.sh — Already declares LAST_AGENT_RETRY_COUNT global (line 47) which will be read by metrics. No changes needed.
- lib/agent_retry.sh — The retry envelope from 13.2.1 that sets LAST_AGENT_RETRY_COUNT. Referenced for context only, no changes needed.
- tests/test_metrics.sh — Existing metrics test suite that may need updates to verify retry_count tracking
- tests/test_run_with_retry_loop.sh — Already tests LAST_AGENT_RETRY_COUNT behavior, provides context for expected retry values

## Key Symbols

- was_null_run() — stages/tester.sh (helper function to detect null runs)
- LAST_AGENT_EXIT_CODE — lib/agent.sh line 44 (exit code from last agent invocation)
- LAST_AGENT_RETRY_COUNT — lib/agent.sh line 47 (retry count from last agent invocation)
- record_run_metrics() — lib/metrics.sh line 55 (appends JSONL record to metrics.jsonl)
- summarize_metrics() — lib/metrics.sh line 184 (prints metrics dashboard)
- _extract_stage_turns() — lib/metrics.sh line 167 (helper to extract stage turns from STAGE_SUMMARY)

## Suspected Root Cause Areas

- stages/tester.sh lines 51–66: SIGKILL retry block checks `was_null_run && LAST_AGENT_EXIT_CODE == 137` and calls sleep 15 then re-invokes agent. This is now handled by the generic retry envelope in lib/agent_retry.sh and must be removed to avoid double-retry.
- lib/metrics.sh around line 130–158: JSONL record construction needs to add retry_count field. Currently records context_tokens but not retry_count.
- lib/metrics.sh around line 235–283: summarize_metrics() output needs to include retry statistics (total retry count and average retries per invocation).

## Complexity Estimate

Files to modify: 2
Estimated lines of change: 25
Interconnected systems: low
Recommended coder turns: 20
Recommended reviewer turns: 5
Recommended tester turns: 15
