# Coder Summary — M131 Preflight Test Framework Config Audit & Interactive-Mode Detection

## Status: COMPLETE

## What Was Implemented

All seven milestone goals plus mandatory extras:

1. **Goal 1 — Dispatcher** (`lib/preflight_checks_ui.sh:_preflight_check_ui_test_config`):
   resets the four `PREFLIGHT_UI_*` contract vars, honors
   `PREFLIGHT_UI_CONFIG_AUDIT_ENABLED` (inline `${...:-true}` default — m131
   does not declare in `config_defaults.sh` per layering rules), short-circuits
   when `UI_TEST_CMD` is unset/empty/`true`, then dispatches to three scanners.

2. **Goal 2 — Playwright scanner** (`_pf_uitest_playwright`):
   - PW-1 (html reporter) → calls `_pf_uitest_playwright_fix_reporter`
   - PW-2 (video on/retain-on-failure) → `warn`, no patch
   - PW-3 (reuseExistingServer: false) → `warn`, no patch
   - Conservative grep covers `'html'`, `"html"`, `['html']`, `["html"]`;
     CI-guarded `process.env.CI ? 'dot' : 'html'` does NOT match (T9).

3. **Goal 2b — PW-1 auto-fix helper** (`_pf_uitest_playwright_fix_reporter`):
   - Auto-fix gating: `PREFLIGHT_UI_CONFIG_AUTO_FIX:-${PREFLIGHT_AUTO_FIX:-true}`
     so the m136 specific knob takes precedence over the legacy m55 knob.
   - Backup filename `<YYYYMMDD_HHMMSS>_<basename>` (m135 retention contract).
   - Sed-rewrites all four simple forms; nested tuples fall through to m126.
   - `cp` failure path emits `fail` and skips sed.
   - Sed failure path emits `fail`. Both backup-fail and sed-fail paths still
     export the contract triple (`DETECTED=1`, `RULE=PW-1`, `FILE=<basename>`,
     `REPORTER_PATCHED=0`).
   - Success path emits `fixed`, exports `REPORTER_PATCHED=1`, fires
     `preflight_ui_config_patch` causal event, and defensively calls
     `_trim_preflight_bak_dir` via `declare -f` (no-op pre-m135).

4. **Goal 3 — Cypress scanner** (`_pf_uitest_cypress`): CY-1 (video: true) and
   CY-2 (mochawesome reporter without `--exit` in `UI_TEST_CMD`). Both `warn`,
   no auto-patch.

5. **Goal 4 — Jest/Vitest watch-mode scanner** (`_pf_uitest_jest_watch`): JV-1
   (`watch: true` / `watchAll: true`) → `fail`. Never auto-patched (changes DX
   for every contributor; the milestone explicitly excludes this from auto-fix).
   Exports the contract triple with `RULE=JV-1`.

6. **Goal 5 — Wired into `run_preflight_checks`**: Added the call between
   `_preflight_check_tools` and `_preflight_check_generated_code` in
   `lib/preflight.sh:154`. Source line for the new file added to `tekhton.sh`
   adjacent to the existing `preflight_checks_env.sh` source.

7. **Goal 6 — `PREFLIGHT_UI_*` contract**: All four env vars are exported at
   every fail-class path (PW-1 fail-no-patch, PW-1 patched, PW-1 sed-failed,
   PW-1 backup-failed, JV-1) per the spec table. The dispatcher `unset`s them
   at function entry so a same-shell re-invocation produces a clean state, but
   they persist across `run_complete_loop` iterations (S7.2 contract).

8. **Goal 7 — Tests** (`tests/test_preflight_ui_config.sh`): T1 (a/b/c) through
   T10 (a/b/c) — 46 assertions, all pass. Auto-discovered by
   `tests/run_tests.sh` via the `test_*.sh` glob; no runner change required.

### Mandatory extras

- **First-run env hardening hook** in `lib/gates_ui_helpers.sh:
  _ui_deterministic_env_list`: when `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1`,
  the function escalates `hardened=1` so the gate's first run gets
  `CI=1` (in addition to `PLAYWRIGHT_HTML_OPEN=never`). M126's existing
  hardened-retry behavior is preserved exactly. Existing m130 P0-T6 test
  still passes (`CI=1` is in the hardened list whether triggered by
  preflight detection or by the explicit hardened argument).
- **`docs/troubleshooting/preflight.md`** (NEW) documents PW-1..3, CY-1..2,
  JV-1, the four config knobs, and the gate-normalizer interaction.
- **`CLAUDE.md`** repository layout updated to list the new
  `lib/preflight_checks_ui.sh`.

### Test maintenance

Two existing tests broke when I added the new check call to
`run_preflight_checks`:
- `tests/test_preflight.sh` — sources individual preflight libs directly.
- `tests/test_m118_preflight_deferred_emit.sh` — same, plus has stub helpers
  that override every `_preflight_check_*`. I added the new file to the source
  list and added `_preflight_check_ui_test_config(){ :; }` to all stub blocks
  (4 occurrences). Both tests now pass.

### File-size ceiling

- `lib/preflight_checks_ui.sh`: 297 lines (NEW; under 300)
- `lib/preflight.sh`: 204 lines (modified; under 300)
- `lib/gates_ui_helpers.sh`: 178 lines (modified; under 300)

Test files are exempt by project convention (existing tests routinely exceed
300 lines; my touches to `test_preflight.sh` and `test_m118_preflight_deferred_emit.sh`
were 2-line and 4-line additions respectively).

## Root Cause (bugs only)
N/A — feature work per milestone spec.

## Files Modified

| File | Change |
|------|--------|
| `lib/preflight_checks_ui.sh` (NEW) | All five m131 functions: dispatcher, three scanners, PW-1 auto-fix helper. 297 lines. |
| `lib/preflight.sh` | Added `_preflight_check_ui_test_config` call between `_preflight_check_tools` and `_preflight_check_generated_code` in `run_preflight_checks`. |
| `lib/gates_ui_helpers.sh` | `_ui_deterministic_env_list` now escalates to hardened (`CI=1`) on first run when `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1`. |
| `tekhton.sh` | Added `source "${TEKHTON_HOME}/lib/preflight_checks_ui.sh"` adjacent to existing preflight checks sources. |
| `tests/test_preflight_ui_config.sh` (NEW) | T1–T10 plus sub-cases — 46 assertions, all pass. |
| `tests/test_preflight.sh` | Added source line for `preflight_checks_ui.sh` so the run_preflight_checks call resolves. |
| `tests/test_m118_preflight_deferred_emit.sh` | Added source line plus `_preflight_check_ui_test_config(){ :; }` to all four stub blocks. |
| `docs/troubleshooting/preflight.md` (NEW) | UI test framework config audit reference; documents PW-1..3, CY-1..2, JV-1, four config knobs, gate interaction. |
| `CLAUDE.md` | Repository layout updated with `lib/preflight_checks_ui.sh` entry. |

## Docs Updated

- `docs/troubleshooting/preflight.md` (NEW) — public surface: documents the
  six new preflight findings (PW-1, PW-2, PW-3, CY-1, CY-2, JV-1) and four
  configuration knobs (`PREFLIGHT_UI_CONFIG_AUDIT_ENABLED`,
  `PREFLIGHT_UI_CONFIG_AUTO_FIX`, `PREFLIGHT_AUTO_FIX` legacy fallback,
  `PREFLIGHT_BAK_DIR`).
- `CLAUDE.md` — repository layout listing updated to include
  `lib/preflight_checks_ui.sh`.

## Human Notes Status
None — milestone-driven work, no human notes specified.

## Architecture Change Proposals

None. The new file follows the existing `preflight.sh` / `preflight_checks.sh` /
`preflight_checks_env.sh` extraction pattern; the gates_ui_helpers hook is a
small addition to an existing helper that already supports the hardened
profile. No layer boundaries crossed.

## Verification

- `shellcheck lib/preflight_checks_ui.sh lib/preflight.sh lib/gates_ui_helpers.sh tests/test_preflight_ui_config.sh` → clean.
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` → no new warnings (excluding
  pre-existing SC1091 source-not-followed informationals).
- `bash tests/test_preflight_ui_config.sh` → 46/46 assertions pass.
- `bash tests/test_preflight.sh` → 54/54 pass.
- `bash tests/test_m118_preflight_deferred_emit.sh` → 11/11 pass.
- `bash tests/test_ui_gate_force_noninteractive.sh` → 8/8 pass (no regression).
- `bash tests/run_tests.sh` → 462/462 shell, 247 Python pass.
- File-size ceiling: every modified `lib/` file is under 300 lines.
