# M112 - Pre-Run Dedup Coverage Hardening

<!-- milestone-meta
id: "112"
status: "done"
-->

## Overview

Milestone 105 added safe test deduplication for several heavy gates, but some
high-cost test paths still re-run `TEST_CMD` without consulting dedup state.
This creates avoidable runtime overhead in large suites, especially during
pre-coder and tester-fix loops.

M112 extends dedup coverage to these missed paths while preserving Tekhton's
quality guarantees: skip only when the current state is provably identical to
one that already passed.

## Design

### Goal 1 — Cover highest-value missed test paths

Apply existing `test_dedup_can_skip` / `test_dedup_record_pass` logic to:

- `run_prerun_clean_sweep()` initial pre-coder test check
- `_run_prerun_fix_agent()` post-attempt shell verification
- `tester_fix_loop()` retest after each fix attempt

These are currently uncached high-frequency test invocations and represent the
largest safe savings opportunity.

### Goal 2 — Strengthen fingerprint identity to avoid false skips

`test_dedup` currently fingerprints working-tree status and `TEST_CMD`.
To prevent clean-tree collisions across different commits, include `HEAD`
identity in the fingerprint when git is available.

Fingerprint components (git repo case):

1. `git rev-parse HEAD`
2. `git status --porcelain`
3. `cmd:${TEST_CMD}`

This keeps dedup deterministic and conservative.

### Goal 3 — Preserve baseline and acceptance quality signals

Dedup expansion must not weaken baseline semantics.

- Never treat a failed-state fingerprint as skippable.
- Continue to record pass fingerprints only on exit 0.
- Keep baseline capture behavior explicit and conservative; if baseline policy
  is changed later, require a dedicated acceptance check for pre-existing
  failure classification integrity.

### Goal 4 — Keep policy centralized and observable

Do not introduce parallel skip mechanisms.

- Reuse `lib/test_dedup.sh` as the single policy source.
- Emit existing `test_dedup_skip` events in newly covered paths so dashboard
  and causal logs preserve observability.
- Respect `TEST_DEDUP_ENABLED=false` as global opt-out.

## Files Modified

| File | Change |
|------|--------|
| `lib/test_dedup.sh` | Strengthen fingerprint (include commit identity); keep fallback behavior deterministic when git is unavailable |
| `stages/coder_prerun.sh` | Add dedup skip/record logic for pre-coder check and fix-loop verification |
| `stages/tester_fix.sh` | Add dedup skip/record logic for retest loop |
| `lib/orchestrate.sh` | Clarify/reset policy for cross-run vs in-run dedup persistence (config-gated if needed) |
| `lib/config_defaults.sh` | Optional: add explicit config for dedup reset scope if implemented |

## Acceptance Criteria

- [ ] With no changes since last successful `TEST_CMD` run, pre-coder test
      check is skipped via dedup and logs a skip event.
- [ ] With no changes since last successful `TEST_CMD` run, pre-coder fix-loop
      verification is skipped via dedup and logs a skip event.
- [ ] With no changes since last successful `TEST_CMD` run, tester-fix retest
      is skipped via dedup and logs a skip event.
- [ ] Pass fingerprints are recorded only when `TEST_CMD` exits 0.
- [ ] A different commit with clean working tree does not match prior pass
      fingerprint (no false skip across commits).
- [ ] `TEST_DEDUP_ENABLED=false` disables all dedup skip paths, including the
      newly covered pre-coder and tester-fix paths.
- [ ] Existing dedup-enabled gates (completion, final checks, acceptance,
      pre-finalization) continue to behave unchanged.
- [ ] Shellcheck remains clean for all touched scripts.
- [ ] Existing test baseline comparison behavior remains unchanged.

## Non-Goals

- Introducing flaky-test masking heuristics.
- Softening acceptance gates for failing tests.
- Replacing baseline capture with dedup-only logic.
