# Coder Summary
## Status: COMPLETE

## What Was Implemented

M109 — Init Feature Wizard. Adds a guided feature wizard step to `tekhton --init`
that detects Python 3.8+ and asks the user three questions about Python-dependent
features (TUI, tree-sitter repo maps, Serena LSP), then writes the answers as
**uncommented active config lines** in pipeline.conf Section 5 and triggers
inline venv setup.

### §1 — `lib/init_wizard.sh` (new, 225 lines)

Single-purpose wizard module providing:

- `_wizard_find_python3()` — Locates Python 3.8+ on PATH using a corrected
  version comparison (`major > 3 OR (major == 3 AND minor >= 8)`). Returns the
  python command name on stdout, exit 1 if not found.
- `_wizard_emit_no_python_advisory()` — Prints the advisory message naming all
  three enhanced features and pointing at `docs/getting-started/installation.md`.
- `_wizard_reset_state()` — Clears all `_WIZARD_*` env vars (used by tests and
  reentrant calls).
- `run_feature_wizard(reinit_mode)` — Main entry point. Handles three paths:
  reinit (no-op), non-interactive (sets feature config but skips venv setup),
  and interactive (three `prompt_confirm` questions, each marked recommended).
- `_wizard_attention_lines(bullet)` — Emits init banner attention bullets
  reflecting the wizard outcome (called from `_init_collect_attention()`).
- `_wizard_run_setup_script()` + `_run_wizard_venv_setup()` — Drive
  `tools/setup_indexer.sh` and (if Serena selected) `tools/setup_serena.sh`
  with summarized or verbose output. Failure is non-fatal — config remains
  valid and features degrade at runtime.

Exported state for downstream consumers:

| Variable | Values |
|----------|--------|
| `_WIZARD_TUI_ENABLED` | `true` / `auto` / unset |
| `_WIZARD_REPO_MAP_ENABLED` | `true` / unset |
| `_WIZARD_SERENA_ENABLED` | `true` / unset |
| `_WIZARD_NEEDS_VENV` | `true` / unset |
| `_WIZARD_PYTHON_FOUND` | `true` / `false` |

### §2 — `lib/init.sh` integration

- Added `source "${_INIT_DIR}/init_wizard.sh"` to the companion sourcing block.
- Inserted Phase 3.5 (`run_feature_wizard "${reinit_mode:-}"`) between crawl
  and config generation so wizard answers flow into `_emit_section_features()`
  via env vars.
- Inserted Phase 4.5 (`_run_wizard_venv_setup ...`) after config generation
  so venv setup happens after pipeline.conf is on disk.

### §3 — `lib/init_config_sections.sh` Section 5 emission

`_emit_section_features()` now reads `_WIZARD_*_ENABLED` and emits the matching
keys as active uncommented lines (or commented defaults when unset). New
behaviour vs prior:

- **`TUI_ENABLED` is now emitted** (commented `# TUI_ENABLED=auto` by default,
  or active `TUI_ENABLED=true|auto` when wizard set it). Prior code never
  emitted a TUI line.
- **`DASHBOARD_ENABLED=true` is now uncommented** (was previously
  `# DASHBOARD_ENABLED=true`). Reflects the design decision that Watchtower is
  always-on by default with effectively zero cost. Reinit merge keys preserve
  existing user values.

### §4 — `lib/init_report_banner.sh` attention items

`_init_collect_attention()` calls `_wizard_attention_lines` (when defined) so
the post-init "What Tekhton learned" section reports either:

- `✓ Enhanced features enabled: TUI, repo maps[, Serena]` (Python found and
  features selected), or
- `ℹ Install Python 3.8+ to enable enhanced features ...` (Python not found).

### §5 — File-size hygiene splits

`init_config_sections.sh` and `init_report_banner.sh` were both pushed close to
or past the 300-line ceiling by the wizard work. Extracted:

- `lib/init_config_workspace.sh` (49 lines, NEW) — `_emit_section_workspace()`
  alone. Sourced from `init_config_sections.sh`.
- `lib/init_report_banner_next.sh` (102 lines, NEW) — `_emit_next_section`,
  `_emit_auto_prompt`, and the new `_banner_detect_milestone_state` helper that
  consolidates the duplicated milestone-state probe used by both. Sourced from
  `init_report_banner.sh`.

Final line counts: init_wizard.sh 225, init.sh 218, init_config_sections.sh
294, init_config_workspace.sh 49, init_report_banner.sh 262,
init_report_banner_next.sh 103, tests/test_init_wizard.sh 204. All under the
300-line ceiling.

### §6 — Test coverage

`tests/test_init_wizard.sh` (NEW) — nine test cases covering:

1. Python not found → advisory printed, flags unset.
2. All three features selected → all `_WIZARD_*_ENABLED=true`,
   `_WIZARD_NEEDS_VENV=true`.
3. All three declined → flags remain unset, no venv trigger.
4. Mixed answers (yes/no/yes via call-counter mock) → only selected flags set.
5. `reinit` mode → wizard is a no-op.
6. Non-interactive with Python → TUI=auto, repo_map=true, serena=true,
   `_WIZARD_NEEDS_VENV` deliberately unset.
7. Non-interactive without Python → all flags unset / PYTHON_FOUND=false.
8. `_emit_section_features` with wizard vars → confirms uncommented lines for
   selected features and `DASHBOARD_ENABLED=true` always uncommented.
9. `_emit_section_features` without wizard vars → confirms today's commented
   defaults still emitted.

All 39 assertions pass. `shellcheck tekhton.sh lib/*.sh stages/*.sh` clean.
Full `bash tests/run_tests.sh` reports 409 shell tests passing and 151 Python
tests passing — no regressions.

## Root Cause (bugs only)
N/A — feature work.

## Files Modified

- `lib/init_wizard.sh` (NEW) — feature wizard module
- `lib/init.sh` — source wizard, add Phase 3.5 and Phase 4.5 hooks
- `lib/init_config_sections.sh` — `_emit_section_features` reads wizard vars,
  adds TUI line, uncomments DASHBOARD_ENABLED; sources init_config_workspace.sh
- `lib/init_config_workspace.sh` (NEW) — extracted workspace section emitter
- `lib/init_report_banner.sh` — calls `_wizard_attention_lines`; sources
  init_report_banner_next.sh; cleaned up unused `has_manifest` local in
  `_init_pick_recommendation` (pre-existing latent issue)
- `lib/init_report_banner_next.sh` (NEW) — extracted "What's next" + auto-prompt
  + shared `_banner_detect_milestone_state` helper
- `tests/test_init_wizard.sh` (NEW) — wizard + emission test coverage
- `CLAUDE.md` — repo layout updated to include both `lib/init_wizard.sh`
  (already present from a prior partial run) and the newly extracted
  `lib/init_config_workspace.sh`
- `.claude/milestones/MANIFEST.cfg` — m109 status set to `in_progress`
- `.claude/milestones/m109-init-feature-wizard.md` — milestone meta status
  updated to `in_progress`

## Docs Updated

None — no public-surface changes in this task. Section 5 emission tweaks are
internal to `--init`'s generated `pipeline.conf` (a per-project artifact, not a
user-facing CLI surface). The wizard's three prompts are interactive
output, not a documented public API. `CLAUDE.md` repo layout already lists the
new `lib/init_wizard.sh` file so future contributors can locate it.

## Human Notes Status
None listed in task input.
