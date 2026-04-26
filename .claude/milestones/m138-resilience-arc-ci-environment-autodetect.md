<!-- milestone-meta
id: m138
status: pending
-->

# m138 — Resilience Arc: Runtime CI Environment Auto-Detection

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | The m126–m137 resilience arc adds `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` to prevent interactive-reporter hangs in non-TTY environments. m136 declares the variable with a default of `0`. But a developer running Tekhton inside GitHub Actions who forgets to export `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1` in their workflow YAML will silently get the wrong behaviour — the gate will try to launch the interactive Playwright HTML reporter and time out. |
| **Gap** | `detect_ci.sh` (m12) parses CI *config files* to discover build/test commands. No code anywhere detects whether the current Tekhton *process* is running inside a CI environment at runtime (i.e. by inspecting well-known CI environment variables such as `$GITHUB_ACTIONS`, `$CI`, `$JENKINS_URL`, etc.). |
| **m138 fills** | When Tekhton starts inside a recognised CI environment and `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` has not been explicitly set in `pipeline.conf`, automatically set it to `1`. This makes the arc's non-interactive path the default for CI without any per-project configuration change. Explicit `pipeline.conf` values — including `=0` — are always honoured first. |
| **Depends on** | m126 (gate reads the variable), m136 (formal variable declaration) |
| **Files changed** | `lib/config_defaults.sh`, the file that owns `_normalize_ui_gate_env` after m126 lands (expected to be `lib/gates_ui.sh`), `tests/test_ci_environment_detection.sh`, `templates/pipeline.conf.example` |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m126 | Deterministic UI gate execution; `_normalize_ui_gate_env` reads `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` |
| m127 | Mixed-log classification |
| m128 | Build-fix continuation loop |
| m129 | Failure context schema hardening |
| m130 | Causal-context-aware recovery routing |
| m131 | Preflight UI config audit |
| m132 | RUN_SUMMARY causal fidelity |
| m133 | Diagnose rule enrichment |
| m134 | Integration test suite |
| m135 | Artifact lifecycle management |
| m136 | Config defaults & validation — declares all 13 arc vars including `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:=0` |
| m137 | V3.2 migration script |
| **m138** | **Runtime CI auto-detection — zero-config non-interactive mode in CI** |

---

## Design

### Sequencing note

This milestone is specified against the **post-m126/post-m136** code shape, not the current live tree. Two consequences matter for the implementer:

1. If `_normalize_ui_gate_env` lives somewhere other than `lib/gates_ui.sh` on the branch being implemented, patch the file that actually defines the function rather than forcing a move.
2. If the m136 arc subsection has not landed yet in `templates/pipeline.conf.example`, m138 must either land after m136 or co-edit that subsection in the same change. Do not add a second parallel comment block elsewhere in the template.

### Goal 1 — `_detect_runtime_ci_environment` in `lib/config_defaults.sh`

Add a function that returns `0` (detected) or `1` (not CI) by inspecting well-known CI environment variables. No file I/O, no subshells, no external commands — pure bash variable tests.

**Supported platforms and their detection signals:**

| Platform | Environment variable | Test |
|----------|---------------------|------|
| GitHub Actions | `GITHUB_ACTIONS` | `== "true"` |
| GitLab CI | `GITLAB_CI` | `== "true"` |
| CircleCI | `CIRCLECI` | `== "true"` |
| Travis CI | `TRAVIS` | `== "true"` |
| Buildkite | `BUILDKITE` | `== "true"` |
| Generic CI (most platforms set this) | `CI` | `== "true"` |
| Jenkins | `JENKINS_URL` | non-empty |
| Azure DevOps | `TF_BUILD` | non-empty |
| TeamCity | `TEAMCITY_VERSION` | non-empty |
| Bitbucket Pipelines | `BITBUCKET_BUILD_NUMBER` | non-empty |

The `CI=true` check covers the generic case and is the last resort. It is checked only after the named-platform variables so that the verbose log can report the specific platform name when possible.

**Placement in `lib/config_defaults.sh`:** add the function immediately before the arc config var block introduced by m136 (the block that starts with the `UI_GATE_ENV_RETRY_ENABLED` declaration). The CI detection must run before the `:=` defaults for `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` so that it can set the variable to `1` before the `:=` no-op.

```bash
# _detect_runtime_ci_environment
# Returns 0 if the current process is running inside a CI/CD system.
# Returns 1 if no CI signals are found.
# Detection is pure-bash (no subshells, no file I/O).
_detect_runtime_ci_environment() {
    # Named-platform fast-path (allows precise platform logging by callers)
    [[ "${GITHUB_ACTIONS:-}"          == "true" ]] && return 0
    [[ "${GITLAB_CI:-}"               == "true" ]] && return 0
    [[ "${CIRCLECI:-}"                == "true" ]] && return 0
    [[ "${TRAVIS:-}"                  == "true" ]] && return 0
    [[ "${BUILDKITE:-}"               == "true" ]] && return 0
    [[ -n "${JENKINS_URL:-}"                    ]] && return 0
    [[ -n "${TF_BUILD:-}"                       ]] && return 0   # Azure DevOps
    [[ -n "${TEAMCITY_VERSION:-}"               ]] && return 0
    [[ -n "${BITBUCKET_BUILD_NUMBER:-}"         ]] && return 0
    # Generic fallback: most platforms export CI=true
    [[ "${CI:-}" == "true" ]] && return 0
    return 1
}

# _get_ci_platform_name
# Returns a human-readable CI platform name for log messages.
# Caller must invoke _detect_runtime_ci_environment first.
_get_ci_platform_name() {
    [[ "${GITHUB_ACTIONS:-}"          == "true" ]] && echo "GitHub Actions"  && return
    [[ "${GITLAB_CI:-}"               == "true" ]] && echo "GitLab CI"       && return
    [[ "${CIRCLECI:-}"                == "true" ]] && echo "CircleCI"        && return
    [[ "${TRAVIS:-}"                  == "true" ]] && echo "Travis CI"       && return
    [[ "${BUILDKITE:-}"               == "true" ]] && echo "Buildkite"       && return
    [[ -n "${JENKINS_URL:-}"                    ]] && echo "Jenkins"         && return
    [[ -n "${TF_BUILD:-}"                       ]] && echo "Azure DevOps"    && return
    [[ -n "${TEAMCITY_VERSION:-}"               ]] && echo "TeamCity"        && return
    [[ -n "${BITBUCKET_BUILD_NUMBER:-}"         ]] && echo "Bitbucket Pipelines" && return
    [[ "${CI:-}" == "true"                      ]] && echo "CI (generic)"    && return
    echo "unknown"
}
```

---

### Goal 2 — `_apply_ci_ui_gate_defaults` in `lib/config_defaults.sh`

m136 adds:

```bash
: "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:=0}" # 0=auto 1=always force non-interactive gate env
```

m138 **replaces** that simple `:=` with a small helper function plus a one-line invocation at source time. The key invariant: **if the user set `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` explicitly in `pipeline.conf`, respect it unconditionally** — including if they set it to `0` to explicitly opt out of the auto-override.

`_CONF_KEYS_SET` (populated by `_parse_config_file` before `config_defaults.sh` is sourced) is the authoritative list of keys the user has explicitly configured. Check membership in that set before applying the CI override.

```bash
# _apply_ci_ui_gate_defaults
# Applies the m138 source-time defaulting rule for
# TEKHTON_UI_GATE_FORCE_NONINTERACTIVE.
#
# Invariant: explicit pipeline.conf values (including =0) always win.
# _CONF_KEYS_SET is populated by _parse_config_file before config_defaults.sh
# is sourced, so it contains exactly the keys the user wrote.
_apply_ci_ui_gate_defaults() {
    if [[ " ${_CONF_KEYS_SET:-} " != *" TEKHTON_UI_GATE_FORCE_NONINTERACTIVE "* ]] && \
       _detect_runtime_ci_environment; then
        TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1
        TEKHTON_CI_ENVIRONMENT_DETECTED=1
        if [[ "${VERBOSE_OUTPUT:-false}" == "true" ]]; then
            echo "[tekhton] CI environment detected ($(_get_ci_platform_name)) — TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 (auto)" >&2
        fi
    else
        : "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:=0}"
        TEKHTON_CI_ENVIRONMENT_DETECTED=0
    fi

    export TEKHTON_UI_GATE_FORCE_NONINTERACTIVE
    export TEKHTON_CI_ENVIRONMENT_DETECTED
}

_apply_ci_ui_gate_defaults
```

**Why use a helper instead of a raw source-time block:** it eliminates logic duplication in the tests, keeps the source-time behavior easy to re-run in isolation, and gives future arc milestones a single function to call if they need to recompute the default after config mutation in a harness.

**Why no `local` variable for the platform name:** `config_defaults.sh` is sourced at top level, so top-level logic must stay declaration-safe. Keeping the platform lookup inside a helper avoids that constraint for future refactors, but there is still no need to add a local variable here because the name is used exactly once and only on the verbose path.

**`TEKHTON_CI_ENVIRONMENT_DETECTED`** is exported as `1` or `0`. It is a diagnostic-only signal consumed by:
- `_normalize_ui_gate_env` in `lib/gates_ui.sh` (Goal 3 below) for verbose logging
- `tests/test_ci_environment_detection.sh` (Goal 4) for assertions
- Future: health dimension or dashboard arc panel

---

### Goal 3 — Verbose log annotation in the `_normalize_ui_gate_env` owner file

`_normalize_ui_gate_env` (introduced by m126) already logs the value of `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE`. m138 adds a one-liner to that function's verbose output section that includes the CI detection source, making it easy to see *why* the variable was set:

**Location:** inside `_normalize_ui_gate_env`, immediately after the block that exports `PLAYWRIGHT_BROWSERS_PATH` / `CI` / etc. — in the verbose log block that already describes the normalised env. On the expected m126 landing shape this is `lib/gates_ui.sh`; if m126 landed elsewhere, patch the actual owner file and keep the change local.

```bash
# Within _normalize_ui_gate_env's verbose section (after the env-export block):
if [[ "${TEKHTON_CI_ENVIRONMENT_DETECTED:-0}" == "1" ]]; then
    log_verbose "[gate-env] TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 was set automatically (CI auto-detect)"
fi
```

This is additive — one conditional `log_verbose` call. No structural change to the gate logic.

---

### Goal 4 — `tests/test_ci_environment_detection.sh`

New test file. 10 scenarios. Uses a minimal inline harness (same pattern as `test_validate_config.sh`).

**Test setup pattern:**

```bash
#!/usr/bin/env bash
# Test: Runtime CI environment auto-detection (m138)
# Tests _detect_runtime_ci_environment(), _get_ci_platform_name(), and
# _apply_ci_ui_gate_defaults() in config_defaults.sh.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Stub functions needed by config_defaults.sh that may not be available standalone
log()          { :; }
warn()         { :; }
log_verbose()  { :; }
_clamp_config_value() { :; }        # stub m136's existing clamp helper
_clamp_config_float() { :; }        # stub m136's existing clamp helper

# Source only config_defaults.sh — it defines _detect_runtime_ci_environment
# shellcheck source=../lib/config_defaults.sh
source "${TEKHTON_HOME}/lib/config_defaults.sh"
```

**Scenarios:**

| # | Name | Setup | Expected outcome |
|---|------|-------|-----------------|
| T1 | No CI vars set | unset all known CI vars | `_detect_runtime_ci_environment` returns 1 |
| T2 | `GITHUB_ACTIONS=true` | export `GITHUB_ACTIONS=true`, clear others | returns 0; platform name = "GitHub Actions" |
| T3 | `GITLAB_CI=true` | export `GITLAB_CI=true` | returns 0; platform name = "GitLab CI" |
| T4 | `CIRCLECI=true` | export `CIRCLECI=true` | returns 0; platform name = "CircleCI" |
| T5 | `JENKINS_URL=http://...` | export non-empty `JENKINS_URL` | returns 0; platform name = "Jenkins" |
| T6 | Generic `CI=true` | export `CI=true`, clear named-platform vars | returns 0; platform name = "CI (generic)" |
| T7 | Auto-elevation: CI + no conf key | `GITHUB_ACTIONS=true`, `_CONF_KEYS_SET=""` | `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1`; `TEKHTON_CI_ENVIRONMENT_DETECTED=1` |
| T8 | Explicit `=0` in pipeline.conf respected | `GITHUB_ACTIONS=true`, `_CONF_KEYS_SET="... TEKHTON_UI_GATE_FORCE_NONINTERACTIVE ..."`, set var to `0` | var stays `0`; auto-elevation suppressed |
| T9 | Explicit `=1` in pipeline.conf preserved | `_CONF_KEYS_SET` includes key, var already `1` | var stays `1` (`:=` no-op) |
| T10 | No CI + no conf key → defaults to `0` | no CI vars, `_CONF_KEYS_SET=""` | `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0`; `TEKHTON_CI_ENVIRONMENT_DETECTED=0` |

**T7 fixture (auto-elevation):**

```bash
echo "=== T7: CI detected + no conf key → auto-elevation to 1 ==="
# Reset state from previous tests
unset TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEKHTON_CI_ENVIRONMENT_DETECTED
export GITHUB_ACTIONS=true
_CONF_KEYS_SET=""   # key not in user's pipeline.conf

# Re-run the same helper that config_defaults.sh invokes at source time.
_apply_ci_ui_gate_defaults

[[ "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE}" == "1" ]] && \
    pass "T7: TEKHTON_UI_GATE_FORCE_NONINTERACTIVE auto-elevated to 1" || \
    fail "T7: expected 1, got ${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:-<unset>}"

[[ "${TEKHTON_CI_ENVIRONMENT_DETECTED}" == "1" ]] && \
    pass "T7: TEKHTON_CI_ENVIRONMENT_DETECTED=1" || \
    fail "T7: TEKHTON_CI_ENVIRONMENT_DETECTED expected 1, got ${TEKHTON_CI_ENVIRONMENT_DETECTED:-<unset>}"
unset GITHUB_ACTIONS
```

**T8 fixture (explicit `=0` wins):**

```bash
echo "=== T8: Explicit pipeline.conf =0 wins over CI detection ==="
unset TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEKHTON_CI_ENVIRONMENT_DETECTED
export GITHUB_ACTIONS=true
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0    # user explicitly set this
_CONF_KEYS_SET="PROJECT_NAME TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEST_CMD"
_apply_ci_ui_gate_defaults

[[ "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE}" == "0" ]] && \
    pass "T8: explicit =0 honoured (auto-elevation suppressed)" || \
    fail "T8: expected 0, got ${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE}"
unset GITHUB_ACTIONS
```

**Standard summary block (same tail as every test file):**

```bash
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
```

---

### Goal 5 — `templates/pipeline.conf.example` comment update

In the arc subsection added by m136, the comment for `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` currently reads:

```
# TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0
```

m138 expands it to:

```
# TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0
# ^ Auto-set to 1 when running inside CI (GitHub Actions, GitLab CI, CircleCI,
#   Jenkins, Azure DevOps, Buildkite, TeamCity, Bitbucket, Travis, CI=true).
#   Uncomment and set to 0 to suppress the auto-override in CI.
#   Uncomment and set to 1 to force non-interactive mode locally.
```

This change is made inside the arc subsection's comment block, keeping the example self-documenting for operators who read it.

Because the current live template does not yet contain the m136 arc subsection, the implementation rule is: anchor this edit to the `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` line inside that subsection once m136 lands. If m136 has not landed on the branch, land the subsection first and then expand the comment in place.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `lib/config_defaults.sh` | Add + modify | `_detect_runtime_ci_environment()`, `_get_ci_platform_name()`, `_apply_ci_ui_gate_defaults()`, and source-time invocation replacing the simple `:=0` default from m136 |
| `_normalize_ui_gate_env` owner file | Add (2 lines) | Verbose log annotation when `TEKHTON_CI_ENVIRONMENT_DETECTED=1`; expected file is `lib/gates_ui.sh` after m126 lands |
| `tests/test_ci_environment_detection.sh` | Create | 10-scenario test file for both helper functions and the auto-elevation logic via `_apply_ci_ui_gate_defaults()` |
| `templates/pipeline.conf.example` | Modify | Expand 1-line comment to 4-line self-documenting block for `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` |

---

## Acceptance Criteria

- [ ] `_detect_runtime_ci_environment` returns `0` for each named CI signal plus the generic `CI=true` fallback, and returns `1` when none are set.
- [ ] `_get_ci_platform_name` returns the correct human-readable string for each platform; returns `"unknown"` when none are set.
- [ ] `_apply_ci_ui_gate_defaults` is the only place that implements the CI auto-elevation rule; the source-time code path invokes that helper directly rather than duplicating its logic inline.
- [ ] When Tekhton starts with `GITHUB_ACTIONS=true` (or any other recognised CI signal) and `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` is **not** in `pipeline.conf`, the variable is set to `1` and `TEKHTON_CI_ENVIRONMENT_DETECTED=1` is exported.
- [ ] When `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0` is **explicitly present** in `pipeline.conf` (i.e. its key appears in `_CONF_KEYS_SET`), the value `0` is preserved even inside CI — no auto-elevation.
- [ ] When `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1` is explicitly present in `pipeline.conf`, the value `1` is preserved (`:=` is a no-op).
- [ ] When no CI signals are present and the key is absent from `pipeline.conf`, `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` defaults to `0` and `TEKHTON_CI_ENVIRONMENT_DETECTED=0`.
- [ ] `_normalize_ui_gate_env` emits a `log_verbose` line mentioning "CI auto-detect" when `TEKHTON_CI_ENVIRONMENT_DETECTED=1`.
- [ ] `VERBOSE_OUTPUT=true` with a CI env var set prints a diagnostic message to stderr during config loading; `VERBOSE_OUTPUT=false` (default) prints nothing.
- [ ] All 10 tests in `tests/test_ci_environment_detection.sh` pass: T1–T6 (function unit tests), T7–T10 (integration conditional block tests).
- [ ] `test_validate_config.sh` continues to pass unchanged (no regression in the Check D `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` validation path from m136, which validates `0` or `1`; auto-detected `1` is still valid).
- [ ] The `templates/pipeline.conf.example` comment for `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` explains the CI auto-detection behaviour in four lines.
- [ ] `_detect_runtime_ci_environment` and `_get_ci_platform_name` are pure bash: no subshells (`$()`), no external commands, no file reads. Verified by `declare -f` inspection showing only `[[` tests and `return`.

## Watch For

- `config_defaults.sh` is sourced after `_parse_config_file`, so `_CONF_KEYS_SET` is available here. Do not re-parse `pipeline.conf` or add file I/O to recompute explicit-key membership.
- Keep the runtime-CI logic in one helper. Re-implementing the conditional block inline in tests or in adjacent milestones invites drift.
- The current live repo does not yet contain the m136 arc subsection in `templates/pipeline.conf.example`. Land m136's subsection first or co-land it here; do not scatter CI override comments into unrelated template sections.
- The current live repo also does not yet expose `_normalize_ui_gate_env` in `lib/gates_ui.sh`. Patch the file that actually owns the function on the implementation branch; the function definition is the anchor, not the filename.
- `CI=true` is a fallback, not the preferred identity. Check named CI signals first so logs and future health surfaces can report a specific platform when available.
- `tests/run_tests.sh` already auto-discovers `tests/test_*.sh`. Adding `tests/test_ci_environment_detection.sh` should not require editing the runner unless the naming convention changes.

## Seeds Forward

- **m134 integration suite extension:** m134 already calls out CI-runtime scenarios. Keep the helper names and env signal vocabulary stable so the integration suite can add CI cases without rediscovering m138 internals.
- **m135 artifact lifecycle:** recovered CI auto-detect behavior should remain success-path quiet. Do not introduce new persisted artifacts for this milestone beyond normal gate diagnostics on terminal failure paths.
- **m137 migration consistency:** if a follow-up amends m137's migrated arc block or a later migration re-renders that section, reuse the final `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` wording here rather than introducing a third variant.
- **Future observability/health work:** `TEKHTON_CI_ENVIRONMENT_DETECTED` is intentionally diagnostic. Keep it binary and stable so later health or dashboard milestones can read it without parsing logs.
- **Future CI-platform-specific tuning:** if a later milestone needs platform-specific behavior, extend `_get_ci_platform_name`/`_detect_runtime_ci_environment` rather than teaching downstream gate code to infer platforms independently.
