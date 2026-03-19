## Relevant Files
- lib/agent.sh — Core agent invocation wrapper; needs retry envelope around _invoke_and_monitor() and retry loop logic
- lib/agent_monitor.sh — Already has _reset_monitoring_state() (M13.1) for cleaning FIFO/ring buffer between retries
- lib/config.sh — Already has retry config defaults (MAX_TRANSIENT_RETRIES, TRANSIENT_RETRY_BASE_DELAY, TRANSIENT_RETRY_MAX_DELAY, TRANSIENT_RETRY_ENABLED) from M13.1
- lib/errors.sh — Already has classify_error() and is_transient() functions (M13.1); needed for transient detection
- lib/errors_helpers.sh — Already has suggest_recovery() function used for recovery messaging
- lib/common.sh — Already has report_retry() function (M13.1) for formatted retry notices
- lib/metrics.sh — Missing retry_count field; needs to add field to JSONL record and read LAST_AGENT_RETRY_COUNT
- stages/tester.sh — Has tester-specific OOM retry block (lines 51-66) that must be removed; this is the only stage-level retry logic that conflicts

## Key Symbols
- run_agent() / lib/agent.sh:51 — Main agent invocation wrapper; wrap _invoke_and_monitor call with retry envelope
- _invoke_and_monitor() / lib/agent_monitor.sh:114 — Monitor infrastructure; called from inside run_agent(); already handles FIFO/activity/timeout
- _reset_monitoring_state() / lib/agent_monitor.sh:335 — Cleans FIFO/temp files between retries; already implemented from M13.1
- classify_error() / lib/errors.sh:55 — Error classification; already called at line 190 of agent.sh
- is_transient() / lib/errors.sh:266 — Checks if error category/subcategory is transient
- report_retry() / lib/common.sh:118 — Prints formatted retry notice; already exists from M13.1
- AGENT_ERROR_CATEGORY / lib/agent.sh:45 — Set by classify_error(); used to determine if error is retryable
- AGENT_ERROR_TRANSIENT / lib/agent.sh:47 — Set by classify_error(); true if error is transient
- LAST_AGENT_EXIT_CODE / lib/agent.sh:40 — Existing exit code tracking; needed for retry logic
- LAST_AGENT_RETRY_COUNT / lib/agent.sh — NEW; needs initialization at line ~43 alongside other LAST_AGENT_* globals
- record_run_metrics() / lib/metrics.sh:55 — Appends JSONL record; needs retry_count field added
- run_stage_tester() / stages/tester.sh:17 — Tester stage; contains OOM retry block at lines 51-66 that must be removed

## Suspected Root Cause Areas
- lib/agent.sh lacks the retry wrapper logic between agent exit detection (line 197) and the null-run classification (line 199); retry loop needs to wrap _invoke_and_monitor call at line 114
- lib/agent.sh missing initialization of LAST_AGENT_RETRY_COUNT variable; should be initialized alongside LAST_AGENT_TURNS and other exit detection globals at line ~38-42
- stages/tester.sh has redundant OOM retry at lines 51-66 that conflicts with generic retry infrastructure; must be removed entirely
- lib/metrics.sh missing retry_count field in JSONL record building (lines 130-158); field needs to be added and populated from LAST_AGENT_RETRY_COUNT
- Retry envelope needs to handle exponential backoff calculation with capping at TRANSIENT_RETRY_MAX_DELAY; exponential formula is TRANSIENT_RETRY_BASE_DELAY × 2^attempt capped at max
- Special handling needed for rate_limit (429): parse retry-after from last output if available, else minimum 60s
- Special handling needed for overloaded (529): minimum 60s wait
- Special handling needed for oom: minimum 15s wait (allow OS to reclaim memory)

## Complexity Estimate
Files to modify: 4
Estimated lines of change: 180
Interconnected systems: medium
Recommended coder turns: 40
Recommended reviewer turns: 10
Recommended tester turns: 30
