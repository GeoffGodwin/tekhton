# M126 - Deterministic UI Gate Execution & Non-Interactive Reporter Control

<!-- milestone-meta
id: "126"
status: "pending"
-->

## Overview

The bifl-tracker M03 failure exposed a repeatable gate-level defect:
`UI_TEST_CMD` can enter a long-lived interactive report server mode
and never terminate on its own, which causes Tekhton to hit
`UI_TEST_TIMEOUT` and return exit code 124. In that state, the gate
knows only that the process timed out; it does not distinguish:

1. Real test execution slowness (legitimate long run), versus
2. Interactive reporter serving mode (command completed tests but
   stayed alive waiting for Ctrl+C), versus
3. Dev-server readiness drift where tests never got to meaningful
   assertions.

In the failing run, Playwright output included:
`Serving HTML report at http://localhost:9323. Press Ctrl+C to quit.`
That line is definitive evidence the command entered an interactive
tail mode that is incompatible with deterministic build gates.

M126 makes UI gate execution deterministic by design. The gate will:

- Normalize known E2E commands into non-interactive execution mode.
- Detect interactive-report signatures when timeout still occurs.
- Re-run once with a hardened, non-interactive command profile.
- Emit a structured diagnosis when deterministic mode still fails.

This milestone does not redesign full error taxonomy scoring
(planned for follow-up milestones). It only ensures gate execution
semantics are deterministic and reproducible so later classification
and routing layers can reason over stable signal.

## Design

### Goal 1 — Add a deterministic UI gate command normalizer

Add three small helpers in `lib/gates_ui.sh` (or `lib/gates_ui_helpers.sh`
if the file would otherwise exceed the 300-line ceiling — see
"Files Modified" note).

```bash
# _ui_detect_framework
#   Reads UI_FRAMEWORK, UI_TEST_CMD, and PROJECT_DIR. Echoes one of:
#   playwright | cypress | selenium | puppeteer | testing-library | detox | none
#   M126 only branches on `playwright`; other values short-circuit to "none-acting".

# _ui_deterministic_env_list HARDENED?
#   Echoes zero or more KEY=VALUE lines (one per line) to be passed to `env`
#   when invoking UI_TEST_CMD. HARDENED=1 forces the most aggressive profile
#   (used only by the hardened-rerun branch from Goal 3); default is the
#   normal-run profile.

# _normalize_ui_gate_env HARDENED?
#   Thin owner hook that materializes the subprocess env list by calling
#   _ui_deterministic_env_list. Later milestones patch this wrapper for
#   logging and adapter dispatch; _ui_deterministic_env_list remains the
#   pure helper that decides which KEY=VALUE lines are emitted.
```

Normalization rules for this milestone:

1. Preserve configured `UI_TEST_CMD` verbatim as the primary command.
   M126 does not rewrite arguments or replace reporter flags — env-only
   hardening avoids package-manager argument-parsing drift.
2. When `_ui_detect_framework` returns `playwright`, the **normal-run**
   profile injects:
   - `PLAYWRIGHT_HTML_OPEN=never` (the single env var that prevents
     report serving regardless of reporter config)
3. The **hardened-rerun** profile (HARDENED=1) additionally injects:
   - `CI=1` (forces non-interactive Playwright behavior in case the
     project's playwright.config overrides `host: 'open'` directly).
   `CI=1` is scoped to the hardened rerun only because it changes more
   than reporter behavior (forces `--forbid-only`, increases default
   retries) — we want that hammer only when the first deterministic
   run already failed with an interactive-report signature.
4. Env injection mechanism — apply env at the `env` boundary so it never
   mutates the parent shell:
   ```bash
   local _env_list=()
  mapfile -t _env_list < <(_normalize_ui_gate_env)
   _ui_output=$(run_op "Running UI tests" \
       env "${_env_list[@]}" timeout "$_ui_timeout" \
       bash -c "$UI_TEST_CMD" 2>&1) || _ui_exit=$?
   ```
   When `_env_list` is empty, `env` with no `KEY=VAL` args is a no-op
   passthrough and is safe.
5. Apply the normal-run env to **every** UI subprocess invocation in
   `_run_ui_test_phase` — not just the first run. That includes the
   M54 registry-remediation rerun, the hardened rerun, and the existing
   generic flakiness retry. The env is purely about reporter mode; no
   path benefits from omitting it.
6. Framework-specific command rewrites for Cypress/Detox/etc. are
   explicitly deferred. They return `none` from `_ui_detect_framework`
   and behave exactly as today.

> **Extension point — m57 (UI Platform Adapter Framework):**
> `_normalize_ui_gate_env` is the public owner hook that m57 will extend
> when Cypress, Selenium, and other frameworks need their own non-interactive
> env profiles. In M126 it stays thin and delegates the Playwright-specific
> env selection to `_ui_deterministic_env_list`. In m57's model, each adapter
> registers its own `_ui_gate_env_<framework>()` function; `_normalize_ui_gate_env`
> dispatches to the registered adapter or falls back to the Playwright path.
> **Do not add `if [[ "$framework" == "cypress" ]]` branches here** — use
> the m57 adapter registration instead.

Framework detection priority (first match wins):

1. `UI_FRAMEWORK=playwright` in config (already validated by
   `lib/config.sh:188-193`).
2. `UI_TEST_CMD` matches the regex `(^|[[:space:]/])playwright([[:space:]]|$)`
   (word-boundary match — avoids false positives on paths like
   `./test-playwright-helper.sh` or arg substrings).
3. Presence of `playwright.config.{ts,js,mjs,cjs}` in `$PROJECT_DIR`.

If any of the above match, apply the Playwright deterministic env.

### Goal 2 — Add timeout signature detection for interactive report serving

Add a pure parser helper in `lib/gates_ui.sh` (or the helpers file from
Goal 1):

```bash
# _ui_timeout_signature EXIT_CODE OUTPUT
# Prints one of: interactive_report | generic_timeout | none
# Pure function — no side effects, no logging. Easy to unit-test directly.
```

Detection logic (order matters — first match wins):

- If `EXIT_CODE == 124` AND `OUTPUT` contains either of:
  - `Serving HTML report at`
  - `Press Ctrl+C to quit`
  classify as `interactive_report`. The exit-124 guard ensures we only
  treat this as the pathology when `timeout` actually fired; a normal
  exit-0 run that printed the same line during shutdown is not the bug
  we're solving.
- Else if `EXIT_CODE == 124`, classify as `generic_timeout`.
- Else `none`.

Call this helper only on the failure path (`_ui_exit != 0`).

### Goal 3 — Deterministic re-run branch, mutually exclusive with generic retry

The existing flow in `lib/gates_ui.sh:42-61` is:

```
run #1 (raw UI_TEST_CMD)
  └─ if fail: M54 registry remediation (env_setup auto-fix) → rerun on success
       └─ if still fail: generic flakiness retry (one extra run)
```

M126 inserts a deterministic-recovery branch and reuses run slots
rather than stacking them. The replacement flow in `_run_ui_test_phase`:

```
run #1 (UI_TEST_CMD with normal-run deterministic env)
  └─ pass → return 0
  └─ fail → classify with _ui_timeout_signature
       │
       ├─ signature == interactive_report:
       │     SKIP M54 remediation (not an env_setup error)
       │     SKIP generic flakiness retry (same hang would recur)
       │     Run hardened rerun (HARDENED=1 env profile)
       │       └─ pass → log
       │           "UI tests passed after deterministic reporter hardening."
       │           return 0
       │       └─ fail → write diagnosis, return 1
       │
       └─ signature in {generic_timeout, none}:
             Existing M54 remediation path runs unchanged
             (with normal-run env applied to the rerun)
             then existing generic flakiness retry runs unchanged
             (also with normal-run env applied)
             then existing failure artifact path with diagnosis block
```

Rationale for mutual exclusion:

- **`interactive_report` path:** M54 remediation only fires for
  classified env_setup errors (browser-not-installed, etc.); an
  interactive-report hang produces no such classification, so the
  remediation branch would be a no-op. A generic retry of the same
  command without env hardening would just hang again. Worst-case
  invocation count stays at 2 (run #1 + hardened rerun), bounded by
  `2 × UI_TEST_TIMEOUT`.
- **Other failures:** preserve current behavior exactly. No regression
  in M53/M54 auto-remediation or in flakiness mitigation.

This avoids the current pathology where two identical interactive
commands time out back-to-back, while not stacking 3-4 subprocess
invocations on every failure.

Two inline-fallback knobs are introduced for this deterministic-retry
branch and formalized later by M136 in `config_defaults.sh`:

- `UI_GATE_ENV_RETRY_ENABLED` (default `true`) — when `false`, skip the
  hardened rerun entirely and write terminal diagnosis immediately on an
  `interactive_report` signature.
- `UI_GATE_ENV_RETRY_TIMEOUT_FACTOR` (default `0.5`) — the hardened rerun
  gets `UI_TEST_TIMEOUT * factor`, clamped to at least 1 second and at
  most the original `UI_TEST_TIMEOUT`, so the non-interactive retry fails
  faster than the original hung command when the env hardening does not
  help.

On the `interactive_report` path, the hardened rerun therefore becomes:

```
run #2 (HARDENED=1 env profile, timeout = UI_TEST_TIMEOUT * UI_GATE_ENV_RETRY_TIMEOUT_FACTOR)
```

When `UI_GATE_ENV_RETRY_ENABLED=false`, the branch still classifies as
`interactive_report` and writes diagnosis, but it performs no rerun.

### Goal 4 — Emit structured gate diagnosis for timeout classes

Diagnosis is written **only on terminal gate failure** — never on a
recovered pass. Both `UI_TEST_ERRORS_FILE` and the appended block in
`BUILD_ERRORS_FILE` get the same `## UI Gate Diagnosis` section,
appended **after** the existing `## Output (last N lines)` and
`## UI Test Failures` blocks (so the build-fix agent sees raw output
first, then the diagnosis pointing at the suspected class).

Section format:

```markdown
## UI Gate Diagnosis
- Timeout class: interactive_report | generic_timeout | none
- Deterministic env applied: yes (normal) | yes (hardened) | no
- Hardened rerun attempted: yes | no
- Suggested action: <single actionable sentence>
```

Suggested action mapping:

- `interactive_report` →
  `Command stays alive serving the HTML report; configure the gate to disable report serving (PLAYWRIGHT_HTML_OPEN=never) or pass --reporter=line to UI_TEST_CMD.`
- `generic_timeout` →
  `Increase UI_TEST_TIMEOUT only after confirming the command is non-interactive and any required dev server is healthy.`
- `none` →
  `UI tests failed without a recognized timeout signature; inspect the captured output for the underlying assertion or runtime error.`

Suppress the diagnosis when the gate ultimately passes (recovered run,
hardened-rerun success). The clean-state contract from
`run_build_gate` (`gates.sh:212-213` removes `BUILD_ERRORS_FILE` and
`UI_TEST_ERRORS_FILE` on overall pass) already handles cleanup — do
not duplicate that logic in `gates_ui.sh`.

### Goal 5 — Add focused tests for deterministic UI execution

Expand `tests/test_ui_build_gate.sh` (currently 12 tests passing — see
its header) with deterministic-mode coverage. Existing tests must
continue to pass unchanged.

All new tests use shell stubs only — no real Playwright, no network,
no real browsers. Reuse the state-file pattern from existing Test 8
(`fail_then_pass.sh` with `RETRY_STATE` counter) for invocation-count
assertions.

Add at minimum:

1. **`unit_signature_parser`** (pure-function unit test)
   Call `_ui_timeout_signature` directly with crafted arg pairs —
   no gate invocation. Cover the truth table:
   - `(124, "...Serving HTML report at...")` → `interactive_report`
   - `(124, "...Press Ctrl+C to quit")` → `interactive_report`
   - `(0,   "...Serving HTML report at...")` → `none`
     (exit-0 guard prevents false positive on shutdown chatter)
   - `(124, "Test timeout exceeded")` → `generic_timeout`
   - `(1,   "AssertionError")` → `none`

2. **`deterministic_playwright_env_applied`**
   Fixture: `UI_TEST_CMD` is a stub script that writes
   `${TMPDIR}/seen_env.txt` with the value of `$PLAYWRIGHT_HTML_OPEN`
   then exits 0. Set `UI_FRAMEWORK=playwright`. After running the
   gate, assert `seen_env.txt` contains `never`. Also assert
   `$PLAYWRIGHT_HTML_OPEN` is **unset** in the parent shell after the
   gate returns (no env mutation leaks).

3. **`framework_detection_word_boundary`**
   Fixture: `UI_FRAMEWORK=""` (force regex/file-based detection),
   `UI_TEST_CMD="./test-playwright-helper.sh"` where the script is
   not actually playwright. Assert `_ui_detect_framework` returns
   `none` (regex must require word boundary, not substring).

4. **`hardened_rerun_executed_once_on_interactive_report`**
   Fixture: stub script that on its first invocation prints
   `Serving HTML report at http://localhost:9323. Press Ctrl+C to quit.`
   and exits 124, on its second invocation prints `ok` and exits 0.
   Track invocation count via `RETRY_STATE` file. Assert:
   - Gate returns 0
   - Stub was invoked exactly **2** times (run #1 + hardened rerun;
     M54 remediation and generic retry must be skipped)
   - Log line `UI tests passed after deterministic reporter hardening.`
     was emitted

5. **`generic_timeout_preserves_existing_retry_path`**
   Fixture: stub script that prints `Test timeout exceeded` and
   exits 124 on every invocation (no interactive-report signature).
   Assert:
   - Gate returns 1
   - Stub was invoked exactly **2** times (run #1 + existing
     generic flakiness retry — same as today)
   - No hardened rerun happened

6. **`diagnosis_block_written_on_terminal_failure`**
   Fixture: same as Test 4 but stub stays interactive-report on the
   hardened rerun too. Assert `UI_TEST_ERRORS.md` and
   `BUILD_ERRORS.md` both contain:
   - Literal heading `## UI Gate Diagnosis`
   - `Timeout class: interactive_report`
   - `Hardened rerun attempted: yes`
   - The full `Suggested action:` sentence for `interactive_report`

7. **`diagnosis_suppressed_on_recovered_pass`**
   Fixture: same as Test 4 (recovers on hardened rerun). Assert
   neither `UI_TEST_ERRORS.md` nor `BUILD_ERRORS.md` exists (the
   existing `gates.sh:212-213` cleanup must still fire).

## Files Modified

| File | Change |
|------|--------|
| `lib/gates_ui.sh` | Add deterministic env normalization, interactive-report timeout signature detection, hardened rerun branch, and diagnosis metadata emission. Currently 117 lines; estimated +120-160 LOC. If the result exceeds the 300-line ceiling (CLAUDE.md non-negotiable rule 8), extract the new helpers (`_ui_detect_framework`, `_ui_deterministic_env_list`, `_normalize_ui_gate_env`, `_ui_timeout_signature`, diagnosis writers) into `lib/gates_ui_helpers.sh` and source it from `gates_ui.sh`. |
| `tests/test_ui_build_gate.sh` | Add seven deterministic-mode tests (see Goal 5). Update the header comment block and the final "All UI build gate tests passed (12/12)" summary to the new total. Currently 305 lines; well under the test-file budget. |
| `docs/reference/stages.md` | Update the build-gate description (around line 105–110) to note that the UI gate phase now applies a deterministic env profile for Playwright (`PLAYWRIGHT_HTML_OPEN=never`) and recovers once via a hardened rerun if it detects an interactive-report timeout signature. |
| `docs/troubleshooting/common-errors.md` | Add a new entry under `## Pipeline Errors` titled `### "UI tests timed out with interactive report serving"` covering the symptom (`Serving HTML report at ... Press Ctrl+C to quit` in the captured output, exit 124), the automatic recovery, and how to permanently fix it in the project's playwright config or `UI_TEST_CMD`. |

## Acceptance Criteria

- [ ] When `_ui_detect_framework` returns `playwright`, the UI gate subprocess sees `PLAYWRIGHT_HTML_OPEN=never` in its environment, and `$PLAYWRIGHT_HTML_OPEN` remains unset in the parent shell after the gate returns (no env leak).
- [ ] The hardened-rerun profile additionally sets `CI=1`; the normal-run profile does not.
- [ ] `_ui_detect_framework` returns `playwright` for `UI_FRAMEWORK=playwright`, for `UI_TEST_CMD` matching the word-boundary regex, and when `playwright.config.{ts,js,mjs,cjs}` exists in `$PROJECT_DIR`. It returns `none` for the false-positive case `./test-playwright-helper.sh`.
- [ ] `_ui_timeout_signature` is a pure function (no side effects, no logging) and produces the truth table specified in Goal 5 Test 1.
- [ ] When the first run fails with `interactive_report` signature, Tekhton invokes `UI_TEST_CMD` exactly **2** times total (run #1 + hardened rerun); M54 remediation and the existing generic flakiness retry are skipped on this branch.
- [ ] When the first run fails with `generic_timeout` or `none` signature, the existing M54 remediation path and the existing generic flakiness retry both run unchanged (with the normal-run env applied to every invocation).
- [ ] If the hardened rerun succeeds, the gate returns 0, no diagnosis or error file is left on disk (existing `gates.sh:212-213` cleanup), and the log contains the line `UI tests passed after deterministic reporter hardening.`.
- [ ] `UI_GATE_ENV_RETRY_ENABLED=false` suppresses the hardened rerun on the `interactive_report` branch without changing classification or diagnosis content.
- [ ] `UI_GATE_ENV_RETRY_TIMEOUT_FACTOR` scales only the hardened-rerun timeout; it never mutates the configured primary `UI_TEST_TIMEOUT` in the parent shell.
- [ ] If the hardened rerun fails, both `UI_TEST_ERRORS.md` and `BUILD_ERRORS.md` contain a `## UI Gate Diagnosis` section with the four bullet fields from Goal 4 populated.
- [ ] All 12 existing `tests/test_ui_build_gate.sh` tests still pass; the seven new tests from Goal 5 also pass; the summary line and header comment block reflect the new total.
- [ ] New tests run with no network access and no real Playwright/browser invocation.
- [ ] `shellcheck` reports zero warnings on every modified `.sh` file.
- [ ] Every modified `.sh` file is under the 300-line ceiling, or the extraction described in the Files Modified note has been performed.

## Watch For

- **`PLAYWRIGHT_HTML_OPEN` and `CI` must not leak into the parent
  shell.** Goal 5 Test 2 asserts the parent shell environment is
  unmodified after the gate returns. Apply env at the
  `env KEY=VAL ...` boundary on the subprocess invocation; never
  `export` either var in `lib/gates_ui.sh`.
- **`_ui_timeout_signature` is a pure function.** No `log`, no `warn`,
  no file writes. The unit test (Goal 5 Test 1) calls it directly; any
  side effect breaks the test and complicates downstream reuse from
  the diagnose stage.
- **Word-boundary regex in `_ui_detect_framework`.** Goal 5 Test 3
  covers the false-positive case `./test-playwright-helper.sh`. Use
  `(^|[[:space:]/])playwright([[:space:]]|$)`, not a substring match.
- **Diagnosis is suppression-on-pass.** The recovered-pass path
  (hardened rerun succeeds) must leave no `BUILD_ERRORS.md` or
  `UI_TEST_ERRORS.md` on disk. The existing `gates.sh:212-213` cleanup
  handles this — do not duplicate cleanup logic in `gates_ui.sh`.
- **Worst-case invocation budget is 2.** On the `interactive_report`
  branch, the M54 remediation and the generic flakiness retry are
  both skipped. Stacking them would burn `4 × UI_TEST_TIMEOUT` per
  failure.
- **300-line ceiling.** `lib/gates_ui.sh` is 117 lines today; +120-160
  LOC will exceed 300. Extract helpers into `lib/gates_ui_helpers.sh`
  if needed (already noted in Files Modified).

## Seeds Forward

- **M127 — Mixed-log classification hardening.** M127's classifier
  reads the same UI-gate output that M126 produces. Deterministic gate
  execution is the precondition for cleaner classification: without
  M126, even legitimate `noncode_dominant` outputs are contaminated by
  the interactive-reporter banner and timeout chatter, producing
  inconsistent routing decisions. M127 also adds an explicit
  non-diagnostic filter for the report-serving lines — they are the
  symptom M126 fixes at the source.
- **M129 — Failure context schema v2.** The `## UI Gate Diagnosis`
  block written on terminal failure (Goal 4) is a natural source for
  `primary_cause.signal` — for example `ui_timeout_interactive_report`
  for the `interactive_report` class. Keep the timeout-class token
  vocabulary in `_ui_timeout_signature` stable (`interactive_report`,
  `generic_timeout`, `none`) so M129 can map it 1:1 without a
  translation layer.
- **M130 — Causal-context-aware recovery routing.** M130 introduces a
  `retry_ui_gate_env` recovery action that exports
  `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1` and re-runs the UI gate.
  M126 does not yet honor this knob, but the cleanest place to wire it
  in is the framework-detection priority added in Goal 1. Consider
  adding a Priority 0 rule: `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1`
  → apply hardened env regardless of detected framework, and
  `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0` → short-circuit the
  normalizer entirely (user override). If M126 ships without this
  hook, M130 will need a follow-up patch to either implement it itself
  or invoke a different mechanism, so addressing it here costs less.
