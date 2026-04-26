# Coder Summary
## Status: COMPLETE

## What Was Implemented
M126 — Deterministic UI Gate Execution & Non-Interactive Reporter Control.
The UI test phase of the build gate now applies a deterministic env profile
to every subprocess invocation, classifies failure timeouts into a stable
token vocabulary, and recovers from interactive-report hangs without burning
the existing M54 / generic-retry slots.

Concrete changes:

- `lib/gates_ui_helpers.sh` (NEW). Five pure helpers plus one writer:
  - `_ui_detect_framework` — priority order: `UI_FRAMEWORK=playwright`,
    word-boundary regex `(^|[[:space:]/])playwright([[:space:]]|$)` on
    `UI_TEST_CMD`, then `playwright.config.{ts,js,mjs,cjs}` in
    `$PROJECT_DIR`. Returns `playwright` or `none`.
  - `_ui_deterministic_env_list HARDENED?` — emits `PLAYWRIGHT_HTML_OPEN=never`
    on the normal-run profile; adds `CI=1` only when HARDENED=1.
  - `_normalize_ui_gate_env` — owner hook that delegates to the env list
    helper. M57 will extend this for additional adapters; do not add
    framework branches inline.
  - `_ui_timeout_signature EXIT_CODE OUTPUT` — pure classifier returning
    `interactive_report` | `generic_timeout` | `none`. No logging, no
    file writes. Exit-124 guard prevents false positives on shutdown
    chatter.
  - `_ui_hardened_timeout BASE FACTOR` — clamps to `[1, BASE]` so the
    hardened rerun never exceeds the original `UI_TEST_TIMEOUT`.
  - `_ui_write_gate_diagnosis` — appends `## UI Gate Diagnosis` to both
    `UI_TEST_ERRORS_FILE` and `BUILD_ERRORS_FILE` after the existing
    raw-output blocks.

- `lib/gates_ui.sh`. Refactored `_run_ui_test_phase`:
  - Every subprocess invocation runs through a new `_ui_run_cmd` wrapper
    that materializes the env list via `mapfile` and passes it at the
    `env(1)` boundary — no env mutation leaks into the parent shell.
  - On failure, `_ui_timeout_signature` classifies the run.
  - `interactive_report` branch skips M54 remediation and the generic
    flakiness retry; performs a single hardened rerun under the
    `UI_GATE_ENV_RETRY_*` knobs (inline `${VAR:-default}` fallbacks —
    M136 will formalize these in `config_defaults.sh`).
  - `generic_timeout` and `none` branches run the existing M54
    remediation and generic flakiness retry exactly as before.
  - Diagnosis is written only on terminal failure; `gates.sh:212-213`
    cleanup handles suppression on recovered pass.

- `tests/test_ui_build_gate.sh`. Added 7 tests (13–19) covering: pure
  signature classifier truth table, deterministic env reaches subprocess
  while parent stays unset, word-boundary framework detection,
  hardened-rerun invocation count and success log line, generic-timeout
  retry path preserved, diagnosis block format on terminal failure, and
  diagnosis suppression on recovered pass. Header comment block and
  summary line updated to 19/19. Added `unset _TUI_ACTIVE` early so
  `log()` output is deterministic regardless of caller environment.

- `tekhton.sh`. Added `source "${TEKHTON_HOME}/lib/gates_ui_helpers.sh"`
  immediately after `gates_phases.sh` and before `gates_ui.sh` so the
  consumer sees the helpers at parse time.

- Docs:
  - `docs/reference/stages.md` — Build gate section now describes the
    deterministic UI test phase, env profile, hardened rerun, and
    diagnosis emission.
  - `docs/troubleshooting/common-errors.md` — New entry under
    `## Pipeline Errors`: "UI tests timed out with interactive report
    serving" with symptom, automatic recovery, and permanent fixes.
  - `ARCHITECTURE.md` — Added `lib/gates_ui_helpers.sh` to the Layer 3
    library catalog with helper-by-helper signatures and source-order
    note.

## Root Cause (bugs only)
N/A — feature implementation, not a bug fix. The motivating defect
(bifl-tracker M03 hang) is described in the milestone overview; this
milestone makes gate execution deterministic so future classification
and routing layers (M127–M130) can reason over stable signal.

## Files Modified
- `lib/gates_ui_helpers.sh` (NEW) — 163 lines.
- `lib/gates_ui.sh` — refactored to apply deterministic env on every
  invocation, branch on timeout signature, emit diagnosis. 183 lines.
- `tests/test_ui_build_gate.sh` — added 7 tests (13–19), refreshed
  header and summary, unset `_TUI_ACTIVE` for deterministic logging.
  490 lines.
- `tekhton.sh` — sources the new helpers between `gates_phases.sh` and
  `gates_ui.sh` (one line added).
- `ARCHITECTURE.md` — added catalog entry for `lib/gates_ui_helpers.sh`.
- `docs/reference/stages.md` — added UI test phase paragraph to Build
  gate section.
- `docs/troubleshooting/common-errors.md` — new entry for the
  interactive-report timeout class.

## Docs Updated
- `docs/reference/stages.md` — documents the new deterministic UI gate
  behavior (env profile, hardened rerun, diagnosis).
- `docs/troubleshooting/common-errors.md` — new troubleshooting entry
  for the interactive_report timeout class with permanent-fix guidance.
- `ARCHITECTURE.md` — catalog entry for the new helpers file.

## Human Notes Status
No human notes were attached to this task (HUMAN_NOTES.md contained
only the boilerplate template).

## Verification
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — zero warnings.
- `bash tests/run_tests.sh` — 454/454 shell tests pass, 247/247 Python
  tests pass.
- `bash tests/test_ui_build_gate.sh` — 19/19 tests pass (12 baseline +
  7 new M126 tests).
- File length: every modified `.sh` file under the 300-line ceiling
  (gates_ui.sh: 183, gates_ui_helpers.sh: 163).

## Observed Issues (out of scope)
None.
