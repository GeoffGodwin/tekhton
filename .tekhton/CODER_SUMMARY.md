# Coder Summary

## Status: COMPLETE

## What Was Implemented

Milestone 138 — Resilience Arc: Runtime CI Environment Auto-Detection. When
Tekhton starts inside a recognised CI environment and the user has not set
`TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` in `pipeline.conf`, the variable is
auto-elevated to `1` so the m126 hardened UI gate path becomes the default
in CI without per-project YAML edits. Explicit `pipeline.conf` values
(including `=0`) are honoured unconditionally.

**Goal 1 + 2 — `lib/config_defaults_ci.sh` (NEW).** Three helpers:

- `_detect_runtime_ci_environment` — pure-bash probe of the named-platform
  signals (`GITHUB_ACTIONS`, `GITLAB_CI`, `CIRCLECI`, `TRAVIS`, `BUILDKITE`,
  `JENKINS_URL`, `TF_BUILD`, `TEAMCITY_VERSION`, `BITBUCKET_BUILD_NUMBER`)
  with `CI=true` as the generic last-resort fallback. No subshells, no file
  I/O, no external commands.
- `_get_ci_platform_name` — returns the human-readable platform name or
  `"unknown"`. Same precedence order so callers can log the specific
  platform when one is identifiable.
- `_apply_ci_ui_gate_defaults` — the single owner of the m138 rule.
  Membership check on `_CONF_KEYS_SET` (populated by `_parse_config_file`
  before `config_defaults.sh` is sourced) is the authoritative
  "user-set?" test. Exports `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` and
  `TEKHTON_CI_ENVIRONMENT_DETECTED` (diagnostic-only). Emits a single
  stderr line via `echo … >&2` when `VERBOSE_OUTPUT=true` and
  auto-elevation fired.

**Goal 1 + 2 wiring — `lib/config_defaults.sh`.** The m136 simple
`: "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:=0}"` line was replaced with
two operations:
1. `source "$(dirname "${BASH_SOURCE[0]}")/config_defaults_ci.sh"` —
   resolved relative to the file rather than via `TEKHTON_HOME` so tests
   that source `config_defaults.sh` standalone (e.g. `test_m72_tekhton_dir.sh`,
   `test_m84_tekhton_dir_complete.sh`) keep working without exporting
   `TEKHTON_HOME`.
2. `_apply_ci_ui_gate_defaults` — invokes the source-time defaulter.

The helpers live in their own file so `config_defaults.sh` remains data-only
under the project's 300-line exemption (no function bodies of its own;
function bodies + conditional logic would have broken that exemption).

**Goal 3 — `lib/gates_ui_helpers.sh`.** Added a guarded
`log_verbose "[gate-env] TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 was set
automatically (CI auto-detect)" >&2` line at the end of
`_normalize_ui_gate_env`. The `>&2` redirect is required because the
function's stdout is consumed by `mapfile` in `_ui_run_cmd`; an unredirected
`log_verbose` call would inject a bogus KEY=VALUE line into the env list
when `VERBOSE_OUTPUT=true`. Documented the constraint in the function's
header comment so future editors don't drop the redirect.

**Goal 4 — `tests/test_ci_environment_detection.sh` (NEW).** All 10 scenarios
from the milestone implemented (19 individual assertions), all passing:
T1–T6 unit-test `_detect_runtime_ci_environment` + `_get_ci_platform_name`
across platform signals; T7–T10 exercise `_apply_ci_ui_gate_defaults` with
`_CONF_KEYS_SET` membership variations to verify the auto-elevate /
explicit-=0 / explicit-=1 / no-CI default-0 paths. The test stubs out
`log`/`warn`/`log_verbose` and the m136 clamp helpers so it can source
`config_defaults.sh` standalone without dragging in `common.sh` or
`config.sh`. A `_clear_all_ci_vars` helper resets every named-platform
signal between scenarios, so inherited shell state cannot poison T1 / T6 /
T10 — tests run identically locally and inside GitHub Actions.

**Goal 5 — `templates/pipeline.conf.example`.** Replaced the m136 two-line
comment for `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` with the four-line
self-documenting block from the milestone, anchored to the same line in the
m136 arc subsection (no parallel comment block created elsewhere).

## Acceptance Criteria

- [x] `_detect_runtime_ci_environment` returns 0 for each named CI signal +
  generic `CI=true` fallback; returns 1 when none set (T1–T6).
- [x] `_get_ci_platform_name` returns the correct human-readable string per
  platform; returns `"unknown"` when none set.
- [x] `_apply_ci_ui_gate_defaults` is the only place that implements the
  CI auto-elevation rule. The source-time path in `config_defaults.sh`
  invokes the helper instead of duplicating the conditional inline.
- [x] Auto-elevation fires when `GITHUB_ACTIONS=true` and the key is absent
  from `_CONF_KEYS_SET` (T7).
- [x] Explicit `=0` in `pipeline.conf` is preserved inside CI (T8).
- [x] Explicit `=1` in `pipeline.conf` is preserved (T9).
- [x] Outside CI, the value defaults to `0` and `TEKHTON_CI_ENVIRONMENT_DETECTED=0` (T10).
- [x] `_normalize_ui_gate_env` emits a `log_verbose` line mentioning
  "CI auto-detect" when `TEKHTON_CI_ENVIRONMENT_DETECTED=1`. Redirected to
  stderr to preserve mapfile-captured stdout.
- [x] `VERBOSE_OUTPUT=true` + CI signal prints a diagnostic to stderr
  during config loading; default `VERBOSE_OUTPUT=false` is silent.
- [x] All 10 tests in `tests/test_ci_environment_detection.sh` pass.
- [x] `tests/test_validate_config.sh` — passes unchanged (24/24).
- [x] `tests/test_validate_config_arc.sh` — passes unchanged (16/16).
- [x] Full shell suite: 471 passed, 0 failed (was 468 + 3 pre-existing
  failures from M137 baseline; the 3 — `test_m72_tekhton_dir.sh`,
  `test_m84_tekhton_dir_complete.sh`, `test_tui_lifecycle_invariants.sh` —
  initially broke because they source `config_defaults.sh` standalone with
  no `TEKHTON_HOME` exported. Switched the source line to a
  `BASH_SOURCE`-relative path; all three now pass).
- [x] `templates/pipeline.conf.example` comment expanded to the 4-line
  self-documenting block specified in Goal 5.
- [x] `_detect_runtime_ci_environment` and `_get_ci_platform_name` are
  pure bash — only `[[ ]]` tests + `return`/`echo`. No subshells or
  external commands.

## Files Modified

- `lib/config_defaults_ci.sh` (NEW, 84 lines) — three M138 helpers.
- `lib/config_defaults.sh` — sources the new helper file via
  `BASH_SOURCE`-relative path; replaces the m136 `:=0` line with a call to
  `_apply_ci_ui_gate_defaults`. File remains data-only (no function bodies),
  preserving the 300-line exemption.
- `lib/gates_ui_helpers.sh` — adds the m138 verbose annotation inside
  `_normalize_ui_gate_env` with `>&2` redirect; expands the function header
  comment to document the mapfile-stdout constraint.
- `tests/test_ci_environment_detection.sh` (NEW, 168 lines) — 10-scenario
  test file (19 assertions) exercising all three helpers.
- `templates/pipeline.conf.example` — comment for
  `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` expanded from 2 to 4 lines.
- `CLAUDE.md` — added `lib/config_defaults_ci.sh` to the Repository Layout
  tree.
- `ARCHITECTURE.md` — added one-line entry for `lib/config_defaults_ci.sh`
  immediately after `lib/config_defaults.sh`; appended a sentence to the
  `lib/config_defaults.sh` description noting the m138 chain.

## Verification

- `shellcheck --severity=warning tekhton.sh lib/*.sh stages/*.sh tests/test_ci_environment_detection.sh` → clean.
- `bash tests/test_ci_environment_detection.sh` → 19 passed, 0 failed.
- `bash tests/test_validate_config.sh` → 24 passed, 0 failed.
- `bash tests/test_validate_config_arc.sh` → 16 passed, 0 failed.
- `bash tests/test_m72_tekhton_dir.sh` → 83/83 passed.
- `bash tests/test_m84_tekhton_dir_complete.sh` → 36/36 passed.
- `bash tests/test_tui_lifecycle_invariants.sh` → 17 passed.
- `bash tests/run_tests.sh` → 471 shell tests passed, 0 failed; Python 247 passed.

## File Lengths (300-line ceiling check)

- `lib/config_defaults.sh` — 673 lines (data-only — exempt; no function bodies introduced).
- `lib/config_defaults_ci.sh` — 84 lines.
- `lib/gates_ui_helpers.sh` — 190 lines.
- `tests/test_ci_environment_detection.sh` — 168 lines.

## Architecture Change Proposals

None — the milestone's Sequencing Note specifies that `_normalize_ui_gate_env`
should be patched in its actual owner file, which is `lib/gates_ui_helpers.sh`
on this branch (m126's helper-extraction landing). No new layer boundary or
interface contract was introduced. The decision to put the three helpers in
their own file (`config_defaults_ci.sh`) rather than inline in
`config_defaults.sh` is an internal-organization choice that preserves the
data-only exemption documented in CLAUDE.md — observable behaviour is identical.

## Human Notes Status

N/A — no `HUMAN_NOTES.md` items injected for this milestone.

## Docs Updated

- `CLAUDE.md` — Repository Layout tree now lists `lib/config_defaults_ci.sh`.
- `ARCHITECTURE.md` — added a `lib/config_defaults_ci.sh` entry and noted the
  chain from `lib/config_defaults.sh` to it.

The new config keys in this milestone are diagnostic-only
(`TEKHTON_CI_ENVIRONMENT_DETECTED`) and exported behaviour
(`TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` auto-elevation), which the milestone
itself documents as the canonical reference. The
`templates/pipeline.conf.example` comment update (Goal 5) is the
operator-facing doc update for the public-surface change.
