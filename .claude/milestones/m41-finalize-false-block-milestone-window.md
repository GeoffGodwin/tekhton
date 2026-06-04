<!-- milestone-meta
id: "41"
status: "todo"
-->

# m41 — Finalize: stop false-blocking the commit when the milestone block can't be populated

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | A dogfood run of a downstream project (sdivi-rust, milestone `49.2`, a multi-phase dotted ID) completed the full pipeline — coder, security, review, tester all succeeded and the produced code was correct and complete — but the commit was **hard-blocked at finalize**, leaving a successful milestone uncommitted and still `pending` in the manifest. The operator had to recover the run by hand. The block was a false positive. |
| **Gap** | `stages/coder.sh:251-259` calls `set_focused_milestone_block`; if it returns non-zero while `MILESTONE_MODE=true` it calls `trip_commit_gate "milestone_block_unavailable_${_CURRENT_MILESTONE}"`. That sentinel makes `lib/finalize_commit.sh::_hook_commit` refuse to commit regardless of the actual stage results. For the dotted ID `49.2`, `set_focused_milestone_block` (`lib/milestone_window.sh`) returned non-zero — yet the coder went on to produce a valid `CODER_SUMMARY.md` and the downstream stages passed, proving the block-unavailable signal was wrong (the agent had sufficient context). Compounding it, the operator-facing diagnostic is self-contradictory: `Commit blocked: final checks failed (FINAL_CHECK_RESULT=0, persisted=1)` — the in-process result says pass, the persisted sentinel says fail, and the actual reason (`# milestone_block_unavailable_49.2`, stored as a comment in `.final_check_result`) is never surfaced. |
| **m41 fills** | (a) Fix `set_focused_milestone_block` to resolve dotted/multi-phase milestone IDs (`49.2`, `40.1`) and tolerate the milestone-file shapes used by downstream projects (e.g. `**Watch For:**` bold-label form, not only `## Watch For` H2 headers). (b) Make the coder's block-unavailable path **non-fatal when the run actually succeeds**: trip the gate only if the coder subsequently fails to produce a substantive `CODER_SUMMARY` (the existing `coder_did_not_produce_summary` / `completion_gate_failed_substantive_work_only` gates already cover the genuine hollow-run case). A populated block is an *input* safeguard, not a *result* check — it must not override green downstream stages. (c) Surface the real block reason in `_hook_commit`: read and print the `# <reason>` line from `.final_check_result` instead of the contradictory `FINAL_CHECK_RESULT/persisted` pair. |
| **Depends on** | — |
| **Files changed** | `lib/milestone_window.sh`, `stages/coder.sh`, `lib/finalize_commit.sh`, `tests/test_milestone_window_focused.sh`, `tests/test_finalize_commit_block_reason.sh` (new). |

---

## Design

### Goal 1 — `set_focused_milestone_block` resolves dotted IDs and varied file shapes

Reproduce the failure first: in a fixture project with a milestone file `m49.2-*.md`
whose `id: "49.2"` and which uses `**Watch For:**`/`**Seeds Forward:**` bold labels,
assert `set_focused_milestone_block` returns 0 and populates a non-empty
`MILESTONE_BLOCK`. Fix the resolver (number→id mapping, file lookup, and the section
extractor) so the dotted id and the bold-label section form both resolve. Keep the
existing 500-char section cap and the guarantee that "Watch For" / "Seeds Forward"
are always included.

### Goal 2 — block-unavailable is an input warning, not a commit-blocking result

In `stages/coder.sh`, when `set_focused_milestone_block` fails, **warn and continue**;
do not `trip_commit_gate` here. The genuine hollow-run protections downstream
(`coder_did_not_produce_summary` at coder.sh:803, the completion gate at coder.sh:1154,
`reviewer_did_not_produce_report`, `tester_did_not_produce_report`) already block
rubber-stamped fallbacks. A successful run with a transiently-unpopulated block must
commit.

### Goal 3 — honest, single-line block diagnostic

In `_hook_commit`, when the persisted sentinel is non-zero, read its `# reason`
comment and print: `Commit blocked: <reason> (see .tekhton/.final_check_result)`.
Drop the `FINAL_CHECK_RESULT=0, persisted=1` contradiction from the operator message
(keep both values only in verbose logs).

## Files Modified

- `lib/milestone_window.sh` — dotted-id resolution + bold-label section extraction.
- `stages/coder.sh` — remove the `milestone_block_unavailable` `trip_commit_gate`; keep the warn.
- `lib/finalize_commit.sh` — surface the sentinel `# reason` in the blocked-commit message.
- `tests/test_milestone_window_focused.sh` — dotted-id + bold-label cases.
- `tests/test_finalize_commit_block_reason.sh` (new) — asserts the reason is printed.

## Acceptance Criteria

- A milestone with a dotted id and bold-label sections populates `MILESTONE_BLOCK` (resolver returns 0).
- A run where the coder produces a valid summary and all stages pass **commits**, even if `set_focused_milestone_block` had failed.
- A genuinely hollow run (no `CODER_SUMMARY`) still blocks, via the existing summary/completion gates.
- The blocked-commit message names the actual reason; no `FINAL_CHECK_RESULT=0, persisted=1` contradiction in operator output.
- Existing `tests/test_milestone_window_focused.sh` cases still pass.

## Watch For

- Do not weaken the genuine anti-rubber-stamp gates (synthesize-fallback, did-not-produce-summary). The fix narrows ONE false-positive trip, not the hollow-run protections.
- `set_focused_milestone_block` is called from scout AND coder substages — fix it in one place (`lib/milestone_window.sh`), not per caller.
- The sentinel is intentionally idempotent (first reason wins) and absolute-path resolved — preserve both properties.

## Seeds Forward

- A `tekhton finalize --recover` subcommand that, given a blocked run whose stages all passed, completes the mark-done + commit without re-running agents (the manual recovery this milestone's bug forced).
