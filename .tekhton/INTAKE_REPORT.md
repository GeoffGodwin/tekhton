## Verdict
TWEAKED

## Confidence
52

## Reasoning
- The milestone content is only a title — no scope definition, no acceptance criteria, no files listed, no Watch For section
- Intent is clear enough from the title: completion gate in `lib/gates.sh` should not halt the pipeline when TEST_CMD fails transiently (e.g., file-system state, artifact churn, or a flaky test immediately after a large coder refactor)
- "Transient" vs "persistent" failure boundary is undefined — a competent developer could legitimately implement retry logic, a cool-down window, or a fingerprint-diff heuristic and get very different results
- No acceptance criteria means there is no testable definition of "fixed"
- Added missing scope, acceptance criteria, and Watch For sections with `[PM: ...]` markers

## Tweaked Content

# Milestone m45 — Completion gate: stop false-halting on transient TEST\_CMD failure after a large coder refactor

[PM: Title retained verbatim. All sections below are additive — original file had no body beyond this title.]

## Goal

The completion gate (`lib/gates.sh`) must not halt the pipeline as a failure when
TEST_CMD exits non-zero due to a transient condition that clears on an immediate
retry — specifically when a large coder refactor has left file-system state (stale
artefacts, build caches, timing-sensitive tests) that causes a single flaky test run.
The gate should distinguish a genuinely failing test suite from one-off environmental
noise.

[PM: Goal section added — inferred from milestone title.]

## Scope

**In scope:**
- `lib/gates.sh` — completion gate logic; add retry/quiesce behaviour for TEST_CMD
- Extract helpers to `lib/gates_retry.sh` if the 300-line ceiling would otherwise be
  exceeded

**Out of scope:**
- Changes to the build gate (separate from the completion gate)
- Changes to `stages/tester.sh` or the tester fix agent — those handle structural
  test failures, not completion-gate transients
- Changing the definition of "transient error" for agent-level retries in
  `lib/agent_retry.sh`

[PM: Scope section added — derived from CLAUDE.md file map and milestone title.]

## Acceptance Criteria

1. When TEST_CMD exits non-zero inside the completion gate and then exits zero on an
   immediate re-run with the same working tree, the gate records the run as **passed**
   and does not halt the pipeline.
2. When TEST_CMD exits non-zero on every attempt up to the retry limit, the gate still
   halts the pipeline — retry must not mask genuine failures.
3. The retry limit is configurable via a new `COMPLETION_GATE_RETRY_ATTEMPTS` config
   key (default: `1`, meaning one retry after the initial failure). Setting it to `0`
   restores pre-m45 single-shot behaviour.
4. Each retry attempt is logged at INFO level so the pipeline transcript shows why the
   gate paused (e.g., `[gate] TEST_CMD failed on attempt 1/2 — retrying…`).
5. Existing bash unit tests in `tests/` continue to pass (`bash tests/run_tests.sh`).
6. `shellcheck lib/gates.sh` (and any extracted helper file) reports zero warnings.
7. Any modified `.sh` file stays under 300 lines.

[PM: Acceptance criteria added — none existed in the original file. Criteria are
testable and directly map to the false-halt problem described in the title. The new
config key follows the naming convention of existing config keys documented in
CLAUDE.md.]

## Watch For

- **300-line ceiling.** `lib/gates.sh` may already be near the limit; extract helpers
  to `lib/gates_retry.sh` if needed rather than exceeding the ceiling.
- **Idempotency.** The working tree must be identical between retry attempts — do not
  clean artefacts between retries, as that could mask a genuine failure caused by
  dirty output files.
- **Interaction with TEST_BASELINE.** If `TEST_BASELINE_ENABLED=true`, the baseline
  capture runs before the coder stage; ensure the retry logic does not confuse a
  pre-existing failure (captured in baseline) with a transient one.
- **Config key documentation.** Add `COMPLETION_GATE_RETRY_ATTEMPTS` to the variable
  table in `CLAUDE.md` following the existing table format.

[PM: Watch For section added — none existed in original file.]

## Migration Impact

New optional config key: `COMPLETION_GATE_RETRY_ATTEMPTS` (default: `1`).
Existing deployments require no changes — the default adds one silent retry, which is
the bug-fix behaviour. Projects that want to revert to strict single-shot mode can set
`COMPLETION_GATE_RETRY_ATTEMPTS=0` in `pipeline.conf`.

[PM: Migration Impact section added — required by rubric because a new user-facing
config key is introduced.]
