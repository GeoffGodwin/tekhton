# Human Notes
<!-- notes-format: v2 -->
<!-- IDs are auto-managed by Tekhton. Do not remove note: comments. -->

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes


## Features

## Bugs

- [x] [BUG] Fix MAX_ARG_STRLEN (128KB) limit when passing prompts as positional arguments to the `claude` CLI. On Linux, individual command-line arguments are capped at 131072 bytes. Planning prompts that embed design docs, codebase summaries, repo maps, and template content routinely exceed this, causing "Argument list too long" failures. There are 3 affected call sites that all use the pattern `-p "$prompt" < /dev/null`:
  1. `lib/plan.sh:202` — `_call_planning_batch()`: used by `--plan`, `--replan`, milestone splitting, artifact merging, and init synthesis. Most likely to hit the limit since planning prompts are the largest.
  2. `lib/agent_monitor.sh:51` — FIFO-monitored path in `_invoke_and_monitor()`: used by all main pipeline agents (coder, reviewer, tester, etc.) via `run_agent()`. Prompts include rendered templates with injected context, repo maps, and milestone content.
  3. `lib/agent_monitor.sh:263` — Non-FIFO fallback path in `_invoke_and_monitor()`: same prompt, rare code path for systems without mkfifo.
  **Fix**: At each call site, write `$prompt` to a temp file via `printf '%s' "$prompt" > "$_prompt_file"`, then replace `-p "$prompt" < /dev/null` with `-p < "$_prompt_file"` so the prompt is fed via stdin instead of as a positional argument. The `-p` flag (print mode) remains; only the positional argument is removed. Clean up the temp file after use AND in abort/interrupt traps for safety. In `_call_planning_batch`, use `${TMPDIR:-/tmp}` for the temp file. In `_invoke_and_monitor`, use the existing `$_session_dir`. Add `rm -f "$_prompt_file"` to both `_run_agent_abort()` trap functions (FIFO path line 67 and fallback path line 254). All existing tests must continue to pass. All modified files must pass shellcheck.
