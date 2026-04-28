# Coder Summary

## Status: COMPLETE

## What Was Implemented

M136 — Resilience Arc Config Defaults & Validation Hardening. Config-layer
hardening for the resilience arc (m126/m128/m130/m131/m135). No runtime
changes.

**Goal 1 — Declare missing arc vars in `lib/config_defaults.sh`.** Added a
new `# --- Resilience arc defaults ...` section after the Pre-flight
(Milestone 55) block, registering the seven arc keys that were not yet
declared: `UI_GATE_ENV_RETRY_ENABLED`, `UI_GATE_ENV_RETRY_TIMEOUT_FACTOR`,
`TEKHTON_UI_GATE_FORCE_NONINTERACTIVE`, `BUILD_FIX_CLASSIFICATION_REQUIRED`,
`PREFLIGHT_UI_CONFIG_AUDIT_ENABLED`, `PREFLIGHT_UI_CONFIG_AUTO_FIX`,
`PREFLIGHT_BAK_RETAIN_COUNT`. The six M128 build-fix keys were already
declared in the existing `# --- Build-fix continuation loop defaults
(M128) ---` block (and used by the M128 runtime), so the new section's
header comment points the reader to that block instead of duplicating
them.

**Goal 2 — Validate arc values in `lib/validate_config.sh`.** Added Check
13 dispatch (`_vc_check_resilience_arc`) at the end of `validate_config()`
between Check 12 and the summary line. The helper performs six checks
(integer range, decimal range, binary flag, integer presence, intent
mismatch) and mutates `validate_config()`'s `passes`/`warnings`/`errors`
counters via dynamic scope, matching the existing `_vc_check_role_files`
/ `_vc_check_manifest` helper style.

**Goal 3 — Document arc vars in `templates/pipeline.conf.example`.** Added
a `# ─── Resilience arc (m126–m131) ───` commented section immediately
after the existing `# UI_TEST_TIMEOUT=120` line, with all 13 arc keys
present (commented, with descriptions).

**Goal 4 — Reuse existing clamp infrastructure.** Added two new clamp
calls to the existing hard-clamp table:
`_clamp_config_float UI_GATE_ENV_RETRY_TIMEOUT_FACTOR 0.1 1.0` and
`_clamp_config_value PREFLIGHT_BAK_RETAIN_COUNT 1000`. No new clamp
helper introduced.

**Goal 5 — Test coverage.** Added seven new test cases (14 assertions)
covering the six arc checks plus an all-defaults clean-pass case. The
tests verify: BUILD_FIX_MAX_ATTEMPTS=abc → error,
BUILD_FIX_BASE_TURN_DIVISOR=0 → error, UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=2.5
→ warning, TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=yes → warning, UI_TEST_CMD
+ retry-disabled → warning, PREFLIGHT_BAK_RETAIN_COUNT=abc → error, and
the all-defaults pass with `[Resilience Arc]` header and 0 errors.

## Plan Deviations

**1. Helper placement: `_vc_check_resilience_arc` lives in
`lib/validate_config_arc.sh`, not in `validate_config.sh`.** The design
said to add the helper inside `validate_config.sh`. With six checks (~65
lines) inlined, the file would have grown from 273 → ~338 lines,
breaching the 300-line ceiling (a non-negotiable rule from `CLAUDE.md`).
Following the same pattern M135 used for
`finalize_summary_collectors.sh`, the new helper lives in a sibling file
and is sourced from `validate_config.sh` at load time. The dispatcher
call (`_vc_check_resilience_arc`) inside `validate_config()` is
unchanged. Final sizes: `validate_config.sh` 279, `validate_config_arc.sh`
82 — both under 300.

**2. Test placement: M136 tests live in
`tests/test_validate_config_arc.sh`, not appended to
`test_validate_config.sh`.** The design said to add cases into the
existing test file. The existing file was already 305 lines (over the
300 ceiling, pre-existing). Appending six more cases would have pushed
it to 434 lines, materially worsening the breach in a file I was
modifying. Splitting per-feature mirrors the lib split (`validate_config_arc.sh`)
and keeps the new test file self-contained and at 188 lines. Both files
are picked up automatically by `tests/run_tests.sh`'s glob.

**3. M128 build-fix runtime contract preserved.** The milestone's Goal 1
design block listed all 13 vars together (including the six already
declared in M128's existing block) and proposed
`BUILD_FIX_MAX_TURN_MULTIPLIER:=1.0`. The M128 runtime contract uses
integer-percent encoding (`100 = 1.0×`), so changing the default to
`1.0` would break the loop's `(( ... * MULTIPLIER / 100 ))` arithmetic.
Per the milestone's "No changes to arc runtime logic" constraint, the
existing M128 block was left as-is; the new arc section header points to
it. Same reasoning for the existing M128 clamps
(`_clamp_config_value BUILD_FIX_MAX_TURN_MULTIPLIER 500` is integer 500,
not float 1.0–5.0): changing them would clamp current runtime defaults
to invalid values. Only the two genuinely new clamps were added.

**4. Documented `BUILD_FIX_MAX_TURN_MULTIPLIER=100` in
`pipeline.conf.example`.** The design block showed `=1.0` as the
documented default; this would mislead operators since the runtime
expects integer percent. The commented example uses `=100` with an
explanation of the encoding, matching the M128 declaration.

## Files Modified

- `lib/config_defaults.sh` — new `Resilience arc defaults` section after
  the Pre-flight (M55) block (7 `:=` lines for the arc keys not already
  registered by M128); two new clamps appended to the existing hard-clamp
  table.
- `lib/validate_config.sh` — sources the new arc helper at the top;
  added Check 13 dispatch line in `validate_config()` between Check 12
  and the summary; added a header note explaining the helper split.
- `lib/validate_config_arc.sh` (NEW) — `_vc_check_resilience_arc`
  function with six arc-config checks. Sourced by `validate_config.sh`.
- `templates/pipeline.conf.example` — new `Resilience arc (m126–m131)`
  commented section with 13 keys, inserted after the existing
  `# UI_TEST_TIMEOUT=120` anchor line.
- `tests/test_validate_config_arc.sh` (NEW) — seven test cases (14
  assertions) covering Check 13 behavior. Self-contained, follows the
  same setup pattern as `test_validate_config.sh`.

## Human Notes Status

N/A — no human notes for this task.

## Docs Updated

None — no public-surface changes in this task. The new operator-facing
config keys are all documented in `templates/pipeline.conf.example`
(the canonical operator-facing surface for `pipeline.conf` keys).
`CLAUDE.md`'s Template Variables table already lists these keys — no
edit required. The new helper file (`validate_config_arc.sh`) is
private and not individually referenced in `ARCHITECTURE.md` or
`CLAUDE.md`'s repository layout (consistent with the existing
`validate_config.sh` not being listed there either).

## Verification

- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — clean (no output).
- `bash tests/test_validate_config.sh` — 24 passed, 0 failed.
- `bash tests/test_validate_config_arc.sh` — 14 passed, 0 failed.
- `bash tests/test_config_defaults_claude_standard_model.sh` — all passed
  (config_defaults.sh still loads cleanly under strict bash).
- `bash tests/test_validate_config_design_file.sh` — 8 passed, 0 failed
  (M121 checks still work).
- `bash tests/test_resilience_arc_integration.sh` — 75 passed, 0 failed
  (M135 integration unchanged).
- `bash tests/test_preflight_ui_config.sh` — 46 passed, 0 failed
  (M131 integration unchanged).
- `bash tests/run_tests.sh` — 468 shell + 247 python passed, 0 failed.
- File line counts: `validate_config.sh` 279, `validate_config_arc.sh`
  82, `test_validate_config.sh` 305 (unchanged from pre-task),
  `test_validate_config_arc.sh` 188 — all `.sh` files I created or
  modified are under 300 lines (or are pre-existing as in the case of
  `test_validate_config.sh`). `config_defaults.sh` (661) and
  `pipeline.conf.example` (325) are exempt as data-only / template files.
