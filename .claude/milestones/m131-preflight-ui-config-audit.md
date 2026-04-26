# M131 - Preflight Test Framework Config Audit & Interactive-Mode Detection

<!-- milestone-meta
id: "131"
status: "pending"
-->

## Overview

M126 makes UI gate execution deterministic *reactively* — when the gate
times out with an interactive-reporter signature, it re-runs with a
hardened, non-interactive env profile. M130 ensures a correct recovery
action is selected when that happens. Both milestones assume the failure
has already occurred.

M131 completes the circuit by moving detection *before* the first gate
run: the preflight layer scans the project's test framework config files
for settings that are known to produce interactive or non-deterministic
execution inside Tekhton's gated environment, warns the user (or
auto-patches where safe), and emits a structured preflight finding that
downstream layers (m126, m130) can use to short-cut recovery.

The canonical bifl-tracker failure pattern:

```
// playwright.config.ts
reporter: 'html',   // Opens serve-and-wait loop when not in CI
```

That one line is sufficient to cause the gate timeout that consumed four
hours in the original M03 run. M131 catches it in the first second of
the pipeline before any agent turn is consumed.

Three additional interactive-mode footguns are addressed at the same
time, because each has the same root structure (a test framework config
key whose value changes behavior from "exit 0/1" to "stay alive"):

| Framework | Config file | Key | Bad value | Why it blocks |
|-----------|-------------|-----|-----------|---------------|
| Playwright | `playwright.config.{ts,js,mjs,cjs}` | `reporter` | `'html'` or `['html']` | Launches `playwright show-report --port` and waits for Ctrl+C |
| Playwright | same | `use.video` | `'on'` or `'retain-on-failure'` | Not blocking, but produces gigabyte artifacts without `fullyParallel`; WARN only |
| Playwright | same | `webServer.reuseExistingServer` | `false` when a dev server is already running | Causes test runner hang waiting for port to free |
| Cypress | `cypress.config.{ts,js,mjs}` | `video` | `true` (default) in headless | Not blocking; bloats artifacts by default. WARN only |
| Cypress | same | `reporter` | `'mochawesome'` without `--exit` flag | Can orphan reporter process; WARN only |
| Jest / Vitest | `vitest.config.{ts,js}` / `jest.config.{ts,js}` | `watch` or `watchAll` | `true` | Launches watch mode — never terminates |

M131 does not attempt exhaustive config analysis. The rule set is
deliberately minimal: only the patterns that have produced confirmed
gate hangs in practice (Playwright html reporter, Jest/Vitest watch
mode) are `fail`-level findings. All others are `warn`-level. The
underlying `_pf_record` and `_pf_try_fix` infrastructure from m55 is
reused unchanged.

## Design

### Goal 1 — Add a new preflight check function: `_preflight_check_ui_test_config`

**File placement.** Add to a **new file `lib/preflight_checks_ui.sh`**, mirroring
the existing `lib/preflight_checks_env.sh` split. `lib/preflight_checks.sh` is
already 224 lines; the four new scanner functions plus the dispatcher and the
auto-fix helper add ~200 LOC, which would put `preflight_checks.sh` at ~424
lines and violate CLAUDE.md non-negotiable rule 8 (300-line ceiling). Splitting
from the start is cheaper than splitting after the fact.

`tekhton.sh` already sources `preflight_checks.sh` and `preflight_checks_env.sh`
adjacent to each other; add a `source "${TEKHTON_HOME}/lib/preflight_checks_ui.sh"`
line in the same neighborhood. The new file uses the same `set -euo pipefail`
header and the same `_pf_record` / `_pf_try_fix` helpers from `preflight.sh`
(no new infrastructure).

The function is invoked from `run_preflight_checks` in `lib/preflight.sh`
after `_preflight_check_tools`. It only runs when `UI_TEST_CMD` is configured,
non-empty, and not the no-op default `true`.

High-level structure:

```bash
# =============================================================================
# Check N: UI Test Framework Config Compatibility (M131)
# =============================================================================
_preflight_check_ui_test_config() {
    local proj="${PROJECT_DIR:-.}"

    # Reset module state so a re-invocation in the same shell starts clean.
    # PREFLIGHT_UI_* vars are public contract consumed by m126 (gate) and m132
    # (RUN_SUMMARY); they must reflect this preflight run only, not stale
    # values from a previous run in the same shell session. Per m134 S7.2 they
    # must NOT be reset between iterations of run_complete_loop — only here at
    # the start of preflight, which itself runs once per pipeline invocation.
    unset PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED \
          PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE \
          PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE \
          PREFLIGHT_UI_REPORTER_PATCHED

    # Honor the m136 enable knob (declared in m136 config_defaults.sh; m131
    # uses the inline :- default so it works without m136 deployed).
    [[ "${PREFLIGHT_UI_CONFIG_AUDIT_ENABLED:-true}" == "true" ]] || return 0

    # Only run when a UI test command is configured
    [[ -z "${UI_TEST_CMD:-}" || "${UI_TEST_CMD}" == "true" ]] && return 0

    # Dispatch to framework-specific scanners
    _pf_uitest_playwright "$proj"
    _pf_uitest_cypress    "$proj"
    _pf_uitest_jest_watch "$proj"
}
```

### Goal 2 — Playwright config scanner: `_pf_uitest_playwright`

```bash
_pf_uitest_playwright() {
    local proj="$1"
    local cfg_file=""

    # Locate the config file; try common variants in order
    local candidates=(
        "${proj}/playwright.config.ts"
        "${proj}/playwright.config.js"
        "${proj}/playwright.config.mjs"
        "${proj}/playwright.config.cjs"
    )
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && cfg_file="$f" && break
    done

    [[ -z "$cfg_file" ]] && return 0  # No Playwright config; skip

    local issues_found=0

    # --- Rule PW-1: html reporter (FAIL) ------------------------------------
    # Detect: reporter: 'html' or reporter: ['html'] / ["html"].
    # Nested tuple forms such as [['html', ...]] are intentionally left to
    # m126's gate-level timeout detection; this scanner stays conservative
    # so the auto-fix only rewrites simple, reviewable shapes.
    if grep -qP "reporter\s*:\s*['\"]html['\"]|reporter\s*:\s*\[\s*['\"]html['\"]" "$cfg_file" 2>/dev/null; then
        _pf_uitest_playwright_fix_reporter "$cfg_file" "$proj"
        issues_found=1
    fi

    # --- Rule PW-2: video on (WARN) -----------------------------------------
    if grep -qP "video\s*:\s*['\"]on['\"]|video\s*:\s*['\"]retain-on-failure['\"]" "$cfg_file" 2>/dev/null; then
        _pf_record "warn" "UI Config (Playwright) — video recording" \
"playwright.config video='on' or 'retain-on-failure' produces large artifacts.
Consider: video: process.env.CI ? 'off' : 'retain-on-failure'"
        issues_found=1
    fi

    # --- Rule PW-3: webServer.reuseExistingServer: false (WARN) -------------
    if grep -qP "reuseExistingServer\s*:\s*false" "$cfg_file" 2>/dev/null; then
        _pf_record "warn" "UI Config (Playwright) — reuseExistingServer: false" \
"playwright.config webServer.reuseExistingServer=false can cause the test runner
to hang if the dev server port is already in use.
Consider: reuseExistingServer: !process.env.CI"
        issues_found=1
    fi

    [[ "$issues_found" -eq 0 ]] && _pf_record "pass" "UI Config (Playwright)" \
        "No interactive-mode config issues detected in ${cfg_file##*/}."
}
```

#### Sub-helper: `_pf_uitest_playwright_fix_reporter`

Auto-patch when auto-fix is enabled. The gating order is
`PREFLIGHT_UI_CONFIG_AUTO_FIX` (m136-specific knob) → `PREFLIGHT_AUTO_FIX`
(legacy m55 knob) → default `true`; the m136 knob takes precedence so a
user who has historically set `PREFLIGHT_AUTO_FIX=false` keeps their
explicit choice, while m136 deployments get the more specific knob.
Because the patch modifies a source file that will be committed (not a
generated or ephemeral file), it must:

1. Make a backup at `${PREFLIGHT_BAK_DIR}/<YYYYMMDD_HHMMSS>_<basename>`
   — timestamp prefix is m135's contract for lexicographic-sort retention.
2. Replace only the reporter expression, not the whole file.
3. Emit a `fail`-level finding with manual-fix instructions and the
   `PREFLIGHT_UI_*` contract triple set, when auto-fix is disabled.
4. Emit a `fixed`-level finding with the backup path, the contract
   triple, `PREFLIGHT_UI_REPORTER_PATCHED=1`, and the
   `preflight_ui_config_patch` causal event when auto-fix succeeds.
5. Call `_trim_preflight_bak_dir "$bak_dir"` (m135) defensively via
   `declare -f` so the patch path ships cleanly before m135 lands.

```bash
_pf_uitest_playwright_fix_reporter() {
    local cfg_file="$1"
    local proj="$2"
    # PREFLIGHT_BAK_DIR is declared by m136 in config_defaults.sh; the inline
    # :- default keeps m131 functional pre-m136. m135 reads the same var via
    # the same fallback in _trim_preflight_bak_dir.
    local bak_dir="${PREFLIGHT_BAK_DIR:-${proj}/.claude/preflight_bak}"
    # Filename format: <YYYYMMDD_HHMMSS>_<original-basename>
    # NOT <basename>.<timestamp>.bak — m135's _trim_preflight_bak_dir relies on
    # the timestamp prefix so plain lexicographic sort == chronological sort.
    # Format mismatch silently breaks m135's retention trim ordering.
    local bak_file="${bak_dir}/$(date +%Y%m%d_%H%M%S)_$(basename "$cfg_file")"

    # PREFLIGHT_UI_CONFIG_AUTO_FIX (m136) is the specific knob; fall back to
    # the legacy PREFLIGHT_AUTO_FIX (m55) so existing user configs still work.
    if [[ "${PREFLIGHT_UI_CONFIG_AUTO_FIX:-${PREFLIGHT_AUTO_FIX:-true}}" != "true" ]]; then
        _pf_record "fail" "UI Config (Playwright) — html reporter" \
"${cfg_file##*/} sets reporter: 'html'. Playwright's HTML reporter launches an
interactive serve-and-wait loop that is incompatible with Tekhton's timed gates.

REQUIRED MANUAL FIX:
  Change:  reporter: 'html'
  To:      reporter: process.env.CI ? 'dot' : 'html'

Or, in tekhton pipeline.conf:
  PLAYWRIGHT_HTML_OPEN=never
  CI=1  (forces non-interactive mode without changing source)

Auto-fix is disabled (PREFLIGHT_UI_CONFIG_AUTO_FIX=false, or legacy
PREFLIGHT_AUTO_FIX=false). Set either to true to allow Tekhton to patch
the config file automatically."
        # Even when not patched, the detection itself is signal m132/m133/m134
        # depend on; export the contract triple regardless of patch outcome.
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE="PW-1"
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE="${cfg_file##*/}"
        export PREFLIGHT_UI_REPORTER_PATCHED=0
        return
    fi

    # Make backup directory
    mkdir -p "$bak_dir"
    cp "$cfg_file" "$bak_file"

    # In-place sed replacement — handles only scalar and single-entry array
    # forms using either quote style.
    # Replaces:
    #   reporter: 'html'
    #   reporter: "html"
    #   reporter: ['html']
    #   reporter: ["html"]
    # with the CI-guarded scalar form. Nested tuple reporters are left
    # unchanged and fall back to m126's runtime detection path.
    if sed -i \
        "s|reporter: 'html'|reporter: process.env.CI ? 'dot' : 'html'|g;
       s|reporter: \"html\"|reporter: process.env.CI ? 'dot' : 'html'|g;
       s|reporter: \['html'\]|reporter: process.env.CI ? 'dot' : 'html'|g;
       s|reporter: \[\"html\"\]|reporter: process.env.CI ? 'dot' : 'html'|g" \
        "$cfg_file" 2>/dev/null; then
        _pf_record "fixed" "UI Config (Playwright) — html reporter" \
"Auto-patched reporter: 'html' → CI-guarded form in ${cfg_file##*/}.
Original saved to: ${bak_file##"$proj"/}
The gate will use 'dot' reporter in CI mode (no interactive server).
Review and commit the change when satisfied."
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE="PW-1"
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE="${cfg_file##*/}"
        export PREFLIGHT_UI_REPORTER_PATCHED=1
        # Emit causal event so diagnose and watchtower know this happened
        if command -v emit_event &>/dev/null; then
            emit_event "preflight_ui_config_patch" "preflight" \
                "{\"file\":\"${cfg_file##*/}\",\"rule\":\"PW-1\",\"action\":\"reporter_ci_guard\"}" 2>/dev/null || true
        fi
        # m135 contract: trim old backups to PREFLIGHT_BAK_RETAIN_COUNT.
        # Helper is defined by m135; guard with `declare -f` so m131 ships
        # cleanly before m135 lands (no-op when the helper is absent).
        if declare -f _trim_preflight_bak_dir >/dev/null 2>&1; then
            _trim_preflight_bak_dir "$bak_dir"
        fi
    else
        # sed failed — fall back to fail-level report
        _pf_record "fail" "UI Config (Playwright) — html reporter" \
"Failed to auto-patch ${cfg_file##*/}. See manual fix instructions above.
Backup (if created): ${bak_file##"$proj"/}"
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE="PW-1"
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE="${cfg_file##*/}"
        export PREFLIGHT_UI_REPORTER_PATCHED=0
    fi
}
```

### Goal 3 — Cypress config scanner: `_pf_uitest_cypress`

```bash
_pf_uitest_cypress() {
    local proj="$1"
    local cfg_file=""

    local candidates=(
        "${proj}/cypress.config.ts"
        "${proj}/cypress.config.js"
        "${proj}/cypress.config.mjs"
    )
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && cfg_file="$f" && break
    done

    [[ -z "$cfg_file" ]] && return 0

    local issues_found=0

    # --- Rule CY-1: video: true (WARN) -------------------------------------
    # Cypress records video by default. It's not blocking, but produces large
    # CI artifacts. Only warn, do not auto-patch.
    if grep -qP "video\s*:\s*true" "$cfg_file" 2>/dev/null; then
        _pf_record "warn" "UI Config (Cypress) — video: true" \
"cypress.config has video: true (default). Video recording produces large artifacts.
Consider: video: !!process.env.CI === false"
        issues_found=1
    fi

    # --- Rule CY-2: mochawesome reporter without --exit (WARN) --------------
    if grep -qP "reporter\s*:\s*['\"]mochawesome['\"]" "$cfg_file" 2>/dev/null; then
        if ! echo "${UI_TEST_CMD:-}" | grep -q -- "--exit"; then
            _pf_record "warn" "UI Config (Cypress) — mochawesome reporter" \
"cypress.config uses mochawesome reporter. Without --exit in UI_TEST_CMD, the
reporter process may not terminate.
Consider adding: --exit to UI_TEST_CMD in pipeline.conf"
            issues_found=1
        fi
    fi

    [[ "$issues_found" -eq 0 ]] && _pf_record "pass" "UI Config (Cypress)" \
        "No interactive-mode config issues detected in ${cfg_file##*/}."
}
```

### Goal 4 — Jest / Vitest watch mode scanner: `_pf_uitest_jest_watch`

```bash
_pf_uitest_jest_watch() {
    local proj="$1"
    local cfg_file=""

    # Check vitest first, then jest
    local candidates=(
        "${proj}/vitest.config.ts"
        "${proj}/vitest.config.js"
        "${proj}/jest.config.ts"
        "${proj}/jest.config.js"
        "${proj}/jest.config.mjs"
    )
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && cfg_file="$f" && break
    done

    [[ -z "$cfg_file" ]] && return 0

    local issues_found=0

    # --- Rule JV-1: watch: true / watchAll: true (FAIL) --------------------
    # Any watch mode in the config (not flag, but the config property) means
    # the test process will never terminate unless Ctrl+C'd.
    if grep -qP "^\s*(watch|watchAll)\s*:\s*true" "$cfg_file" 2>/dev/null; then
        _pf_record "fail" "UI Config (Jest/Vitest) — watch mode enabled" \
"${cfg_file##*/} has watch: true or watchAll: true. Watch mode causes the test
process to run indefinitely, which will always trigger Tekhton's UI_TEST_TIMEOUT.

REQUIRED FIX — choose one:
  a) Remove watch: true from ${cfg_file##*/}
  b) Add --run flag to TEST_CMD in pipeline.conf (Vitest: vitest run ...)
  c) Set CI=true in the environment (disables watch in most frameworks)

Tekhton does not auto-patch watch mode config. This requires deliberate choice."
        # Same downstream contract as PW-1 — m132/m133 read these env vars.
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE="JV-1"
        export PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE="${cfg_file##*/}"
        export PREFLIGHT_UI_REPORTER_PATCHED=0
        issues_found=1
    fi

    [[ "$issues_found" -eq 0 ]] && _pf_record "pass" "UI Config (Jest/Vitest)" \
        "No watch-mode config issues detected in ${cfg_file##*/}."
}
```

Note: Jest/Vitest watch mode is **not** auto-patched. Unlike the
Playwright reporter (a purely cosmetic difference between dot and html
output), disabling watch mode in the config changes the developer
experience for everyone working on the project. The failure message
shows three options; the developer must pick one deliberately.

### Goal 5 — Wire `_preflight_check_ui_test_config` into `run_preflight_checks`

Edit `lib/preflight.sh` in `run_preflight_checks` to call the new check
after `_preflight_check_tools`:

```bash
# In run_preflight_checks(), after the existing _preflight_check_tools call:
_preflight_check_ui_test_config  # M131: interactive-mode config audit
```

The check is guarded internally on `UI_TEST_CMD` being set, so it is a
no-op for projects that do not configure a UI test command.

### Goal 6 — Emit a structured preflight finding consumable by m126/m132/m133

The four `PREFLIGHT_UI_*` env vars are exported inline at every rule
firing (PW-1 fail-no-patch, PW-1 patched, PW-1 sed-failed, JV-1) — see
the `_pf_uitest_playwright_fix_reporter` and `_pf_uitest_jest_watch`
function bodies above. The export contract is consolidated here for
review:

| Var | Set when | Values |
|-----|----------|--------|
| `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED` | Any fail-class rule fires (PW-1, JV-1) | `1` (always — absent means not detected) |
| `PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE` | Same | `PW-1` or `JV-1` |
| `PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE` | Same | basename of the offending config file |
| `PREFLIGHT_UI_REPORTER_PATCHED` | PW-1 only | `1` if the source was auto-patched, `0` if not |

These four var names are public contract consumed by m132's
`_collect_preflight_ui_json`, m133's `_rule_preflight_interactive_config`,
m134's S1.x scenarios, and m126's `_ui_deterministic_env_list`. Renaming
On fail-level exits that stop preflight (PW-1 when auto-fix is disabled,
PW-1 when auto-patch fails, and JV-1), if `set_primary_cause` is
available, call:

```bash
set_primary_cause ENVIRONMENT test_infra ui_interactive_config_preflight preflight
```

Do **not** set this primary cause on `fixed` paths. A successful
auto-patch should remain observable through `PREFLIGHT_UI_*` and the
`preflight_ui.*` summary fields without contaminating an unrelated later
failure in the same run.

them post-merge silently breaks every downstream consumer.

**Wire-through to the gate normalizer.** M126's normalizer already
injects `PLAYWRIGHT_HTML_OPEN=never` for Playwright projects on every
gate run (m126 Goal 1, item 5), so first-run mitigation is in place
regardless of m131. M131's contribution to first-run determinism is to
let m126 escalate to the **hardened** env profile (`CI=1`, normally
reserved for retry only) on the first run when preflight has already
proven the project has the issue. The Files Modified table below
records the corresponding small change in `lib/gates_ui.sh`.

### Goal 7 — Tests: fixture-backed coverage for all scanners

Add `tests/test_preflight_ui_config.sh` with the following test cases:

#### T1 — `_pf_uitest_playwright` detects `reporter: 'html'` → fail or fixed

```
Fixture: minimal playwright.config.ts with reporter: 'html'
PREFLIGHT_UI_CONFIG_AUTO_FIX=false → assert _PF_FAIL incremented, message contains "REQUIRED MANUAL FIX",
                                     PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1, RULE=PW-1, REPORTER_PATCHED=0
PREFLIGHT_UI_CONFIG_AUTO_FIX=true  → assert _PF_REMEDIATED incremented, backup file created with
                                     <YYYYMMDD_HHMMSS>_<basename> format, config file no longer contains
                                     reporter: 'html', PREFLIGHT_UI_REPORTER_PATCHED=1
Legacy fallback: with PREFLIGHT_UI_CONFIG_AUTO_FIX unset and PREFLIGHT_AUTO_FIX=false →
                                     same outcome as PREFLIGHT_UI_CONFIG_AUTO_FIX=false
```

#### T2 — `_pf_uitest_playwright` does not false-positive on `reporter: 'dot'`

```
Fixture: playwright.config.ts with reporter: 'dot'
Expect:  _PF_PASS incremented, no fail/warn
```

#### T3 — `_pf_uitest_playwright` detects `video: 'on'` → warn only

```
Fixture: playwright.config.ts with use: { video: 'on' }
Expect:  _PF_WARN incremented, no fail
```

#### T4 — `_pf_uitest_playwright` detects `reuseExistingServer: false` → warn

```
Fixture: playwright.config.ts with webServer: { reuseExistingServer: false }
Expect:  _PF_WARN incremented
```

#### T5 — No playwright.config → no finding emitted

```
Fixture: project dir with no playwright.config.{ts,js,mjs,cjs}
Expect:  _PF_PASS/_PF_WARN/_PF_FAIL all zero for playwright check
```

#### T6 — `_pf_uitest_jest_watch` detects `watch: true` → fail (no auto-fix)

```
Fixture: vitest.config.ts with watch: true
Expect:  _PF_FAIL incremented; PREFLIGHT_UI_CONFIG_AUTO_FIX=true does NOT change the file
         (watch mode is never auto-patched);
         PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1, RULE=JV-1, REPORTER_PATCHED=0
```

#### T7 — `_pf_uitest_cypress` detects `video: true` → warn only

```
Fixture: cypress.config.ts with video: true
Expect:  _PF_WARN incremented
```

#### T8 — Full `PREFLIGHT_UI_*` contract triple exported when PW-1 fires

```
Fixture: playwright.config.ts with reporter: 'html'
Expect:  After running _preflight_check_ui_test_config:
           PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
           PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE=PW-1
           PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE=playwright.config.ts
           PREFLIGHT_UI_REPORTER_PATCHED=1 (auto-fix on) or =0 (auto-fix off)
```

#### T9 — `_pf_uitest_playwright` backup survives when config already CI-guarded

```
Fixture: playwright.config.ts with reporter: process.env.CI ? 'dot' : 'html'
Expect:  grep pattern does NOT match (correctly reports pass, no patch attempted)
         (validates that the grep pattern is narrow enough)
```

#### T10 — `UI_TEST_CMD` unset → `_preflight_check_ui_test_config` is a no-op

```
Fixture: playwright.config.ts with reporter: 'html', but UI_TEST_CMD=""
Expect:  All PF counters at zero; function returns 0 immediately
```

## Files Modified

| File | Change |
|------|--------|
| `lib/preflight_checks_ui.sh` | **New file.** Contains `_preflight_check_ui_test_config`, `_pf_uitest_playwright`, `_pf_uitest_playwright_fix_reporter`, `_pf_uitest_cypress`, `_pf_uitest_jest_watch`. Mirrors the `preflight_checks_env.sh` split pattern. New file (rather than appending to `preflight_checks.sh`) is mandatory: the additions are ~200 LOC and `preflight_checks.sh` is already 224 lines, so an append violates CLAUDE.md non-negotiable rule 8 (300-line ceiling). |
| `tekhton.sh` | Add `source "${TEKHTON_HOME}/lib/preflight_checks_ui.sh"` in the same neighborhood as the existing `preflight_checks.sh` / `preflight_checks_env.sh` source lines. |
| `lib/preflight.sh` | Add `_preflight_check_ui_test_config` call in `run_preflight_checks` immediately after `_preflight_check_tools`. No other change. |
| `lib/gates_ui.sh` (or `gates_ui_helpers.sh`) | In `_ui_deterministic_env_list`: when `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1`, set the hardened env profile (add `CI=1`) on the *first* gate run rather than only on retry. `PLAYWRIGHT_HTML_OPEN=never` is already on every run per m126 — only the `CI=1` escalation moves earlier. |
| `tests/test_preflight_ui_config.sh` | **New file.** Test cases T1–T10 as described in Goal 7. |
| `tests/run_tests.sh` | Register `test_preflight_ui_config.sh` in the active test list. |
| `docs/troubleshooting/preflight.md` | Add "UI Test Framework Config Audit" section documenting rules PW-1 through PW-3, CY-1, CY-2, JV-1 with remediation steps. |

**Config knobs read by m131 (declared in m136, default-true here for forward compat):**

| Var | Default in m131 | Owner / declarer |
|-----|-----------------|------------------|
| `PREFLIGHT_UI_CONFIG_AUDIT_ENABLED` | `true` (inline `${...:-true}`) | m136 declares in `config_defaults.sh` |
| `PREFLIGHT_UI_CONFIG_AUTO_FIX` | `true`, falling back to legacy `PREFLIGHT_AUTO_FIX`, then `true` | m136 declares; m55's `PREFLIGHT_AUTO_FIX` remains the legacy fallback |
| `PREFLIGHT_BAK_DIR` | `${PROJECT_DIR}/.claude/preflight_bak` | m135 declares; m131 reads via inline `${...:-...}` |

m131 deliberately does **not** add these to `lib/config_defaults.sh` —
that is m136's exclusive scope. The inline defaults make m131
deployable independently of m136.

## Implementation Notes

### Grep pattern conservatism

The grep patterns in the scanners are deliberately *not* exhaustive TypeScript
parsers. They cover the 95% case of real configs written by hand or scaffolded
by `npm init playwright`. The remaining 5% (conditional expressions, spread
configs, programmatic reporter arrays) are not false-negatives — they simply
won't be caught at preflight and will instead be caught at the gate level by
m126's timeout-signature detection. This is acceptable: preflight is a
fast-path optimisation, not a guarantee.

Each scanner function name starts with `_pf_uitest_` (not `_preflight_uitest_`)
to distinguish them from the top-level check functions while keeping them
co-located with the check dispatch in `preflight_checks.sh`.

### Auto-fix scope boundary

Only the Playwright html reporter is auto-patched. The decision matrix:

| Rule | Auto-patch? | Rationale |
|------|-------------|-----------|
| PW-1 (html reporter) | Yes | Pure behavior change: `dot` vs `html` output. No effect on what is tested. Easily reviewed. |
| PW-2 (video on) | No | Trade-off decision; developer may want video in some environments |
| PW-3 (reuseExistingServer) | No | Depends on project's port-conflict risk; developer must decide |
| CY-1 (cypress video) | No | Developer preference |
| CY-2 (mochawesome) | No | Requires `pipeline.conf` edit, not config-file edit |
| JV-1 (jest/vitest watch) | No | Changes DX for all contributors; requires deliberate decision |

### Backup directory placement

Backup files go under `PROJECT_DIR/.claude/preflight_bak/` — inside the
`.claude/` directory that Tekhton already owns. This keeps backups
adjacent to other Tekhton artifacts, avoids polluting the project root,
and is already `.gitignore`'d by Tekhton's `init` command.

### Interaction with m126 first-run determinism

Without m131: m126 runs the gate, waits for timeout, detects the
interactive-reporter signature, then applies the non-interactive env
profile for the retry. Cost: one full `UI_TEST_TIMEOUT` burn.

With m131: preflight sets `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1`
*before* any gate run. M126's `_ui_deterministic_env_list` reads the
flag and includes `PLAYWRIGHT_HTML_OPEN=never` and `CI=1` in the
*first* run's env, not just the retry. Cost: zero timeout burns.

The two milestones are independent: m126 works without m131 (reactive
mode), and m131 produces correct preflight findings whether or not m126
is deployed. Together they eliminate the timeout entirely on first run.

## Acceptance Criteria

- [ ] `lib/preflight_checks_ui.sh` exists, sourced from `tekhton.sh`, and is ≤ 300 lines (CLAUDE.md non-negotiable rule 8).
- [ ] `_preflight_check_ui_test_config` is called by `run_preflight_checks` when `UI_TEST_CMD` is set, immediately after `_preflight_check_tools`.
- [ ] `_preflight_check_ui_test_config` is a no-op when `UI_TEST_CMD` is empty, unset, or the no-op default `true`.
- [ ] `_preflight_check_ui_test_config` is a no-op when `PREFLIGHT_UI_CONFIG_AUDIT_ENABLED=false`.
- [ ] `_preflight_check_ui_test_config` `unset`s the four `PREFLIGHT_UI_*` contract vars at function start so a same-shell re-invocation produces a clean state.
- [ ] PW-1 (Playwright html reporter) produces a `fail` record when `PREFLIGHT_UI_CONFIG_AUTO_FIX=false` (or legacy `PREFLIGHT_AUTO_FIX=false`).
- [ ] PW-1 with auto-fix enabled produces a `fixed` record, creates a backup file named `<YYYYMMDD_HHMMSS>_<basename>` in `${PREFLIGHT_BAK_DIR:-.claude/preflight_bak}/`, and leaves the config file without `reporter: 'html'`.
- [ ] PW-1 does not match `reporter: process.env.CI ? 'dot' : 'html'` (already-guarded form).
- [ ] PW-2 and PW-3 produce `warn` records only; no auto-patch.
- [ ] JV-1 (watch: true) produces a `fail` record and is never auto-patched even when auto-fix is enabled.
- [ ] When PW-1 or JV-1 fires, all four contract vars are exported: `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1`, `PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE` (= `PW-1` or `JV-1`), `PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE` (basename), and `PREFLIGHT_UI_REPORTER_PATCHED` (`1` only when sed succeeded; `0` otherwise).
- [ ] When no fail-class rule fires, none of the four `PREFLIGHT_UI_*` contract vars is set in the environment seen by downstream consumers.
- [ ] PW-1 auto-patch path emits the `preflight_ui_config_patch` causal event with rule, file, and action fields.
- [ ] PW-1 auto-patch path calls `_trim_preflight_bak_dir "$bak_dir"` if the helper is defined (m135-shipped); the call is a no-op when m135 has not yet shipped.
- [ ] All 10 test cases in `test_preflight_ui_config.sh` pass; `tests/run_tests.sh` includes the new test file.
- [ ] M126's `_ui_deterministic_env_list` adds `CI=1` to the *first* gate run env (not only on retry) when `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1`. `PLAYWRIGHT_HTML_OPEN=never` is unchanged from m126's existing every-run application.
- [ ] `shellcheck` clean for `lib/preflight_checks_ui.sh`, `lib/preflight.sh`, `lib/gates_ui.sh` (or its helpers file), and `tests/test_preflight_ui_config.sh`.
- [ ] `docs/troubleshooting/preflight.md` updated with UI config audit section covering PW-1 through PW-3, CY-1, CY-2, JV-1.

## Watch For

- **The four `PREFLIGHT_UI_*` env vars are public contract.** m132's
  `_collect_preflight_ui_json`, m133's `_rule_preflight_interactive_config`,
  m134's S1.x scenarios, and m126's `_ui_deterministic_env_list` all
  read these names byte-for-byte. Renaming, splitting, or
  re-prefixing any of `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED`,
  `PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE`,
  `PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE`, or
  `PREFLIGHT_UI_REPORTER_PATCHED` silently breaks every downstream
  consumer with no shellcheck signal. Treat these as the public
  interface to the resilience arc finalize layer.
- **Reset the contract vars at preflight start, NOT per iteration.**
  m134 S7.2 documents this contract explicitly: `PREFLIGHT_*` vars are
  set by preflight which runs once per pipeline invocation. They must
  persist across `run_complete_loop` iterations so m126/m130 see the
  detection signal on every gate retry. Reset only at the top of
  `_preflight_check_ui_test_config` (same-shell re-invocation safety),
  never per iteration.
- **Backup file format is `<timestamp>_<filename>`, not `<filename>.<timestamp>.bak`.**
  m135's `_trim_preflight_bak_dir` relies on `find | sort | head` —
  the YYYYMMDD_HHMMSS prefix makes lexicographic sort chronological.
  Any other format silently breaks retention ordering: oldest files
  may be retained while newest are trimmed.
- **Read `PREFLIGHT_BAK_DIR` via inline `${...:-...}`, do not declare in
  `config_defaults.sh`.** m136 is the exclusive declarer of all three
  m131 config knobs (`PREFLIGHT_UI_CONFIG_AUDIT_ENABLED`,
  `PREFLIGHT_UI_CONFIG_AUTO_FIX`, `PREFLIGHT_BAK_RETAIN_COUNT`/
  `PREFLIGHT_BAK_DIR`). m131 reading them inline keeps m136 purely
  additive; declaring them in m131 forces m136 to do migration work it
  was designed to avoid.
- **Auto-fix gating order matters.** Use
  `PREFLIGHT_UI_CONFIG_AUTO_FIX:-${PREFLIGHT_AUTO_FIX:-true}` — the
  m136-specific knob takes precedence, the legacy m55 knob is the
  fallback, and `true` is the ultimate default. Reversing this order
  means a user who has set `PREFLIGHT_AUTO_FIX=false` historically
  still gets the auto-patch behavior they explicitly disabled.
- **Grep patterns are deliberately conservative.** PW-1's regex
  matches the common simple forms (`reporter: 'html'`, `reporter: ['html']`,
  `reporter: ["html"]`) but does **not** match nested tuple arrays,
  conditional, programmatic, or spread-config forms. Don't try to widen
  them — false-positive auto-patches on programmatic configs would
  corrupt files that m131 then can't undo. The remaining gap is caught
  by m126 at the gate level via timeout-signature detection. Preflight
  is a fast-path optimisation, not a guarantee.
- **`_pf_uitest_playwright_fix_reporter` calls `_trim_preflight_bak_dir`
  *defensively*.** Wrap the call in `declare -f _trim_preflight_bak_dir`
  so m131 ships cleanly when m135 has not yet landed. Do not source
  `preflight_checks.sh` from the new file just to pull in m135's helper —
  the shell-builtin `declare` check is the simplest decoupling.
- **Cypress and Jest/Vitest scanners do not auto-patch.** Only PW-1 is
  pure-cosmetic enough to safely rewrite. CY-1, CY-2, PW-2, PW-3
  represent trade-offs; JV-1 changes the developer experience for
  every contributor. The decision matrix in "Auto-fix scope boundary"
  below is normative — do not extend auto-patch to other rules in
  this milestone.
- **JV-1 is scoped to UI projects via `UI_TEST_CMD`.** Watch mode is
  a footgun for any project using Jest/Vitest, including pure
  backend ones using `TEST_CMD`. The current scope intentionally
  bounds detection to `UI_TEST_CMD` users to keep the milestone
  reviewable; broadening to `TEST_CMD` is left to a future milestone
  (the same scanner can be reused — keep `_pf_uitest_jest_watch`
  parameter-light to make that future call easy).
- **300-line ceiling on the new file.** The combined LOC of all five
  scanner functions plus the dispatcher is ~200 lines. Stay below
  300 in `lib/preflight_checks_ui.sh`. If wording the inline
  remediation messages pushes the file over, extract the message
  strings to functions or hereldocs — do not split into a third
  preflight file.

## Seeds Forward

This milestone produces three artifact classes consumed by every
downstream resilience-arc milestone. The contracts pinned here must
remain stable through m138.

- **m132 — RUN_SUMMARY Causal Fidelity Enrichment.** Hard contract:
  `_collect_preflight_ui_json` reads exactly these four env vars
  (`PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED`,
  `PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE`,
  `PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE`,
  `PREFLIGHT_UI_REPORTER_PATCHED`) plus the preflight `_PF_FAIL` /
  `_PF_WARN` counters from `lib/preflight.sh`. m132 emits a
  `preflight_ui` top-level key in `RUN_SUMMARY.json`. Renaming any
  of these four vars or breaking the `0/1` value convention silently
  breaks RUN_SUMMARY emission. → Keep var names and value semantics
  frozen.

- **m133 — Diagnose Rule Enrichment.** `_rule_preflight_interactive_config`
  reads `PREFLIGHT_REPORT.md` looking for the literal heading
  `### ✗ UI Config (Playwright) — html reporter`. The exact unicode
  cross + space + heading text is generated by `_pf_record "fail" "UI Config (Playwright) — html reporter" ...`
  — the prefix comes from `lib/preflight.sh` `_pf_record` (not under
  m131's control), but the **heading text** "UI Config (Playwright) — html reporter"
  is m131's wording. m133 will grep for it byte-for-byte. → Do not
  reword the `_pf_record` name strings without coordinating with m133.

- **m134 — Resilience Arc Integration Test Suite.** Scenario group 1
  (S1.x) drives `_preflight_check_ui_test_config` directly with fixture
  configs and asserts every `PREFLIGHT_UI_*` env-var transition: detect
  (S1.1), detect-and-patch (S1.2), no-detection (S1.3). S7.2 asserts
  the per-iteration non-reset semantic documented above. The fixture
  shape (one playwright.config.ts per scenario) is byte-for-byte the
  same as `tests/test_preflight_ui_config.sh` — m134 reuses them. →
  Keep T1–T10 fixtures stable and parseable; m134's helpers will copy
  them.

- **m135 — Resilience Arc Artifact Lifecycle.** Adds
  `_trim_preflight_bak_dir` to `lib/preflight_checks.sh` and `.gitignore`
  entries for `.claude/preflight_bak/`. m131's
  `_pf_uitest_playwright_fix_reporter` calls `_trim_preflight_bak_dir`
  immediately after `PREFLIGHT_UI_REPORTER_PATCHED=1` (guarded by
  `declare -f` for backwards compat). The backup filename format
  `<YYYYMMDD_HHMMSS>_<basename>` is m135's contract; deviating produces
  silent retention ordering bugs. → Keep filename format frozen.

- **m136 — Resilience Arc Config Defaults & Validation.** Declares
  `PREFLIGHT_UI_CONFIG_AUDIT_ENABLED:=true`,
  `PREFLIGHT_UI_CONFIG_AUTO_FIX:=true`, and `PREFLIGHT_BAK_RETAIN_COUNT:=5`
  in `config_defaults.sh`, plus `--validate-config` checks. m131 reads
  all three via inline `${...:-...}` defaults so m136 is purely
  additive. → m131 must NOT add these to `config_defaults.sh` itself;
  leave declaration to m136 to keep the layering clean.

- **m137 — V3.2 Migration Script.** Surfaces the new
  `PREFLIGHT_UI_CONFIG_AUTO_FIX` knob in user-facing migration output so
  existing projects know it exists. The exact knob name (with
  `_UI_CONFIG_` infix, not `_UI_` directly) is what m137 substring-matches
  for. → Do not rename to `PREFLIGHT_UI_AUTO_FIX` or similar; keep the
  `_CONFIG_` infix.

- **m138 — CI Environment Auto-Detection.** Lists m131 in its scope
  table as a feeder of preflight signal. m138 may layer additional
  CI-detection logic on top of `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED`
  to short-circuit the auto-patch when the project is already in CI
  (the patch isn't visible to a developer in CI mode, so the source
  rewrite is wasted churn). m131 itself does not need to do this; the
  hook for m138 is simply the existing `PREFLIGHT_UI_CONFIG_AUTO_FIX`
  knob. → Keep auto-fix gating idempotent and side-effect-free when
  the source already has the CI-guarded form (T9 already verifies this).

- **Future: cypress / jest auto-patch.** This milestone caps auto-fix
  at PW-1 (Playwright html reporter) per the decision matrix. Future
  milestones may extend auto-patch to CY-1 (cypress video) or JV-1
  (jest/vitest watch) once the trade-off cost is well-understood. The
  pattern established here — backup, sed-based replacement,
  defensive `_trim_preflight_bak_dir` call, env-var triple export —
  is reusable. → Keep `_pf_uitest_playwright_fix_reporter` shaped
  so a future `_pf_uitest_cypress_fix_video` is a copy-paste with
  message swaps, not a redesign.
