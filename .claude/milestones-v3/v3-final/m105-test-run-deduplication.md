# M105 — Test Run Deduplication: Skip Redundant TEST_CMD Executions
<!-- milestone-meta
id: "105"
status: "done"
-->

## Overview

On a successful milestone run, `TEST_CMD` executes back-to-back at two points with
zero code changes between them:

1. **Milestone acceptance** (`lib/milestone_acceptance.sh:77`) — validates acceptance
   criteria. Tests pass.
2. **Build gate** (`lib/gates_phases.sh:51`) — runs `ANALYZE_CMD` only (shellcheck/lint).
   No files are modified.
3. **Pre-finalization gate** (`lib/orchestrate.sh:287`) — runs `TEST_CMD` again.
   Identical result — nothing changed since #1.

The existing `_PREFLIGHT_TESTS_PASSED` flag already deduplicates between the
pre-finalization gate and `_hook_final_checks` in `lib/finalize.sh`. This milestone
extends that idea to the full pipeline using a **working-tree fingerprint** that
tracks whether any files have changed since the last successful test run.

**Impact:** Saves one full test suite execution (~9 minutes in observed runs) on
every successful milestone completion. Non-disruptive — the dedup is purely
skip-on-match with a conservative fallback to always re-run.

## Design

### §1 — Working-Tree Fingerprint

A fingerprint is a hash of the current working-tree state. If the fingerprint has
not changed since the last time `TEST_CMD` exited 0, the result is provably
identical and the run can be skipped.

**Fingerprint computation** (`lib/test_dedup.sh`):

```bash
_test_dedup_fingerprint() {
    if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        # git status --porcelain covers: modified, staged, untracked, deleted
        # Include TEST_CMD itself so a config change invalidates the cache
        { git status --porcelain 2>/dev/null; echo "cmd:${TEST_CMD:-}"; } \
            | md5sum | cut -d' ' -f1
    else
        # No git — always re-run (return unique value each time)
        echo "no-git-$(date +%s%N)"
    fi
}
```

Using `git status --porcelain` is fast (<50 ms on most repos), captures all
relevant changes (modified, staged, untracked, deleted), and is deterministic.
Including `TEST_CMD` in the hash ensures a config change invalidates the cache.

**Storage:** `${TEKHTON_DIR}/test_dedup.fingerprint` — a single line containing
the md5 hash from the last successful `TEST_CMD` execution. Cleared at pipeline
start.

### §2 — Core Functions

```bash
# Record a successful test pass with the current fingerprint.
test_dedup_record_pass() {
    [[ "${TEST_DEDUP_ENABLED:-true}" = "true" ]] || return 0
    local fp
    fp=$(_test_dedup_fingerprint)
    local fp_file="${TEKHTON_DIR}/test_dedup.fingerprint"
    mkdir -p "$(dirname "$fp_file")"
    echo "$fp" > "$fp_file"
}

# Check if tests can be skipped. Returns 0 (skip) or 1 (must run).
test_dedup_can_skip() {
    [[ "${TEST_DEDUP_ENABLED:-true}" = "true" ]] || return 1
    local fp_file="${TEKHTON_DIR}/test_dedup.fingerprint"
    [[ -f "$fp_file" ]] || return 1
    local current previous
    current=$(_test_dedup_fingerprint)
    previous=$(cat "$fp_file")
    [[ "$current" = "$previous" ]]
}

# Clear dedup state. Called once at pipeline start.
test_dedup_reset() {
    rm -f "${TEKHTON_DIR}/test_dedup.fingerprint" 2>/dev/null || true
}
```

### §3 — Call-Site Integration

Each `TEST_CMD` call site wraps with a check-and-record pattern. The dedup only
applies to **pass results** — failed tests always re-run (a failure invalidates
nothing since nothing was cached for it).

**Sites that participate in dedup:**

| Site | File:Line | Role | Record pass? | Check skip? |
|------|-----------|------|-------------|-------------|
| Completion gate | `lib/gates_completion.sh:77` | After coder, verify tests still pass | Yes | Yes |
| Milestone acceptance | `lib/milestone_acceptance.sh:77` | Acceptance criteria validation | Yes | Yes |
| Pre-finalization gate | `lib/orchestrate.sh:287` | Final pre-finalize verification | Yes | Yes |
| Pre-run check | `lib/orchestrate_preflight.sh:78` | Post Jr-Coder fix verification | Yes | Yes |
| Final checks (pass 1) | `lib/hooks_final_checks.sh:90` | Finalization hook | Yes | Yes |
| Final checks (pass 2) | `lib/hooks_final_checks.sh:127` | Post-fix re-verification | Yes | No (fix just ran) |

**Sites explicitly excluded from dedup:**

| Site | File:Line | Reason |
|------|-----------|--------|
| Test baseline capture | `lib/test_baseline.sh:90` | Baseline must always capture current state |

**Wrapping pattern** (example: `lib/milestone_acceptance.sh:77`):

```bash
# Before:
test_output=$(bash -c "${TEST_CMD}" 2>&1) || test_exit=$?

# After:
if test_dedup_can_skip; then
    log "[dedup] Tests passed with no file changes since last run — skipping"
    test_output="[dedup] Cached pass — no files changed since last successful test run"
    test_exit=0
else
    test_output=$(bash -c "${TEST_CMD}" 2>&1) || test_exit=$?
    if [[ "$test_exit" -eq 0 ]]; then
        test_dedup_record_pass
    fi
fi
```

Each site follows this exact pattern, varying only the local variable names
(`test_output`/`test_exit` vs `_cg_output`/`_cg_exit` vs
`_preflight_output`/`_preflight_exit`).

### §4 — Pipeline Reset

Add `test_dedup_reset` to the orchestration loop entry point so that stale
fingerprints from a previous run don't carry over. In `lib/orchestrate.sh`, call
`test_dedup_reset` once at the top of the orchestration function, before the first
pipeline attempt.

### §5 — Configuration

Add to `lib/config_defaults.sh` after the `TEST_BASELINE_*` block (~line 388):

```bash
# --- Test run deduplication (M105) ---
: "${TEST_DEDUP_ENABLED:=true}"
```

Default `true` — the fingerprint-based dedup is provably safe (only skips when
the working tree is byte-identical to when tests last passed). Users who want to
force every test run (e.g., for non-deterministic test suites) can set
`TEST_DEDUP_ENABLED=false`.

### §6 — Causal Event Logging

When a test run is skipped via dedup, emit a causal event so Watchtower and
diagnostics can surface it:

```bash
if test_dedup_can_skip; then
    if command -v emit_event &>/dev/null; then
        emit_event "test_dedup_skip" "${_CURRENT_STAGE:-unknown}" \
            "fingerprint_match=true" "" "" "" >/dev/null 2>&1 || true
    fi
    ...
fi
```

### §7 — Interaction with `_PREFLIGHT_TESTS_PASSED`

The existing `_PREFLIGHT_TESTS_PASSED` flag in `lib/finalize.sh:69` remains
unchanged. The dedup is an independent layer that fires earlier — at the
`test_dedup_can_skip` check. If pre-finalization is skipped via dedup, it still
sets `_PREFLIGHT_TESTS_PASSED=true` so `_hook_final_checks` continues to skip as
before. The two mechanisms are complementary, not competing.

### §8 — Interaction with M104

M104 wraps `TEST_CMD` invocations with `run_op` for TUI liveness. If M104 lands
first, the dedup wrapping goes around the `run_op` line:

```bash
if test_dedup_can_skip; then
    ...
else
    test_output=$(run_op "Running acceptance tests" bash -c "${TEST_CMD}" 2>&1) || test_exit=$?
    ...
fi
```

If M105 lands first, M104 adds `run_op` inside the `else` branch. Either order
works — the edits are structurally compatible.

## Files Modified

| File | Change |
|------|--------|
| **NEW** `lib/test_dedup.sh` | Core functions: `_test_dedup_fingerprint`, `test_dedup_record_pass`, `test_dedup_can_skip`, `test_dedup_reset` |
| `lib/config_defaults.sh` | Add `TEST_DEDUP_ENABLED` default (~line 388) |
| `tekhton.sh` | Source `lib/test_dedup.sh` (after `lib/gates_completion.sh`, before `lib/hooks.sh`) |
| `lib/orchestrate.sh` | Call `test_dedup_reset` at loop entry; wrap pre-finalization TEST_CMD at line 287 |
| `lib/milestone_acceptance.sh` | Wrap TEST_CMD at line 77 |
| `lib/gates_completion.sh` | Wrap TEST_CMD at line 77 |
| `lib/hooks_final_checks.sh` | Wrap TEST_CMD at lines 90 and 127 |
| `lib/orchestrate_preflight.sh` | Wrap TEST_CMD at line 78 |

## Acceptance Criteria

- [ ] `test_dedup_can_skip` returns 1 (must run) when no fingerprint file exists
- [ ] `test_dedup_can_skip` returns 1 (must run) when `TEST_DEDUP_ENABLED=false`
- [ ] After `test_dedup_record_pass`, `test_dedup_can_skip` returns 0 (skip) when
      no files have changed
- [ ] After `test_dedup_record_pass`, modifying any file causes
      `test_dedup_can_skip` to return 1 (must run)
- [ ] After `test_dedup_record_pass`, adding an untracked file causes
      `test_dedup_can_skip` to return 1 (must run)
- [ ] `test_dedup_reset` removes the fingerprint file and causes subsequent
      `test_dedup_can_skip` to return 1
- [ ] Changing `TEST_CMD` between calls invalidates the fingerprint (returns
      must-run) even with no file changes
- [ ] On a successful milestone run, the pre-finalization gate at
      `lib/orchestrate.sh:287` logs a dedup skip message when acceptance tests
      at `lib/milestone_acceptance.sh:77` already passed with no intervening
      code changes
- [ ] `test_baseline.sh:90` (baseline capture) does NOT participate in dedup —
      it always runs `TEST_CMD` unconditionally
- [ ] The causal event `test_dedup_skip` is emitted when a test run is skipped
- [ ] `_PREFLIGHT_TESTS_PASSED` is still set to `true` when the pre-finalization
      gate is skipped via dedup (so `_hook_final_checks` continues to skip)
- [ ] In a non-git directory, `test_dedup_can_skip` always returns 1 (dedup
      disabled gracefully)
- [ ] `shellcheck` passes on all modified `.sh` files with zero new warnings
- [ ] All existing tests pass (`bash tests/run_tests.sh`)
