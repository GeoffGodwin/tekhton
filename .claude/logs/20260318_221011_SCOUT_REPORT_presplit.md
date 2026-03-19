# Scout Report: Milestone 13 — Transient Error Retry Loop

## Relevant Files
- lib/agent.sh — Core agent invocation wrapper; requires _retry_agent() envelope with exponential backoff
- lib/agent_monitor.sh — Agent monitoring infrastructure; requires _reset_monitoring_state() helper to cleanly re-initialize FIFO and activity state between retries
- lib/config.sh — Configuration loader; requires retry config defaults (MAX_TRANSIENT_RETRIES, TRANSIENT_RETRY_BASE_DELAY, TRANSIENT_RETRY_MAX_DELAY, TRANSIENT_RETRY_ENABLED)
- lib/common.sh — Logging utilities; requires report_retry() function for formatted retry notices with backoff info
- lib/errors.sh — Error classification engine (already exists from M12); provides classify_error() and is_transient() needed for transience detection
- lib/metrics.sh — Run metrics recording; requires retry_count field in JSONL records to track retry attempts per invocation
- stages/coder.sh — Coder stage execution; no OOM retry special case found (unlike tester)
- stages/tester.sh — Tester stage; has OOM retry special case at lines 52-57 that must be removed (will be subsumed by generic M13 retry)
- templates/pipeline.conf.example — Configuration template; requires retry config keys with inline documentation

## Key Symbols
- run_agent — lib/agent.sh (entry point for all agent invocations; ~line 51)
- _invoke_and_monitor — lib/agent_monitor.sh (agent process lifecycle and FIFO monitoring)
- classify_error — lib/errors.sh (parses exit code, stderr, output to classify error; ~line 40)
- is_transient — lib/errors.sh (returns 0 if category/subcategory is retryable; ~line 266)
- report_error — lib/common.sh (boxed error reporting; ~line 47; report_retry will be similar pattern)
- LAST_AGENT_EXIT_CODE — lib/agent.sh (captured exit code for error classification; ~line 40)
- AGENT_ERROR_TRANSIENT — lib/agent.sh (boolean set by classify_error; ~line 47)
- _FIFO — lib/agent_monitor.sh (FIFO pipe for agent output streaming; requires cleanup on retry)
- record_run_metrics — lib/metrics.sh (appends JSONL record; ~line 55)

## Suspected Root Cause Areas
- lib/agent.sh run_agent() function: requires wrapping of _invoke_and_monitor() call with retry envelope after error classification
- lib/agent_monitor.sh FIFO lifecycle: requires explicit _reset_monitoring_state() to kill stale readers and remove temp files before retry attempt
- lib/agent.sh error classification integration: classify_error() must be called after agent exit and before null-run detection to prevent misclassification of API errors as null runs
- stages/tester.sh lines 52-57: existing SIGKILL retry special case must be removed to prevent double-retry (once in wrapper, once in stage)
- lib/config.sh defaults section: retry config keys must be added and properly defaulted to match M13 spec
- lib/metrics.sh record_run_metrics(): must capture and include retry_count in JSONL to enable metrics-driven adaptive retry calibration in future milestones

## Complexity Estimate
Files to modify: 9
Estimated lines of change: 400
Interconnected systems: high
Recommended coder turns: 70
Recommended reviewer turns: 14
Recommended tester turns: 50
