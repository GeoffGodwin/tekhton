# M121 - Planning Path Write-Failure Hardening + Empty-Slate Test Coverage

<!-- milestone-meta
id: "121"
status: "done"
-->

## Overview

M120 stops the DESIGN_FILE landmine at its source (init emits a real
default; plan-mode re-applies defaults after `load_plan_config`). M121
is the defence-in-depth pass: make sure a future regression to the same
class of bug — empty string, path-to-directory, silent write failure —
can't hide again.

The original issue #179 failed silently for three compounding reasons:

1. **No assertions.** No plan-mode consumer asserted `DESIGN_FILE` was
   non-empty or that the composed path wasn't the project root.
2. **Write failure didn't propagate.** The `printf '%s\n' "$design_content"
   > "$design_file"` at `stages/plan_interview.sh:195` returned non-zero
   (write to a directory), but a failed redirection inside a function
   under `set -euo pipefail` doesn't abort the function in bash. The
   stage carried on, fabricated a `design_status="exists (0 lines)"`
   default, and called `success`.
3. **No test exercised the `--init` → `--plan` empty-slate flow.** The
   two halves are tested in isolation; the generated `pipeline.conf`
   never round-trips through a real plan invocation in CI.

M121 fixes all three. It's independent of M120 in implementation but
depends on M120 semantically: the assertions below should never fire
on a correctly-functioning pipeline, and with M120 in place they won't
fire on legitimate configs. If M121 ships without M120, these
assertions would correctly abort the current broken flow (at least
loudly instead of silently).

## Design

### Goal 1 — Fail-loud assertions at every planning entry point

Add a single shared helper in `lib/plan.sh`:

```bash
# _assert_design_file_usable — Guard against empty or directory-valued
# DESIGN_FILE. Called at the top of every --plan / --replan /
# --plan-from-index consumer before composing a path from DESIGN_FILE.
_assert_design_file_usable() {
    if [[ -z "${DESIGN_FILE:-}" ]]; then
        error "DESIGN_FILE is empty. Check pipeline.conf — the value should point to a markdown file (default: .tekhton/DESIGN.md)."
        return 1
    fi
    if [[ "${DESIGN_FILE}" == */ ]]; then
        error "DESIGN_FILE ends in '/' (directory path, not a file): ${DESIGN_FILE}"
        return 1
    fi
    return 0
}
```

Called at the top of (each call is a single `_assert_design_file_usable ||
return $?` line):

- `run_plan_interview` in `stages/plan_interview.sh` (before line 50).
- `run_plan_generate` in `stages/plan_generate.sh` (before line 32).
- `check_design_completeness` in `lib/plan_completeness.sh` (before
  line 160).
- `run_plan_completeness_loop` in `lib/plan_completeness.sh` (before
  line 216).
- `run_replan_brownfield` in `lib/replan_brownfield.sh` (before line
  90).
- `_apply_brownfield_delta` in `lib/replan_brownfield.sh` (before line
  257).

Do **not** add the assertion to `lib/plan_state.sh:51` (state-file
rendering). That path is cosmetic and tolerates an empty or bad value
— it just renders a label. Let it stay lenient to avoid crashing a
state-save on a degenerate config.

### Goal 2 — Verify the write in `run_plan_interview`

Currently (`stages/plan_interview.sh:192-200`):

```bash
local design_status="not created"
if [[ -n "$design_content" ]]; then
    if [[ "$_disk_rescued" == "false" ]]; then
        printf '%s\n' "$design_content" > "$design_file"
    fi
    local line_count
    line_count=$(count_lines < "$design_file")
    design_status="exists (${line_count} lines)"
fi
```

The `printf > "$design_file"` can fail (directory, permission, read-
only filesystem) without aborting. Replace with:

```bash
local design_status="not created"
if [[ -n "$design_content" ]]; then
    if [[ "$_disk_rescued" == "false" ]]; then
        if ! printf '%s\n' "$design_content" > "$design_file" 2>/dev/null; then
            error "Failed to write ${DESIGN_FILE} to ${design_file}."
            error "Check that the path is a file (not a directory) and the parent directory is writable."
            exec 3<&- 2>/dev/null || true
            return 1
        fi
    fi
    if [[ ! -s "$design_file" ]]; then
        error "${DESIGN_FILE} write appeared to succeed but the file is empty or missing at ${design_file}."
        exec 3<&- 2>/dev/null || true
        return 1
    fi
    local line_count
    line_count=$(count_lines < "$design_file")
    design_status="exists (${line_count} lines)"
fi
```

Two independent checks: (a) the `printf` redirection actually
succeeded, and (b) the file on disk has non-zero size after. Either
failure returns 1 from `run_plan_interview`, which the caller in
`lib/plan.sh` already handles (its `run_plan` wrapper logs and exits
non-zero).

### Goal 3 — Config validator gains a DESIGN_FILE shape check

`lib/validate_config.sh:120-131` already has a soft check for
`DESIGN_FILE` (warns if set but file-not-found; passes if unset). Add
two stricter checks before the existing ones. Wording is deliberately
self-heal-aware: the validator runs for both plan-mode and execution-
pipeline users, and brownfield users with a pre-M120 `pipeline.conf`
(literal `DESIGN_FILE=""`) should not feel scolded — M120 already
self-heals the empty value at runtime, so the message is informational.

```bash
# Check 6a: DESIGN_FILE is explicitly empty
if [[ -n "${DESIGN_FILE+set}" ]] && [[ -z "${DESIGN_FILE}" ]]; then
    _vc_warn "DESIGN_FILE is an empty string in pipeline.conf. Tekhton will fall back to the default (.tekhton/DESIGN.md) when needed — you can safely remove the line, set it to the default explicitly, or point it at your existing design doc if you keep one elsewhere."
fi

# Check 6b: DESIGN_FILE ends in '/' (not a file path)
if [[ -n "${DESIGN_FILE:-}" ]] && [[ "${DESIGN_FILE}" == */ ]]; then
    _vc_warn "DESIGN_FILE ends in '/' (directory path, not a file): ${DESIGN_FILE}. This will cause planning-mode writes to fail. Fix: remove the trailing slash or point the key at a markdown file."
fi
```

These surface the landmine at `tekhton --validate` time but frame it
as informational for check 6a (brownfield-safe) and actionable for
check 6b (truly broken).

### Goal 4 — Integration test: `--init` → `--plan` empty slate

New file: `tests/test_plan_empty_slate.sh`.

Approach: mirror the pattern in existing plan-mode tests (source the
relevant libs, stub the agent call, assert file existence). Steps:

1. Create a fresh temp directory under `$TMPDIR`.
2. Run `tekhton.sh --init` non-interactively (supply answers via env
   vars or stdin as existing init tests do).
3. Assert the generated `pipeline.conf` contains
   `DESIGN_FILE=".tekhton/DESIGN.md"` (post-M120) — this is the
   regression check for the bug's root.
4. Simulate `--plan` far enough to reach the write path. Stub
   `_call_planning_batch` to produce known `DESIGN.md` content.
5. Assert `.tekhton/DESIGN.md` exists and contains the stubbed content
   (not zero bytes, not a directory).
6. Assert `DESIGN_FILE` in the shell is non-empty at the moment of
   write.
7. Negative test: craft a `pipeline.conf` that explicitly sets
   `DESIGN_FILE=""`. Run `--plan` and assert that (a) the write still
   succeeds (because M120 re-defaults) and (b) `_assert_design_file_usable`
   does not trip.

### Goal 5 — Unit test: `load_plan_config` empty-value behavior

New test in `tests/test_plan_config_loader.sh` (or append to an
existing plan-config test if one exists — none found in the current
tree):

- Source `lib/plan.sh` in a subshell with
  `PROJECT_DIR=<temp>/empty_design`, where
  `<temp>/empty_design/.claude/pipeline.conf` contains
  `DESIGN_FILE=""`. Assert `DESIGN_FILE == "${TEKHTON_DIR}/DESIGN.md"`
  after sourcing (post-M120 re-default worked).
- Same setup with `pipeline.conf` containing
  `DESIGN_FILE="custom/path.md"`. Assert `DESIGN_FILE == "custom/path.md"`
  (user value preserved).
- Same setup with no `pipeline.conf` at all. Assert `DESIGN_FILE ==
  "${TEKHTON_DIR}/DESIGN.md"` (pure default path).

### Goal 6 — Register the new tests

Add both test files to the test runner at `tests/run_tests.sh` and
ensure they pass under the self-test harness.

## Files Modified

| File | Change |
|------|--------|
| `lib/plan.sh` | Add `_assert_design_file_usable` helper near the top of the file (after `load_plan_config` block). |
| `stages/plan_interview.sh` | Call `_assert_design_file_usable` at the top of `run_plan_interview`. Replace the unchecked `printf ... > "$design_file"` with a checked write + post-write size assertion. |
| `stages/plan_generate.sh` | Call `_assert_design_file_usable` at the top of `run_plan_generate`. |
| `lib/plan_completeness.sh` | Call `_assert_design_file_usable` at the top of `check_design_completeness` and `run_plan_completeness_loop`. |
| `lib/replan_brownfield.sh` | Call `_assert_design_file_usable` at the top of `run_replan_brownfield` and `_apply_brownfield_delta`. |
| `lib/validate_config.sh` | Add checks 6a and 6b (empty-string and trailing-slash warnings) before existing check 6. |
| `tests/test_plan_empty_slate.sh` | **New file.** Integration test for `--init` → `--plan` empty-slate flow. |
| `tests/test_plan_config_loader.sh` | **New file.** Unit test for `load_plan_config` empty/custom/default cases. |
| `tests/run_tests.sh` | Register both new test files. |

## Acceptance Criteria

- [ ] `_assert_design_file_usable` exists in `lib/plan.sh` and returns
      1 with an error message when `DESIGN_FILE` is empty or ends in
      `/`. Returns 0 otherwise.
- [ ] All six listed call sites invoke the assertion before using
      `${DESIGN_FILE}` to compose a path.
- [ ] Hand-test: craft a `pipeline.conf` with `DESIGN_FILE=""`, delete
      `lib/artifact_defaults.sh` (simulating missing M120), run
      `tekhton --plan`. Assertion fires, pipeline aborts with a clear
      message, no directory-valued write is attempted.
- [ ] Restore M120, re-run the same scenario: assertion does not fire,
      pipeline writes `.tekhton/DESIGN.md` correctly.
- [ ] In `run_plan_interview`, inject a failing write (e.g.,
      `DESIGN_FILE` is a read-only path, or stub `printf` to return
      non-zero). Stage emits the new error line, returns 1, and no
      `success` message is printed.
- [ ] In `run_plan_interview`, the post-write `[[ ! -s "$design_file" ]]`
      check fires if `printf` succeeds but the file is zero-byte for
      any reason (defensive).
- [ ] `tekhton --validate` emits a warning for a `pipeline.conf`
      containing `DESIGN_FILE=""` (6a) and for one containing
      `DESIGN_FILE="some/dir/"` (6b). Does not warn for
      `DESIGN_FILE=".tekhton/DESIGN.md"` or for an unset key.
- [ ] **Brownfield safety — no new blocking behavior in execution
      pipeline**: in a project with `DESIGN_FILE=""` in pipeline.conf
      and no `.tekhton/DESIGN.md` on disk, `tekhton "some task"`
      (execution pipeline, not `--plan`) runs to completion without
      any new assertion firing. Specifically verified:
      `_assert_design_file_usable` is NOT called from any
      execution-pipeline stage (coder, reviewer, tester, security,
      intake, preflight). Assertions are confined to `--plan`,
      `--replan`, `--plan-from-index` call sites listed in Goal 1.
- [ ] **Brownfield safety — validator warnings are not blocking**:
      running `tekhton --validate` against a pipeline.conf with
      `DESIGN_FILE=""` prints a warning but exits 0 (matching
      existing soft-check behavior at `lib/validate_config.sh`).
      Warnings do not promote to errors.
- [ ] `tests/test_plan_empty_slate.sh` passes: fresh-dir `--init` →
      `--plan` produces `.tekhton/DESIGN.md` with non-zero content.
- [ ] `tests/test_plan_empty_slate.sh` negative case passes: crafted
      `DESIGN_FILE=""` config still round-trips cleanly (M120's
      self-healing in action).
- [ ] `tests/test_plan_config_loader.sh` passes all three cases
      (empty, custom, unset).
- [ ] Both new test files are registered in `tests/run_tests.sh` and
      picked up by the runner.
- [ ] Shellcheck clean for all modified and new files.
- [ ] No existing tests need edits to continue passing.

## Non-Goals

- Changing the behavior of `load_plan_config` itself (M120 already
  handled the root fix).
- Adding assertions to non-plan-mode consumers of `DESIGN_FILE`
  (`lib/crawler_content.sh`, `lib/detect_doc_quality.sh`,
  `lib/health_checks_infra.sh`). Those paths already tolerate empty
  values by using `${DESIGN_FILE:-}` and checking file existence.
- Migrating legacy `pipeline.conf` files that still contain
  `DESIGN_FILE=""` — M120 makes them self-healing; the validator
  warning in Goal 3 is sufficient nudging.
- Generalizing `_assert_design_file_usable` to cover other file-path
  config keys (`CODER_SUMMARY_FILE`, `TESTER_REPORT_FILE`, etc.). If a
  similar bug appears there, it would get its own narrow assertion.
- Adding a hard fail to `tekhton --validate` for the new warnings
  (keep them warnings; users running on older configs shouldn't be
  locked out).
- Changing the visual or log format of `error` / `success` calls.
