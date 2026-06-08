<!-- milestone-meta
id: "04"
status: "todo"
-->

# m04 (V5) — Restore [MILESTONE X ✓] Commit Subject Prefix During Auto-Advance

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | The V5 m01 → m02 → m03 auto-advance run shipped all three milestones successfully, but every milestone's finalize commit landed with m44's largest-file-fallback subject (`feat: changes in <largest-file>`) instead of `[MILESTONE 01 ✓]`, `[MILESTONE 02 ✓]`, `[MILESTONE 03 ✓]`. m48's auto-advance per-iteration banner correctly flagged this: *"m03 finalize skipped commit — HEAD subject is 'feat: changes in .../m02-stages-consume-provider.md' (expected '[MILESTONE 03 ✓]' prefix)"*. The work shipped correctly; the per-milestone commit narrative is muddled. The pattern matches the m37.1 / e215fbb env-asymmetry bug that bit intake — `MILESTONE_MODE` and `_CURRENT_MILESTONE` aren't propagating from the Go-side auto-advance loop through the finalize hook chain to the bash `_hook_commit` subprocess. m04 finds the exact propagation gap and closes it. |
| **Gap** | `lib/finalize_commit.sh::_hook_commit` (around lines 204-208) reads `${MILESTONE_MODE:-false}` and `${_CURRENT_MILESTONE:-}` from its subprocess env. If MILESTONE_MODE != "true" OR _CURRENT_MILESTONE is empty, `ms_num` stays empty, the milestone-prefix code path doesn't activate, and `generate_commit_message` falls through to the m44 largest-file fallback. The Go auto-advance loop at `cmd/tekhton/run.go::runAutoAdvanceLoop` correctly sets `nextReq.Mode = proto.RunModeMilestone` per iteration. `internal/runner/runner.go::Finalize` correctly derives `MilestoneMode: req.Mode == proto.RunModeMilestone`. The gap is somewhere between `finalize.Input{MilestoneMode: true}` and the env block handed to the bash hook subprocess — analogous to the intake-stage env-asymmetry fix (m37.1 era) where the runner composed env into `req.EnvOverrides` but the bash subprocess read from `os.Environ`. m04's job is to trace this end-to-end and apply the same envBool-style fix. |
| **m04 fills** | (1) Trace the env path from `runAutoAdvanceLoop` → `RunSingle` → `Hooks.Finalize` → `finalize.Orchestrator.Run` → bash hook subprocess `_hook_commit`. Identify the exact site where `MILESTONE_MODE` and `_CURRENT_MILESTONE` fail to reach the bash env. (2) Apply the fix — most likely either ensure the finalize orchestrator's hook-subprocess env block carries the variables, OR add a setenv at the per-iteration boundary in runAutoAdvanceLoop. (3) Regression test: drive a synthesized 3-milestone auto-advance with stubbed agents and assert each iteration's commit subject begins with `[MILESTONE 0X ✓]`. (4) No retroactive fix-up of the m01/m02/m03 commits — git history stays as-is. The fix prevents the next batch from repeating. |
| **Depends on** | m03 (the failure is observed on the m01-m03 chain; the fix applies to any subsequent chain) |
| **Files changed** | `lib/finalize_commit.sh` OR `internal/finalize/orchestrator.go` OR `cmd/tekhton/run.go` (one of these is the propagation gap site — implementer identifies during investigation), the corresponding test files, possibly `internal/runner/runner.go` for env-block composition. New shim-boundary test `tests/test_autoadvance_milestone_prefix.sh`. |

---

## Design

### Sequencing note

m04 should land before any further V5 stage-port or polyglot work that
auto-advances. Without it, every multi-milestone chain produces
muddled commit history requiring manual post-cleanup. Small fix, high
operator value.

### Goal 1 — Identify the env-propagation gap

Walk the call chain manually with `set -x` enabled OR add temporary
debug-print statements to surface where MILESTONE_MODE and
_CURRENT_MILESTONE are populated vs empty:

1. `runAutoAdvanceLoop` at the top of each iteration — populated.
2. `RunSingle(ctx, nextReq)` — req has Mode + Milestone set.
3. `Runner.Finalize(ctx, req, res)` — `finalize.Input.MilestoneMode = true`, `Milestone = "m01"`.
4. `finalize.Orchestrator.Run` — hook subprocess spawn site. **Likely gap location.**
5. Bash `_hook_commit` reads `${MILESTONE_MODE:-false}` — sees "false" (or empty).

The most likely fix site is step 4: the finalize orchestrator composes
the env block for each bash hook subprocess but may not include
MILESTONE_MODE and _CURRENT_MILESTONE among the variables exported.
The fix is to add them to the env block alongside whatever else is
already exported (TASK, TEKHTON_DIR, etc.).

### Goal 2 — Apply the fix

Most likely shape (in `internal/finalize/orchestrator.go` or a sibling
file that composes the hook env):

```go
// m04 — Propagate milestone-mode env to bash hook subprocesses so
// _hook_commit's MILESTONE_MODE / _CURRENT_MILESTONE checks see the
// correct values. Without this, every milestone's finalize commit
// lands with m44's largest-file fallback subject instead of the
// [MILESTONE X ✓] prefix.
hookEnv := append(os.Environ(),
    "MILESTONE_MODE=" + boolStr(in.MilestoneMode),
    "_CURRENT_MILESTONE=" + in.Milestone,
)
cmd.Env = hookEnv
```

Exact shape depends on what `Orchestrator` does today. The implementer
audits the existing env-composition site (search for where the bash
shim's env block is built) and adds the two variables there.

### Goal 3 — Regression test

**File:** `tests/test_autoadvance_milestone_prefix.sh` (new, ~100 lines).

Drives a 2-milestone auto-advance with stubbed agents:

1. Set up a throwaway repo with two trivial fixture milestones.
2. Stub the agent runner to produce a deterministic single-file change.
3. Run `tekhton --milestone <first> --auto-advance --auto-advance-limit 2`.
4. Assert: both commits' subjects begin with `[MILESTONE X.Y ✓]`.
5. Self-skip when the Go binary isn't built.

Plus a Go unit test that exercises whatever env-composition site the
fix touches — asserts MILESTONE_MODE=true and _CURRENT_MILESTONE
appear in the hook subprocess env.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/finalize/orchestrator.go` (or sibling) | Modify | Add MILESTONE_MODE + _CURRENT_MILESTONE to the bash hook subprocess env block. |
| `internal/finalize/orchestrator_test.go` | Modify | Add a unit test asserting both env vars appear in the composed hook env. |
| `tests/test_autoadvance_milestone_prefix.sh` | Create | Shim-boundary regression guard. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

- [ ] After m04, an auto-advance run from m04 → m05 produces TWO commits whose subjects start with `[MILESTONE 04 ✓]` and `[MILESTONE 05 ✓]` respectively. The m04 commit itself is the proof — its subject should begin with `[MILESTONE 04 ✓]`. Self-verifying.
- [ ] The bash hook subprocess env block contains `MILESTONE_MODE=true` and `_CURRENT_MILESTONE=m04` (or equivalent for whichever id is running). Verified by the Go-side env-composition unit test.
- [ ] `tests/test_autoadvance_milestone_prefix.sh` passes — both stubbed-agent iterations produce `[MILESTONE X.Y ✓]` subjects.
- [ ] No regression in existing `internal/finalize/...` tests.
- [ ] `shellcheck tests/test_autoadvance_milestone_prefix.sh` clean.
- [ ] `golangci-lint run ./internal/finalize/...` and `go vet` clean.
- [ ] Full suite passes.

## Watch For

- **This is an env-propagation bug, NOT a commit-message-generation bug.**
  m44's logic in `lib/hooks.sh::generate_commit_message` is correct; it
  just doesn't see MILESTONE_MODE / _CURRENT_MILESTONE because they
  aren't in env. Don't modify `generate_commit_message`.
- **The auto-advance per-iteration sentinel reset (m48's
  `clearAutoAdvanceIterationState`) is NOT the bug source.** That
  function correctly clears commit-skip sentinels; it doesn't touch
  milestone-mode env. The gap is between the Go-side finalize
  orchestrator and the bash hook subprocess.
- **Don't fix this in the bash side.** Tempting to add an `export MILESTONE_MODE=true` at the top of `_hook_commit`. Resist —
  bash can't know what milestone it's part of without the Go side
  telling it. The fix belongs in the Go env-composition layer.
- **The first iteration of an auto-advance run may have populated env
  correctly via shell-function inheritance** (the operator's `tekhton`
  shell function passes env through). The bug primarily affects
  iteration 2 onward. The regression test should specifically exercise
  iteration 2+ to catch the gap.

## Seeds Forward

- **Audit other env vars at the same gap.** If MILESTONE_MODE doesn't
  propagate, what else doesn't? Candidates: TASK, AUTO_ADVANCE,
  AUTO_ADVANCE_LIMIT. A future arc could systematize this with a
  contract test that every finalize-input field gets a corresponding
  env var in the subprocess.
- **Surface the prefix-missing warning at finalize time, not just
  at next-iteration banner.** m48's banner catches this AFTER the
  next iteration starts. A finalize-time check (the bash side
  inspecting its own commit subject and warning if MILESTONE_MODE was
  set but the prefix didn't fire) would catch it 5-10 minutes earlier.
