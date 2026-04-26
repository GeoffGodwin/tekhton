# M136 - Resilience Arc Config Defaults & Validation Hardening

<!-- milestone-meta
id: "136"
status: "pending"
-->

## Overview

The eight resilience arc milestones (m126–m133) introduced eleven new
config variables that control their behaviour. None of these variables
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
| `BUILD_FIX_MAX_ATTEMPTS` | m128 | `3` | Max build-fix continuation attempts per pipeline cycle |
| `BUILD_FIX_MAX_TURNS_PER_ATTEMPT` | m128 | `CODER_MAX_TURNS / 2` | Turn budget per build-fix attempt |
| `BUILD_FIX_ENABLED` | m128 | `true` | Toggle build-fix continuation loop entirely |
| `BUILD_FIX_PROGRESS_GATE_FAILURES_MAX` | m128 | `2` | Max consecutive no-progress gates before abandoning |
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

M136 registers all eleven variables in `config_defaults.sh`,
adds six new `--validate-config` checks in `validate_config.sh`,
and documents them in a new subsection of `pipeline.conf.example`.

No changes to arc runtime logic. Config-layer only.

## Design

### Goal 1 — Declare all eleven vars in `lib/config_defaults.sh`

Add a new section block immediately after the `# --- Pre-flight environment
validation defaults (Milestone 55) ---` block (lines ~367–370). Follow
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
: "${BUILD_FIX_MAX_TURNS_PER_ATTEMPT:=$(( CODER_MAX_TURNS / 2 ))}"  # Turn budget per attempt
: "${BUILD_FIX_PROGRESS_GATE_FAILURES_MAX:=2}" # No-progress gates before abandoning loop

# Causal recovery routing (m130)
: "${BUILD_FIX_CLASSIFICATION_REQUIRED:=true}" # Require code_dominant classification for build-fix loop

# Preflight UI config audit (m131)
: "${PREFLIGHT_UI_CONFIG_AUDIT_ENABLED:=true}" # Scan test framework configs for interactive-mode settings
: "${PREFLIGHT_UI_CONFIG_AUTO_FIX:=true}"      # Auto-patch detected interactive config (e.g. reporter: 'html')
: "${PREFLIGHT_BAK_RETAIN_COUNT:=5}"           # Max backups to keep in .claude/preflight_bak/
```

**Derivation safety for `BUILD_FIX_MAX_TURNS_PER_ATTEMPT`:** The
expression `$(( CODER_MAX_TURNS / 2 ))` is evaluated at source time.
`CODER_MAX_TURNS` is guaranteed set before this block because it appears
earlier in `config_defaults.sh` (`:="${CODER_MAX_TURNS:=80}"`). The `:=`
operator prevents re-evaluation if `BUILD_FIX_MAX_TURNS_PER_ATTEMPT`
was already set in `pipeline.conf`. This mirrors the exact pattern used
by `FINAL_FIX_MAX_TURNS:=$((CODER_MAX_TURNS / 3))` already in the file.

**Why `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` defaults to `0` not `false`:**
The m126 implementation reads it with `[[ "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:-0}" == "1" ]]`
— treating it as a binary flag (0/1 not true/false). The default matches
that convention for consistency.

### Goal 2 — Add validation checks in `lib/validate_config.sh`

Add a new helper function `_vc_check_resilience_arc` called at the end
of `validate_config()`, between Check 12 and the summary line. The
function runs seven checks and increments `passes`/`warnings`/`errors`
via the standard `_vc_pass`/`_vc_warn`/`_vc_fail` helpers.

The integration in `validate_config()`:

```bash
    # Check 12: No stale PIPELINE_STATE.md
    ...

    # Check 13: Resilience arc config sanity (m136)
    _vc_check_resilience_arc passes warnings errors

    echo ""
    echo "${passes} passed, ${warnings} warnings, ${errors} errors"
```

Because bash doesn't support pass-by-reference for integers, use the
existing approach: `_vc_check_resilience_arc` writes directly to the
caller's `passes`/`warnings`/`errors` vars via `declare -g` or
`nameref`. Look at how `_vc_check_role_files` updates `found`/`total`
in the current code — it uses direct var mutation because it is called
from within `validate_config`'s scope. Follow the same pattern: the
function uses `local -n` (nameref, bash ≥4.3) to mutate the counters.

```bash
# _vc_check_resilience_arc P_REF W_REF E_REF
# Validates resilience arc config values. Mutates the caller's pass/warn/error
# counters via namerefs.
_vc_check_resilience_arc() {
    local -n _arc_p="$1"  # nameref to passes counter
    local -n _arc_w="$2"  # nameref to warnings counter
    local -n _arc_e="$3"  # nameref to errors counter

    echo ""
    echo "  [Resilience Arc]"

    # Check A: BUILD_FIX_MAX_ATTEMPTS must be a positive integer (1–20)
    local bfa="${BUILD_FIX_MAX_ATTEMPTS:-3}"
    if [[ "$bfa" =~ ^[0-9]+$ ]] && (( bfa >= 1 && bfa <= 20 )); then
        _vc_pass "BUILD_FIX_MAX_ATTEMPTS=${bfa} (valid)"
        _arc_p=$(( _arc_p + 1 ))
    else
        _vc_fail "BUILD_FIX_MAX_ATTEMPTS=${bfa} — must be integer 1–20"
        _arc_e=$(( _arc_e + 1 ))
    fi

    # Check B: BUILD_FIX_MAX_TURNS_PER_ATTEMPT must be a positive integer
    local bft="${BUILD_FIX_MAX_TURNS_PER_ATTEMPT:-40}"
    if [[ "$bft" =~ ^[0-9]+$ ]] && (( bft >= 1 )); then
        _vc_pass "BUILD_FIX_MAX_TURNS_PER_ATTEMPT=${bft} (valid)"
        _arc_p=$(( _arc_p + 1 ))
    else
        _vc_fail "BUILD_FIX_MAX_TURNS_PER_ATTEMPT=${bft} — must be positive integer"
        _arc_e=$(( _arc_e + 1 ))
    fi

    # Check C: UI_GATE_ENV_RETRY_TIMEOUT_FACTOR must be a decimal 0.1–1.0
    local rtf="${UI_GATE_ENV_RETRY_TIMEOUT_FACTOR:-0.5}"
    # bash can't do float comparison directly — use awk for this one check
    local rtf_ok
    rtf_ok=$(awk -v v="$rtf" 'BEGIN { print (v+0 >= 0.1 && v+0 <= 1.0) ? "ok" : "fail" }')
    if [[ "$rtf_ok" == "ok" ]]; then
        _vc_pass "UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=${rtf} (valid, 0.1–1.0)"
        _arc_p=$(( _arc_p + 1 ))
    else
        _vc_warn "UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=${rtf} — expected decimal 0.1–1.0; using 0.5"
        _arc_w=$(( _arc_w + 1 ))
    fi

    # Check D: TEKHTON_UI_GATE_FORCE_NONINTERACTIVE must be 0 or 1
    local fni="${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:-0}"
    if [[ "$fni" == "0" || "$fni" == "1" ]]; then
        _vc_pass "TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=${fni} (valid)"
        _arc_p=$(( _arc_p + 1 ))
    else
        _vc_warn "TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=${fni} — expected 0 or 1"
        _arc_w=$(( _arc_w + 1 ))
    fi

    # Check E: PREFLIGHT_BAK_RETAIN_COUNT must be non-negative integer
    local pbr="${PREFLIGHT_BAK_RETAIN_COUNT:-5}"
    if [[ "$pbr" =~ ^[0-9]+$ ]]; then
        _vc_pass "PREFLIGHT_BAK_RETAIN_COUNT=${pbr} (valid)"
        _arc_p=$(( _arc_p + 1 ))
    else
        _vc_fail "PREFLIGHT_BAK_RETAIN_COUNT=${pbr} — must be non-negative integer (0 = keep all)"
        _arc_e=$(( _arc_e + 1 ))
    fi

    # Check F (formerly G): Warn when UI_TEST_CMD is set but UI_GATE_ENV_RETRY_ENABLED is false
    if [[ -n "${UI_TEST_CMD:-}" ]] && [[ "${UI_GATE_ENV_RETRY_ENABLED:-true}" == "false" ]]; then
        _vc_warn "UI_GATE_ENV_RETRY_ENABLED=false with UI_TEST_CMD set — interactive reporter timeouts will not be auto-retried"
        _arc_w=$(( _arc_w + 1 ))
    else
        _vc_pass "UI gate retry configuration consistent"
        _arc_p=$(( _arc_p + 1 ))
    fi
}
```

**Why `awk` for float comparison in Check C:** Bash cannot compare
floating-point natively. `awk` is universally available (POSIX), is
already used elsewhere in the codebase (e.g. `gates_ui.sh`), and avoids
the `bc` dependency which is not guaranteed on all CI images.

**Why Check G is `warn` not `fail`:** Turning off the retry is a valid
project choice (e.g., for performance test suites that always take the
full `UI_TEST_TIMEOUT`). The warning is informational.

### Goal 3 — Document arc vars in `templates/pipeline.conf.example`

Add a new commented section at the end of the existing `# Section 2:
Testing` block (after `UI_TEST_TIMEOUT`), immediately before `# Section 3:
Pipeline Behavior`. This keeps all test-related config together.

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

# Turn budget per build-fix attempt (defaults to CODER_MAX_TURNS/2).
# BUILD_FIX_MAX_TURNS_PER_ATTEMPT=40

# Max consecutive no-progress gates before the loop abandons.
# BUILD_FIX_PROGRESS_GATE_FAILURES_MAX=2

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
insert the new block immediately after it (before the blank line that
precedes the Section 3 header).

### Goal 4 — Hard upper-bound clamps for numeric arc vars

`config_defaults.sh` already applies hard clamps for some numeric vars
using arithmetic assignment:

```bash
# M-existing pattern from FINAL_FIX_MAX_TURNS:
: "${FINAL_FIX_MAX_TURNS:=$((CODER_MAX_TURNS / 3))}"
```

For arc vars, the clamps happen in the `:=` expressions themselves
where safe, and in a new `_clamp_arc_config_values` function called at
the end of `config_defaults.sh`'s execution for values that need
cross-variable constraints:

```bash
# _clamp_arc_config_values — Applies hard upper-bound clamps on resilience arc
# numeric config. Called at the end of config_defaults.sh after all vars are set.
# Prevents obviously dangerous values (e.g., 9999 build-fix attempts).
_clamp_arc_config_values() {
    # BUILD_FIX_MAX_ATTEMPTS: hard ceiling = 10
    if [[ "${BUILD_FIX_MAX_ATTEMPTS:-3}" =~ ^[0-9]+$ ]] && \
       (( BUILD_FIX_MAX_ATTEMPTS > 10 )); then
        BUILD_FIX_MAX_ATTEMPTS=10
        warn "[config] BUILD_FIX_MAX_ATTEMPTS clamped to 10 (maximum allowed)"
    fi

    # BUILD_FIX_MAX_TURNS_PER_ATTEMPT: hard ceiling = CODER_MAX_TURNS_CAP
    local bft_cap="${CODER_MAX_TURNS_CAP:-200}"
    if [[ "${BUILD_FIX_MAX_TURNS_PER_ATTEMPT:-40}" =~ ^[0-9]+$ ]] && \
       (( BUILD_FIX_MAX_TURNS_PER_ATTEMPT > bft_cap )); then
        BUILD_FIX_MAX_TURNS_PER_ATTEMPT="$bft_cap"
        warn "[config] BUILD_FIX_MAX_TURNS_PER_ATTEMPT clamped to ${bft_cap} (CODER_MAX_TURNS_CAP)"
    fi
}

# Call clamp at end of config_defaults.sh
_clamp_arc_config_values
```

**Why a function call at the bottom of the file:** `config_defaults.sh`
is sourced, not executed. A function call at the end runs in the
sourcing shell's scope, which is the same pattern used by nothing today —
but `config_defaults.sh` is a pure assignment file so this is the cleanest
integration point without touching `config.sh`. If the project convention
changes to prohibit side effects in `config_defaults.sh`, the clamp can
be moved to `config.sh` after `load_config()` returns.

### Goal 5 — Extend test coverage in `tests/test_validate_config.sh`

Add six new tests covering the new `_vc_check_resilience_arc` checks:

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

# Test: BUILD_FIX_MAX_ATTEMPTS=25 → clamped to 10
echo "Test: BUILD_FIX_MAX_ATTEMPTS=25 → clamped to 10 at load time"
BUILD_FIX_MAX_ATTEMPTS=25
_clamp_arc_config_values
if [[ "$BUILD_FIX_MAX_ATTEMPTS" == "10" ]]; then
    pass "BUILD_FIX_MAX_ATTEMPTS clamped to 10"
else
    fail "Expected BUILD_FIX_MAX_ATTEMPTS=10, got $BUILD_FIX_MAX_ATTEMPTS"
fi
unset BUILD_FIX_MAX_ATTEMPTS

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

# Test: all defaults → all arc checks pass
echo "Test: All arc defaults → all checks pass"
unset BUILD_FIX_MAX_ATTEMPTS BUILD_FIX_MAX_TURNS_PER_ATTEMPT \
      UI_GATE_ENV_RETRY_TIMEOUT_FACTOR TEKHTON_UI_GATE_FORCE_NONINTERACTIVE \
      PREFLIGHT_BAK_RETAIN_COUNT \
      UI_GATE_ENV_RETRY_ENABLED UI_TEST_CMD
source "${TEKHTON_HOME}/lib/config_defaults.sh"  # re-apply defaults
passes_before=$PASS
validate_config 2>/dev/null
if (( PASS > passes_before )); then
    pass "Arc defaults produce passing checks"
else
    fail "Expected arc default checks to pass"
fi
```

## Files Modified

| File | Change |
|------|--------|
| `lib/config_defaults.sh` | New section block with 12 `:=` declarations; new `_clamp_arc_config_values` function called at the end. |
| `lib/validate_config.sh` | New `_vc_check_resilience_arc` function; call it as "Check 13" in `validate_config()`. |
| `templates/pipeline.conf.example` | New commented arc section after `UI_TEST_TIMEOUT=120` line (14 commented keys with descriptions). |
| `tests/test_validate_config.sh` | Six new test cases for arc config validation checks and clamping. |

No changes to runtime arc logic (m126–m135 code paths unchanged).

## Acceptance Criteria

- [ ] All 12 arc variables declared in `config_defaults.sh` with `:=` and sensible defaults.
- [ ] `BUILD_FIX_MAX_TURNS_PER_ATTEMPT` derived from `CODER_MAX_TURNS / 2` at source time, following existing `FINAL_FIX_MAX_TURNS` pattern.
- [ ] `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` defaults to `0` (not `false`) to match its binary flag convention.
- [ ] `_clamp_arc_config_values` clamps `BUILD_FIX_MAX_ATTEMPTS` to ≤10 and `BUILD_FIX_MAX_TURNS_PER_ATTEMPT` to ≤`CODER_MAX_TURNS_CAP`.
- [ ] `validate_config` runs Check 13 (`_vc_check_resilience_arc`) and its results appear in the pass/warn/error summary totals.
- [ ] `BUILD_FIX_MAX_ATTEMPTS=abc` produces a `fail` line in `validate_config` output.
- [ ] `UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=2.5` produces a `warn` line in `validate_config` output.
- [ ] `UI_TEST_CMD` set + `UI_GATE_ENV_RETRY_ENABLED=false` produces a `warn` line.
- [ ] All arc vars appear in the `pipeline.conf.example` commented section with descriptions.
- [ ] `shellcheck` clean for all modified files.
- [ ] Six new test cases in `tests/test_validate_config.sh` pass.
- [ ] Sourcing `config_defaults.sh` twice (idempotent source) does not change any arc var value.
