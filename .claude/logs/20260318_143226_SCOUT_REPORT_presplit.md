# Scout Report: Milestone 12 - Observability & Error Attribution

## Relevant Files

- `lib/errors.sh` (NEW FILE) — Core error classification engine with taxonomy, transient detection, recovery suggestions, and redaction logic
- `lib/common.sh` — Add `report_error()` function for structured error reporting with boxed output and ASCII fallback
- `lib/agent.sh` — Capture stderr, call `classify_error()` after agent exit, maintain ring buffer of last 50 lines of output
- `lib/agent_monitor.sh` — Detect API error JSON patterns (500/502/503/429/529/auth errors) in real-time during FIFO monitoring, set flags for agent exit handler
- `lib/state.sh` — Extend `PIPELINE_STATE.md` format with error classification section (category, subcategory, transient flag, recovery suggestion, last 10 lines of output)
- `lib/metrics.sh` — Add error fields to JSONL records (`error_category`, `error_subcategory`, `error_transient`), extend `summarize_metrics()` dashboard with error breakdown
- `lib/hooks.sh` — Ensure `record_run_metrics()` is called on ALL exit paths (not just success), verify metrics capture on early exits
- `stages/coder.sh` — After agent completion, check `AGENT_ERROR_CATEGORY` and call `report_error()` for non-AGENT_SCOPE errors
- `stages/review.sh` — Same error classification check after reviewer completion
- `stages/tester.sh` — Same error classification check after tester completion
- `stages/architect.sh` — Same error classification check after architect agent completion

## Key Symbols

**New functions to create in `lib/errors.sh`:**
- `classify_error(exit_code, stderr_file, last_output_file)` — Returns `CATEGORY|SUBCATEGORY|TRANSIENT|MESSAGE`
- `is_transient(category, subcategory)` — Returns 0 for transient, 1 for permanent
- `suggest_recovery(category, subcategory, context)` — Returns human-readable recovery string
- `redact_sensitive(text)` — Strips API keys, auth tokens, and sensitive patterns

**New function to add to `lib/common.sh`:**
- `report_error(category, subcategory, transient, message, recovery)` — Prints boxed error report with Unicode fallback

**New globals in `lib/agent.sh` (after agent exit):**
- `AGENT_ERROR_CATEGORY` — Classification (UPSTREAM, ENVIRONMENT, AGENT_SCOPE, PIPELINE, or unset)
- `AGENT_ERROR_SUBCATEGORY` — Specific error type (api_500, null_run, disk_full, etc.)
- `AGENT_ERROR_TRANSIENT` — Boolean: true if error is transient
- `AGENT_ERROR_MESSAGE` — Diagnostic message

**Existing globals used:**
- `LAST_AGENT_EXIT_CODE` — Agent exit code (lines 36, 176 in agent.sh)
- `LAST_AGENT_NULL_RUN` — Null run flag (lines 38, 178 in agent.sh)
- `LAST_AGENT_TURNS` — Turns used (lines 35, 175 in agent.sh)

## Suspected Root Cause Areas

1. **Ring buffer implementation in `lib/agent_monitor.sh`** — Must maintain fixed-size circular buffer during FIFO read loop (lines 104-190). Variable-size arrays will leak memory on long-running agents (100+ turns).

2. **API error detection in `lib/agent_monitor.sh`** — Real-time pattern matching on JSON output stream must catch: `"type":"server_error"`, `"type":"rate_limit_error"`, `"type":"overloaded_error"`, `"type":"authentication_error"`, and HTTP status codes 429/500/502/503/529. Currently FIFO just logs text — needs JSON error pattern extraction (lines 120-124).

3. **Error classification logic in `lib/errors.sh`** — The taxonomy must map exit codes + error patterns to categories. Critical distinction: UPSTREAM (api_500) must bypass null-run classification entirely. Currently, agent.sh treats exit code 1 + 0 turns as null_run universally (lines 225-247 in agent.sh).

4. **Stage error handling** — All four stages (coder.sh, review.sh, tester.sh, architect.sh) currently report "null run" generically. Need to check `AGENT_ERROR_CATEGORY` and route UPSTREAM errors to transient-error path, not scope-failure path.

5. **Metrics integration in `lib/metrics.sh`** — Current `record_run_metrics()` doesn't capture error fields (lines 55-100+). Must add `error_category`, `error_subcategory`, `error_transient` to JSONL output.

6. **State persistence gap in `lib/hooks.sh`** — `record_run_metrics()` may not fire on all exit paths (lines 720, 901, 923 in tekhton.sh). Early exits (config error, missing files) may skip metrics recording.

7. **Redaction in `lib/errors.sh`** — The `redact_sensitive()` function must strip patterns like `sk-ant-*`, `x-api-key: *`, `ANTHROPIC_API_KEY=*` without over-redacting (e.g., preserve request IDs like `req_011CZ9DVb...`).

## Complexity Estimate

Files to modify: 11
Estimated lines of change: 650
Interconnected systems: high
Recommended coder turns: 85
Recommended reviewer turns: 18
Recommended tester turns: 55
