# Drift Log

## Metadata
- Last audit: 2026-04-20
- Runs since audit: 2

## Unresolved Observations
- [2026-04-20 | "M109: Init Feature Wizard"] `lib/init_wizard.sh:224` — `_INIT_FILES_WRITTEN` is a global array declared in `init.sh` and mutated by `_run_wizard_venv_setup` in `init_wizard.sh`. If more wizard-style modules are extracted in the future, registration points will scatter. Consider a `_init_register_file path desc` helper as a single registration entry point.
- [2026-04-20 | "M109: Init Feature Wizard"] -- **Prior blocker resolved:** `set -euo pipefail` is now present on line 2 of all three new files (`lib/init_wizard.sh`, `lib/init_config_workspace.sh`, `lib/init_report_banner_next.sh`). Verified by direct read.
- [2026-04-20 | "architect audit"] **`stages/review.sh` Jr-after-Sr TUI path (lines 294–303) — no `tui_stage_begin`/`tui_stage_end` brackets** The coder summary confirms this is intentional: "Jr-after-Sr pill-sharing path is deliberately left unwired per spec." The pipeline spec §5 also confirms the decision. The behavior is correct. No remediation action is warranted; the drift log entry can be cleared. --- **`tools/tests/test_tui.py` at 768 lines (over 300-line soft ceiling)** The 300-line ceiling is a convention for shell library files in `lib/` — it was established to keep individual sourced modules auditable and to limit context window cost when loading files into agent prompts. Python test files have no equivalent constraint: they grow naturally with test coverage, are never sourced into shell context, and are not subject to the same auditing economics. No action is warranted; the drift log entry can be cleared.

## Resolved
