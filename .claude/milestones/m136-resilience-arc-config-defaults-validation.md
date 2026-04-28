# M136 - Resilience Arc Config Defaults & Validation Hardening

<!-- milestone-meta
id: "136"
status: "done"
-->

## Overview

Resilience arc milestones m126, m128-m131, and m135 introduced thirteen
operator-facing config variables that control arc behaviour. None of these variables
are declared in `lib/config_defaults.sh` today, which means:

1. They cannot be overridden via `pipeline.conf` the normal way — a
   developer who adds `BUILD_FIX_MAX_ATTEMPTS=4` to their config file
   will find the line silently ignored because `config_defaults.sh` never
   reads it and the arc functions use hard-coded or inline fallbacks.

2. They are invisible to `tekhton --validate-config` — a mis-typed
   `BUILD_FIX_MAX_ATTEMPTS=abc` passes through without warning.

3. They are not documented in `templates/pipeline.conf.example` — a
   developer reading the example config has no idea these levers exist.

The missing variables are:

| Variable | Introduced by | Default | Description |
|----------|---------------|---------|-------------|
| `BUILD_FIX_ENABLED` | m128 | `true` | Toggle build-fix continuation loop entirely |
| `BUILD_FIX_MAX_ATTEMPTS` | m128 | `3` | Max build-fix continuation attempts per pipeline cycle |
| `BUILD_FIX_BASE_TURN_DIVISOR` | m128 | `3` | Baseline divisor used to derive attempt-1 build-fix budget |
| `BUILD_FIX_MAX_TURN_MULTIPLIER` | m128 | `1.0` | Cap multiplier applied against `EFFECTIVE_CODER_MAX_TURNS` |
| `BUILD_FIX_REQUIRE_PROGRESS` | m128 | `true` | Stop continuation when repeated attempts show no measurable progress |
| `BUILD_FIX_TOTAL_TURN_CAP` | m128 | `120` | Cumulative turn cap across the whole build-fix loop |
| `UI_GATE_ENV_RETRY_ENABLED` | m126 | `true` | Enable non-interactive env retry on gate timeout |
| `UI_GATE_ENV_RETRY_TIMEOUT_FACTOR` | m126 | `0.5` | Fraction of original `UI_TEST_TIMEOUT` for retry run |
| `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` | m126 | `0` | Override: force non-interactive env on every gate run |
| `PREFLIGHT_UI_CONFIG_AUDIT_ENABLED` | m131 | `true` | Enable UI config file scan (m131 preflight check) |
| `PREFLIGHT_BAK_RETAIN_COUNT` | m131 / m135 | `5` | Max backup files to keep in `preflight_bak/` |
| `PREFLIGHT_UI_CONFIG_AUTO_FIX` | m131 | `true` | Auto-patch interactive reporter config on detection |
| `BUILD_FIX_CLASSIFICATION_REQUIRED` | m130 | `true` | Require code_dominant classification before build-fix |

> **Note — `LAST_FAILURE_CONTEXT_SCHEMA_VERSION` is intentionally excluded.**
> Schema version is an implementation contract between the writer
> (`lib/diagnose_output.sh`) and the readers (m130, m132, m133). Giving
> operators a `pipeline.conf` knob to downgrade it to `1` would silently
> disable m129–m133's causal fidelity features. The writer always emits
> v2 and retains the v1 flat fields (`category`, `subcategory`) at the
> top level for backward compatibility with any external tooling.

M136 registers all thirteen variables in `config_defaults.sh`,
adds six new `--validate-config` checks in `validate_config.sh`,
and documents them in a new subsection of `pipeline.conf.example`.

No changes to arc runtime logic. Config-layer only.

## Design

### Goal 1 — Declare all thirteen vars in `lib/config_defaults.sh`

Add a new section block immediately after the `# --- Pre-flight environment
validation defaults (Milestone 55) ---` block. Follow
the exact `:=` idiom and comment format used throughout the file.

```bash
# --- Resilience arc defaults (m126–m131: UI gate, build-fix, failure context) ---

# UI gate deterministic execution (m126)
: "${UI_GATE_ENV_RETRY_ENABLED:=true}"         # Retry gate with non-interactive env on timeout
: "${UI_GATE_ENV_RETRY_TIMEOUT_FACTOR:=0.5}"   # Retry timeout = original * this factor (0.1–1.0)
: "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:=0}" # 0=auto 1=always force non-interactive gate env

# Build-fix continuation loop (m128)
: "${BUILD_FIX_ENABLED:=true}"                 # Enable build-fix continuation loop
: "${BUILD_FIX_MAX_ATTEMPTS:=3}"               # Max fix attempts per pipeline cycle
: "${BUILD_FIX_BASE_TURN_DIVISOR:=3}"          # Attempt-1 budget = EFFECTIVE_CODER_MAX_TURNS / divisor
: "${BUILD_FIX_MAX_TURN_MULTIPLIER:=1.0}"      # Upper cap multiplier against EFFECTIVE_CODER_MAX_TURNS
: "${BUILD_FIX_REQUIRE_PROGRESS:=true}"        # Require measurable progress for continuation
: "${BUILD_FIX_TOTAL_TURN_CAP:=120}"           # Cumulative turn cap across all attempts

# Causal recovery routing (m130)
: "${BUILD_FIX_CLASSIFICATION_REQUIRED:=true}" # Require code_dominant classification for build-fix loop

# Preflight UI config audit (m131)
: "${PREFLIGHT_UI_CONFIG_AUDIT_ENABLED:=true}" # Scan test framework configs for interactive-mode settings
: "${PREFLIGHT_UI_CONFIG_AUTO_FIX:=true}"      # Auto-patch detected interactive config (e.g. reporter: 'html')
: "${PREFLIGHT_BAK_RETAIN_COUNT:=5}"           # Max backups to keep in .claude/preflight_bak/
```

**Build-fix default-shape note:** These defaults deliberately mirror the
M128 runtime contract rather than introducing a second operator-facing
surface. `BUILD_FIX_BASE_TURN_DIVISOR`, `BUILD_FIX_MAX_TURN_MULTIPLIER`,
`BUILD_FIX_REQUIRE_PROGRESS`, and `BUILD_FIX_TOTAL_TURN_CAP` are the
same names M128 uses in its loop design, so later milestones and
operator docs do not drift.

**Why `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` defaults to `0` not `false`:**
The m126 implementation reads it with `[[ "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:-0}" == "1" ]]`
— treating it as a binary flag (0/1 not true/false). The default matches
that convention for consistency.

### Goal 2 — Add validation checks in `lib/validate_config.sh`

Add a new helper function `_vc_check_resilience_arc` called at the end
of `validate_config()`, between Check 12 and the summary line. The
function runs six checks and increments `passes`/`warnings`/`errors`
via the standard `_vc_pass`/`_vc_warn`/`_vc_fail` helpers.

The integration in `validate_config()`:

```bash
    # Check 12: No stale PIPELINE_STATE.md
    ...

    # Check 13: Resilience arc config sanity (m136)
    _vc_check_resilience_arc

    echo ""
    echo "${passes} passed, ${warnings} warnings, ${errors} errors"
```

Follow the existing helper pattern in this file (`_vc_check_role_files`,
`_vc_check_manifest`, `_vc_check_models`): mutate `passes`/`warnings`/
`errors` directly via shell dynamic scope. Do not introduce namerefs or
`declare -g` here; the current file does not need them.

```bash
# _vc_check_resilience_arc
# Validates resilience arc config values. Mutates validate_config()
# counters directly (same style as existing helper checks).
_vc_check_resilience_arc() {
    echo ""
    echo "  [Resilience Arc]"

    # Check A: BUILD_FIX_MAX_ATTEMPTS must be a positive integer (1–20)
    local bfa="${BUILD_FIX_MAX_ATTEMPTS:-3}"
    if [[ "$bfa" =~ ^[0-9]+$ ]] && (( bfa >= 1 && bfa <= 20 )); then
        _vc_pass "BUILD_FIX_MAX_ATTEMPTS=${bfa} (valid)"
        passes=$((passes + 1))
    else
        _vc_fail "BUILD_FIX_MAX_ATTEMPTS=${bfa} — must be integer 1–20"
        errors=$((errors + 1))
    fi

    # Check B: BUILD_FIX_BASE_TURN_DIVISOR must be a positive integer
    local bfd="${BUILD_FIX_BASE_TURN_DIVISOR:-3}"
    if [[ "$bfd" =~ ^[0-9]+$ ]] && (( bfd >= 1 && bfd <= 20 )); then
        _vc_pass "BUILD_FIX_BASE_TURN_DIVISOR=${bfd} (valid)"
        passes=$((passes + 1))
    else
        _vc_fail "BUILD_FIX_BASE_TURN_DIVISOR=${bfd} — must be integer 1–20"
        errors=$((errors + 1))
    fi

    # Check C: UI_GATE_ENV_RETRY_TIMEOUT_FACTOR must be a decimal 0.1–1.0
    local rtf="${UI_GATE_ENV_RETRY_TIMEOUT_FACTOR:-0.5}"
    # bash can't do float comparison directly — use awk for this one check
    local rtf_ok
    rtf_ok=$(awk -v v="$rtf" 'BEGIN { print (v+0 >= 0.1 && v+0 <= 1.0) ? "ok" : "fail" }')
    if [[ "$rtf_ok" == "ok" ]]; then
        _vc_pass "UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=${rtf} (valid, 0.1–1.0)"
        passes=$((passes + 1))
    else
        _vc_warn "UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=${rtf} — expected decimal 0.1–1.0; using 0.5"
        warnings=$((warnings + 1))
    fi

    # Check D: TEKHTON_UI_GATE_FORCE_NONINTERACTIVE must be 0 or 1
    local fni="${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:-0}"
    if [[ "$fni" == "0" || "$fni" == "1" ]]; then
        _vc_pass "TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=${fni} (valid)"
        passes=$((passes + 1))
    else
        _vc_warn "TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=${fni} — expected 0 or 1"
        warnings=$((warnings + 1))
    fi

    # Check E: PREFLIGHT_BAK_RETAIN_COUNT must be non-negative integer
    local pbr="${PREFLIGHT_BAK_RETAIN_COUNT:-5}"
    if [[ "$pbr" =~ ^[0-9]+$ ]]; then
        _vc_pass "PREFLIGHT_BAK_RETAIN_COUNT=${pbr} (valid)"
        passes=$((passes + 1))
    else
        _vc_fail "PREFLIGHT_BAK_RETAIN_COUNT=${pbr} — must be non-negative integer (0 = keep all)"
        errors=$((errors + 1))
    fi

    # Check F: Warn when UI_TEST_CMD is set but UI_GATE_ENV_RETRY_ENABLED is false
    if [[ -n "${UI_TEST_CMD:-}" ]] && [[ "${UI_GATE_ENV_RETRY_ENABLED:-true}" == "false" ]]; then
        _vc_warn "UI_GATE_ENV_RETRY_ENABLED=false with UI_TEST_CMD set — interactive reporter timeouts will not be auto-retried"
        warnings=$((warnings + 1))
    else
        _vc_pass "UI gate retry configuration consistent"
        passes=$((passes + 1))
    fi
}
```

**Why `awk` for float comparison in Check C:** Bash cannot compare
floating-point natively. `awk` is universally available (POSIX), is
already used elsewhere in the codebase (e.g. `gates_ui.sh`), and avoids
the `bc` dependency which is not guaranteed on all CI images.

**Why Check F is `warn` not `fail`:** Turning off the retry is a valid
project choice (e.g., for performance test suites that always take the
full `UI_TEST_TIMEOUT`). The warning is informational.

### Goal 3 — Document arc vars in `templates/pipeline.conf.example`

Add a new commented section immediately after the existing `# UI_TEST_TIMEOUT=120`
line inside the `# --- UI Testing (Milestone 28) ---` block. In today's template,
that block lives in Section 5 (Features), so use the `UI_TEST_TIMEOUT` line as
the stable insertion anchor instead of section-number headings.

```conf
# ─── Resilience arc (m126–m131): UI gate robustness & build-fix recovery ─────

# UI gate non-interactive enforcement
# Enable auto-retry with non-interactive env when gate times out (interactive reporter detection).
# UI_GATE_ENV_RETRY_ENABLED=true

# Fraction of UI_TEST_TIMEOUT to allow for the non-interactive retry run (0.1–1.0).
# Lower values fail faster when the fix didn't work; higher values allow longer retry.
# UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=0.5

# Force non-interactive env on every UI gate run (0=auto, 1=always).
# Set to 1 in CI environments that never want the interactive reporter.
# TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0

# Build-fix continuation loop
# Enable the build-fix continuation loop (attempts to fix build errors automatically).
# BUILD_FIX_ENABLED=true

# Maximum number of build-fix attempts per pipeline cycle.
# BUILD_FIX_MAX_ATTEMPTS=3

# Attempt-1 budget divisor. M128 computes the base budget as
# EFFECTIVE_CODER_MAX_TURNS / BUILD_FIX_BASE_TURN_DIVISOR.
# BUILD_FIX_BASE_TURN_DIVISOR=3

# Cap the adaptive schedule at EFFECTIVE_CODER_MAX_TURNS * multiplier.
# BUILD_FIX_MAX_TURN_MULTIPLIER=1.0

# Require measurable progress before continuing to later build-fix attempts.
# BUILD_FIX_REQUIRE_PROGRESS=true

# Cumulative cap across the whole build-fix loop.
# BUILD_FIX_TOTAL_TURN_CAP=120

# Require log classification to be code_dominant before allowing build-fix loop.
# Set to false to attempt build-fix even on mixed/uncertain logs (not recommended).
# BUILD_FIX_CLASSIFICATION_REQUIRED=true

# Preflight UI config audit
# Scan test framework config files (playwright.config.ts, etc.) for interactive-mode settings.
# PREFLIGHT_UI_CONFIG_AUDIT_ENABLED=true

# Auto-patch detected interactive reporter config (e.g. reporter: 'html' → CI-guarded form).
# PREFLIGHT_UI_CONFIG_AUTO_FIX=true

# Maximum number of backup files to keep in .claude/preflight_bak/ (0 = keep all).
# PREFLIGHT_BAK_RETAIN_COUNT=5
```

Placement: find `# UI_TEST_TIMEOUT=120` in `pipeline.conf.example` and
insert the new block immediately after it.

### Goal 4 — Reuse existing clamp infrastructure for numeric arc vars

`config_defaults.sh` already applies hard upper bounds at the bottom of
the file via `_clamp_config_value` and `_clamp_config_float`. Extend that
existing clamp table for resilience-arc numeric knobs; do not add a new
special-purpose clamp function.

```bash
# near the existing "# --- Clamp values to hard upper bounds ---" section
_clamp_config_value BUILD_FIX_MAX_ATTEMPTS 20
_clamp_config_value BUILD_FIX_BASE_TURN_DIVISOR 20
_clamp_config_float BUILD_FIX_MAX_TURN_MULTIPLIER 1.0 5.0
_clamp_config_value BUILD_FIX_TOTAL_TURN_CAP 1000
_clamp_config_float UI_GATE_ENV_RETRY_TIMEOUT_FACTOR 0.1 1.0
_clamp_config_value PREFLIGHT_BAK_RETAIN_COUNT 1000
```

**Why this change:** the project already has a single clamp mechanism and
centralized clamp block. Reusing it keeps behavior consistent and avoids
introducing new side-effect ordering concerns in `config_defaults.sh`.

### Goal 5 — Extend test coverage in `tests/test_validate_config.sh`

Add six new tests covering the new `_vc_check_resilience_arc` checks.
Keep tests in `tests/test_validate_config.sh` focused on validator output
and return codes; clamp behavior belongs to config-defaults/unit coverage.

```bash
# Test: BUILD_FIX_MAX_ATTEMPTS=abc → error
echo "Test: BUILD_FIX_MAX_ATTEMPTS non-integer → validate error"
BUILD_FIX_MAX_ATTEMPTS="abc"
output=$(validate_config 2>&1)
if echo "$output" | grep -q "BUILD_FIX_MAX_ATTEMPTS=abc — must be integer"; then
    pass "Non-integer BUILD_FIX_MAX_ATTEMPTS triggers error"
else
    fail "Expected validation error for BUILD_FIX_MAX_ATTEMPTS=abc: $output"
fi
unset BUILD_FIX_MAX_ATTEMPTS

# Test: BUILD_FIX_BASE_TURN_DIVISOR=0 → error
echo "Test: BUILD_FIX_BASE_TURN_DIVISOR=0 → validate error"
BUILD_FIX_BASE_TURN_DIVISOR="0"
output=$(validate_config 2>&1)
if echo "$output" | grep -q "BUILD_FIX_BASE_TURN_DIVISOR=0"; then
    pass "Invalid BUILD_FIX_BASE_TURN_DIVISOR triggers error"
else
    fail "Expected validation error for BUILD_FIX_BASE_TURN_DIVISOR=0: $output"
fi
unset BUILD_FIX_BASE_TURN_DIVISOR

# Test: UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=2.5 → warning
echo "Test: UI_GATE_ENV_RETRY_TIMEOUT_FACTOR out of range → warning"
UI_GATE_ENV_RETRY_TIMEOUT_FACTOR="2.5"
output=$(validate_config 2>&1)
if echo "$output" | grep -qi "UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=2.5"; then
    pass "Out-of-range timeout factor triggers warning"
else
    fail "Expected warning for factor=2.5: $output"
fi
unset UI_GATE_ENV_RETRY_TIMEOUT_FACTOR

# Test: TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=yes → warning
echo "Test: TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=yes → warning"
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE="yes"
output=$(validate_config 2>&1)
if echo "$output" | grep -qi "TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=yes"; then
    pass "Invalid value triggers warning"
else
    fail "Expected warning for FORCE_NONINTERACTIVE=yes: $output"
fi
unset TEKHTON_UI_GATE_FORCE_NONINTERACTIVE

# Test: UI_TEST_CMD set + UI_GATE_ENV_RETRY_ENABLED=false → warning
echo "Test: UI_TEST_CMD set + retry disabled → warning"
UI_TEST_CMD="npx playwright test"
UI_GATE_ENV_RETRY_ENABLED="false"
output=$(validate_config 2>&1)
if echo "$output" | grep -qi "interactive reporter timeouts will not be auto-retried"; then
    pass "Disabled retry with UI_TEST_CMD triggers warning"
else
    fail "Expected retry-disabled warning: $output"
fi
unset UI_TEST_CMD UI_GATE_ENV_RETRY_ENABLED

# Test: PREFLIGHT_BAK_RETAIN_COUNT=abc → error
echo "Test: PREFLIGHT_BAK_RETAIN_COUNT non-integer → validate error"
PREFLIGHT_BAK_RETAIN_COUNT="abc"
output=$(validate_config 2>&1)
if echo "$output" | grep -q "PREFLIGHT_BAK_RETAIN_COUNT=abc"; then
    pass "Non-integer PREFLIGHT_BAK_RETAIN_COUNT triggers error"
else
    fail "Expected validation error for PREFLIGHT_BAK_RETAIN_COUNT=abc: $output"
fi
unset PREFLIGHT_BAK_RETAIN_COUNT

# Test: all defaults → arc checks pass
echo "Test: All arc defaults → arc checks pass"
unset BUILD_FIX_MAX_ATTEMPTS BUILD_FIX_BASE_TURN_DIVISOR \
      UI_GATE_ENV_RETRY_TIMEOUT_FACTOR TEKHTON_UI_GATE_FORCE_NONINTERACTIVE \
      PREFLIGHT_BAK_RETAIN_COUNT UI_GATE_ENV_RETRY_ENABLED UI_TEST_CMD
source "${TEKHTON_HOME}/lib/config_defaults.sh"  # re-apply defaults
output=$(validate_config 2>&1)
if echo "$output" | grep -q "\[Resilience Arc\]" && \
   echo "$output" | grep -q "0 errors"; then
    pass "Arc defaults produce passing checks"
else
    fail "Expected arc default checks to pass cleanly: $output"
fi
```

## Files Modified

| File | Change |
|------|--------|
| `lib/config_defaults.sh` | New section block with 13 `:=` declarations; add arc numeric keys to existing hard-clamp table. |
| `lib/validate_config.sh` | New `_vc_check_resilience_arc` function; call it as "Check 13" in `validate_config()`. |
| `templates/pipeline.conf.example` | New commented arc section after `UI_TEST_TIMEOUT=120` line (13 commented keys with descriptions). |
| `tests/test_validate_config.sh` | Six new test cases for arc config validation behavior. |

No changes to runtime arc logic (m126–m135 code paths unchanged).

## Watch For

- Keep `LAST_FAILURE_CONTEXT_SCHEMA_VERSION` out of `config_defaults.sh` even though migration docs may show it as a commented key for visibility. It is a schema contract, not a user tuning knob.
- In `lib/validate_config.sh`, do not pass counters as parameters or use namerefs; follow the current helper style that mutates `passes`/`warnings`/`errors` from function scope.
- `templates/pipeline.conf.example` layout evolves over time; anchor insertion by the literal `# UI_TEST_TIMEOUT=120` line, not by section-number comments.
- Avoid introducing new clamp helper functions unless absolutely required. Extending the existing clamp table is lower risk and easier to review.
- Keep check severity stable: invalid integers should fail; compatibility and operator-intent mismatches (like retry disabled with `UI_TEST_CMD`) should warn.

## Seeds Forward

- **m137 (V3.2 migration)**: migration script should append the same 13 user-facing arc keys in `pipeline.conf` comments/active defaults so pre-arc projects become discoverable and consistent after migration.
- **m138 (runtime CI env auto-detect)**: relies on `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` being formally declared and validated here.
- **Future arc observability milestone**: the new `[Resilience Arc]` validation output block can be reused for dashboard/health summarization without additional parsing formats.
- **Future config-doc sync automation**: this milestone establishes a single canonical list of arc knobs across defaults, validator, and template, which is a prerequisite for drift-check tooling.

## Acceptance Criteria

- [ ] All 13 arc variables declared in `config_defaults.sh` with `:=` and sensible defaults.
- [ ] `BUILD_FIX_BASE_TURN_DIVISOR`, `BUILD_FIX_MAX_TURN_MULTIPLIER`, `BUILD_FIX_REQUIRE_PROGRESS`, and `BUILD_FIX_TOTAL_TURN_CAP` are declared with the same names M128 uses in its runtime loop design.
- [ ] `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` defaults to `0` (not `false`) to match its binary flag convention.
- [ ] Arc numeric keys are added to the existing hard-clamp table (`_clamp_config_value` / `_clamp_config_float`) with no new clamp helper function.
- [ ] `validate_config` runs Check 13 (`_vc_check_resilience_arc`) and its results appear in the pass/warn/error summary totals.
- [ ] `BUILD_FIX_MAX_ATTEMPTS=abc` produces a `fail` line in `validate_config` output.
- [ ] `UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=2.5` produces a `warn` line in `validate_config` output.
- [ ] `UI_TEST_CMD` set + `UI_GATE_ENV_RETRY_ENABLED=false` produces a `warn` line.
- [ ] All arc vars appear in the `pipeline.conf.example` commented section with descriptions.
- [ ] Milestone includes explicit `Watch For` and `Seeds Forward` sections that call out m137/m138 integration points.
- [ ] `shellcheck` clean for all modified files.
- [ ] Six new test cases in `tests/test_validate_config.sh` pass.
- [ ] Sourcing `config_defaults.sh` twice (idempotent source) does not change any arc var value.
