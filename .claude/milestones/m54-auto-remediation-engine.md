# Milestone 54: Auto-Remediation Engine
<!-- milestone-meta
id: "54"
status: "done"
-->

## Overview

Milestone 53 classifies build errors into categories. This milestone acts on
that classification: when the registry identifies a `safe`-rated remediation
command, the build gate executes it automatically, then re-runs only the failed
phase. This eliminates the most common class of pipeline stalls — environment
setup issues that have known, deterministic fixes.

The engine is conservative by design: max 2 remediation attempts per gate run,
only `safe`-rated commands execute, all actions logged to the causal event log.
`prompt`-rated remediations are written to HUMAN_ACTION_REQUIRED.md for the
operator. `manual`-rated issues get clear diagnosis but no automated action.

Depends on Milestone 53 (error pattern registry). Can run in parallel with
Milestone 55 (pre-flight).

## Scope

### 1. Remediation Executor (`lib/error_patterns.sh` — extend)

Add functions to the error pattern registry:

- `attempt_remediation()` — Takes classified error output, executes safe
  remediation commands. Returns 0 if at least one remediation succeeded, 1 if
  none succeeded or none were safe. Tracks attempted commands to avoid
  re-running the same fix twice in one gate invocation.
- `_run_safe_remediation()` — Executes a single remediation command with
  timeout (60s default), captures output, returns exit code. Never runs
  commands rated below `safe`.
- `_remediation_already_attempted()` — Checks in-memory set of already-tried
  commands to prevent loops.

**Safety enforcement:**
- Only `safe`-rated commands execute automatically
- Each command runs in a subshell with a 60-second timeout
- Commands execute from `$PROJECT_DIR` (not TEKHTON_HOME)
- stderr/stdout captured for logging, not shown to user unless verbose
- Max 2 total remediation attempts per gate invocation (across all phases)
- No remediation command may contain `rm -rf`, `drop`, `delete`, `destroy`,
  `reset --hard`, or `force` (blocklist enforced in `_run_safe_remediation`)

### 2. Build Gate Remediation Loop (`lib/gates.sh` — extend)

Modify the failure path for each build gate phase:

```
Phase fails
  → classify_build_errors_all(output)
  → separate: remediable (safe) vs non-remediable
  → if remediable AND attempts_remaining > 0:
      → attempt_remediation(remediable_errors)
      → if any succeeded:
          → re-run ONLY the failed phase (not all 5 phases)
          → if passes: continue to next phase
          → if fails again: fall through to normal failure path
  → if non-remediable or remediation exhausted:
      → write classified BUILD_ERRORS.md
      → route to build-fix agent (code errors only) or human action
```

**Key change**: The gate currently re-runs the entire gate on retry. After this
milestone, only the specific failed phase re-runs after remediation. This saves
time and avoids re-running already-passed phases.

Remove the hardcoded Playwright/Cypress `if` blocks added in the prior hotfix —
these patterns now flow through the registry.

### 3. Human Action Routing (`lib/gates.sh`, `lib/hooks.sh`)

For `manual`-rated and `prompt`-rated errors that cannot be auto-fixed:

- Append clear diagnosis to HUMAN_ACTION_REQUIRED.md:
  ```
  ## Environment Issue — [timestamp]
  **Category:** service_dep
  **Diagnosis:** PostgreSQL is not running on port 5432
  **Suggested fix:** Start PostgreSQL: `sudo systemctl start postgresql`
  or `docker-compose up -d postgres`
  **Pipeline impact:** Tests requiring database will fail until resolved.
  ```
- For `prompt`-rated: also append to HUMAN_ACTION_REQUIRED.md with a note
  that the fix is automatable if the user opts in (future: config flag)

### 4. Causal Log Integration (`lib/error_patterns.sh`)

Every remediation attempt emits a causal event via `emit_event()`:

```bash
emit_event "remediation_attempted" \
    "category=env_setup" \
    "command=npx playwright install" \
    "exit_code=0" \
    "duration_s=14" \
    "phase=build_gate_ui_test"
```

Events emitted:
- `remediation_attempted` — Command was run (with exit code and duration)
- `remediation_skipped` — Pattern matched but safety rating blocked auto-fix
- `human_action_required` — Issue routed to HUMAN_ACTION_REQUIRED.md

### 5. Remediation Report in Run Summary (`lib/finalize_summary.sh`)

Add a "Remediations" section to RUN_SUMMARY.json listing all auto-fix
attempts, their outcomes, and any human-action items generated.

## Acceptance Criteria

- `attempt_remediation()` executes safe-rated commands and returns success/failure
- Remediation commands run with 60s timeout in a subshell
- Blocklisted command fragments (`rm -rf`, `drop`, etc.) are rejected
- Max 2 remediation attempts per gate invocation enforced
- After successful remediation, only the failed phase re-runs (not all phases)
- `manual` and `prompt` errors are written to HUMAN_ACTION_REQUIRED.md
- Causal log contains remediation events after any build gate failure
- RUN_SUMMARY.json includes remediation section
- Hardcoded Playwright/Cypress blocks removed from gates.sh
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n` and `shellcheck` pass on all modified files
- New tests in `tests/test_error_patterns.sh` (extend from M53):
  - Safe command executes and gate re-runs phase
  - Manual command is NOT executed, routed to human action
  - Blocklisted command is rejected
  - Max 2 attempts enforced
  - Causal events emitted correctly

Watch For:
- Remediation commands must run from `$PROJECT_DIR`, not `$TEKHTON_HOME`. Use
  `(cd "$PROJECT_DIR" && timeout 60 bash -c "$cmd")` pattern.
- The `npm install` remediation can take 30+ seconds on large projects. The 60s
  timeout must be generous enough. Consider making it configurable per-pattern
  in a future iteration.
- Re-running a single phase requires the gate to track which phase failed. The
  current `run_build_gate()` function is monolithic. Extract each phase into a
  callable function (e.g., `_gate_phase_ui_test()`) that can be invoked
  independently.
- The `attempt_remediation()` function must be idempotent: running `npm install`
  twice is harmless, but some commands may not be. The `_remediation_already_attempted`
  check prevents this.
- `HUMAN_ACTION_REQUIRED.md` already exists in the pipeline. Append to it, don't
  overwrite. Use the existing format with `## ` section headers.

Seeds Forward:
- Milestone 55 reuses `attempt_remediation()` for pre-flight auto-fixes
- The causal log remediation events feed into Watchtower dashboards (future)
- Per-project custom patterns (future) can add project-specific remediation commands
