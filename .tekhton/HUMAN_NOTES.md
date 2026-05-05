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
- [ ] [BUG] At the end of a `--fix-nonblockers` run, the action-items summary prints `${NON_BLOCKING_LOG_FILE} — N accumulated observation(s)` using the pre-run count (e.g. "11 accumulated observations") even when every item was addressed during the run. Repro: run a milestone that leaves N≥1 unresolved notes in `## Open`, then run `tekhton --fix-nonblockers --complete`; final summary still claims N accumulated observations and the dashboard's `.claude/dashboard/data/action_items.js` still shows the pre-run count. Root cause: `_run_fix_nonblockers_loop` in `tekhton.sh:2729` checks `count_open_nonblocking_notes` at the *top* of each iteration and `break`s when it hits zero — so after the final pass marks items `[x]`, the loop exits without calling `finalize_run` again. The previous pass's `finalize_run` did emit `emit_dashboard_action_items` (`finalize_dashboard_hooks.sh:54-55`) but at a moment when the items were either still `[ ]` or hadn't been moved yet, so `action_items.js` and the terminal summary both reflect a stale count. `_hook_final_dashboard_status` (`finalize_dashboard_hooks.sh:143`) only re-emits `run_state.js`, not `action_items.js`. Fix — pick one: (1) after `_run_fix_nonblockers_loop`'s break-on-zero, call `emit_dashboard_action_items` and re-print the action-items summary so both terminal and dashboard show the post-run state; (2) extend `_hook_final_dashboard_status` to also re-emit `action_items.js`; (3) suppress the accumulated-observations line at the end of `--fix-nonblockers` since by definition the loop exits only when count==0 (simplest, but loses information for partial-success exits via `FIX_NONBLOCKERS_MAX_PASSES` or `AUTONOMOUS_TIMEOUT`). Option (1) is preferred because it also handles the partial-success exit paths correctly. Add a regression test that runs `--fix-nonblockers` against a fixture with N≥1 open notes and asserts the final terminal output and `action_items.js` both show count 0.0

## Polish

- [ ] [POLISH] **m01/m02 milestone-doc cleanup pass.** Four small doc nits surfaced during V4 Phase 1 implementation, recorded for a future cleanup pass so the docs match what was actually built:
  1. `.claude/milestones-v3/v3-final/m01-go-module-foundation.md` contains a Go snippet `//go:embed ../../VERSION` that is not legal Go (path traversal not allowed in embed). The Architecture Change Proposal in CODER_SUMMARY resolved this with the ldflags approach (`-X main.version=$(cat VERSION)`); update the milestone doc to reflect ldflags so future readers don't waste time tracing the discrepancy.
  2. `scripts/self-host-check.sh` — m01 AC required running `tekhton.sh --dry-run`, but `--dry-run` calls Claude CLI agents (intake + scout) which require auth that CI cannot satisfy. The script defaults to the lighter `tekhton.sh --version` (exercises the bash entry point with `bin/tekhton` on `$PATH`) and gates the full `--dry-run` behind `TEKHTON_SELF_HOST_DRY_RUN=1`. Update the m01 AC text to reflect this split (CI runs the safe subset; humans with auth run the full smoke).
  3. m02 milestone — `init` semantics. The doc's AC #1 prescribes `tekhton causal init` truncates the log and writes an `init-1` event. The bash test suite (the parity gate at AC #7) requires the opposite: `init_causal_log` must NOT truncate (resume-friendly). The implementation honors the resume-friendly semantics; update the doc to match.
  4. m02 AC #6 — `grep -r _json_escape lib/ stages/` cannot return empty without breaking ~20 lib callers. The intent ("delete the bash JSON-escape duplication that was tied to causality.sh") is satisfied by relocating the helper to `lib/common.sh`. Reword the AC to "no `_json_escape` definition in `lib/causality.sh` or `stages/`; sole definition lives in `lib/common.sh`."
