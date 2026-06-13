## Summary
This review covers milestone m20 (route planning/replan batch paths off raw `claude` CLI) and its supporting changes in `lib/plan_batch.sh`, `lib/replan_brownfield.sh`, `lib/replan_midrun.sh`, `stages/plan_interview.sh`, `stages/plan_followup_interview.sh`, `stages/plan_generate.sh`, `lib/common.sh`, and `lib/mcp_resolve.sh`. The change replaces direct `claude --output-format text --dangerously-skip-permissions -p` invocations in the planning batch path with the `tekhton supervise` seam (via `agent_shim.sh`), enabling provider-awareness (codex, qwen-local, claude) for all planning calls. JSON request/response files are properly escaped via `_json_escape`, all subprocess arguments are quoted, and cleanup traps are in place. One low-severity finding on predictable temp file naming is noted.

## Findings
- [LOW] [category:A04] [lib/plan_batch.sh:89-93] fixable:yes — Temp files (`tekhton_plan_prompt_$$.txt`, `tekhton_plan_request_$$.json`, `tekhton_plan_response_$$.json`) use predictable PID-based names in the fallback `/tmp` path. In a shared multi-user environment a local attacker with `/tmp` write access could pre-create a symlink at the expected path before the file is created, redirecting prompt writes or supervisor response reads. Risk is low because `TEKHTON_SESSION_DIR` is normally a session-private directory and these files contain planning prompts (not credentials). Fix: use `mktemp` with a suffix flag for atomic, race-free temp file creation, or ensure `TEKHTON_SESSION_DIR` is always used rather than falling back to `/tmp`.

## Verdict
FINDINGS_PRESENT
