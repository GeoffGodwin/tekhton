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

- [ ] [BUG] The coder role file (`templates/coder.md`) says "when finished, write CODER_SUMMARY.md" which conflicts with `coder.prompt.md` Step 1 instruction to write it immediately before touching code. This causes the coder to sometimes produce a great verbal summary in its final output but never write it to disk, triggering reconstruction. Fix: rewrite the Required Output section of `templates/coder.md` to match the prompt's write-first intent — create the IN PROGRESS skeleton before writing any code, update throughout, and set Status to COMPLETE as the final act.

- [ ] [BUG] When the coder writes the IN PROGRESS skeleton at Step 1 but never updates it (leaves `(fill in as you go)` placeholders), the completion gate correctly detects IN PROGRESS and starts a continuation loop — but neither the continuation prompt nor the original prompt explicitly tells the agent to re-create the file from scratch if it's missing during a continuation. Add a check in `stages/coder.sh` after `run_agent` that detects an un-updated skeleton (grep for `fill in as you go`) and treats it the same as a missing file, plus add an explicit instruction to `lib/agent_helpers.sh` `build_continuation_context()` that if CODER_SUMMARY.md is missing or still contains placeholder text, recreating it with actual content is Step 1 of the continuation.


## Polish
