# Drift Log

## Metadata
- Last audit: 2026-04-21
- Runs since audit: 4

## Unresolved Observations
- [2026-04-22 | "Implement Milestone 116: Rework + Architect-Remediation Migration Retire tui_stage_transition"] `tui_ops_substage.sh` is a runtime dependency of `run_op` (via `tui_substage_begin`/`tui_substage_end`), but the CLAUDE.md layout entry for `tui_ops.sh` still reads "M104 run_op wrapper + TUI update/event helpers" with no mention of the M113 substage dependency. A reader scanning the layout won't know the two modules are coupled.
- [2026-04-22 | "Implement Milestone 115: run_op Migration and current_operation Retirement"] `tui_ops_substage.sh` is a runtime dependency of `run_op` (via `tui_substage_begin`/`tui_substage_end`), but the CLAUDE.md layout entry for `tui_ops.sh` still reads "M104 run_op wrapper + TUI update/event helpers" with no mention of the M113 substage dependency. A reader scanning the layout won't know the two modules are coupled.
- [2026-04-22 | "M114 - TUI Renderer + Scout Substage Migration"] `lib/tui_ops_substage.sh:27-35` — `tui_substage_begin` signature accepts a MODEL positional arg (documented in the function header comment as `tui_substage_begin LABEL [MODEL]`) but the body only assigns `label="${1:-}"`. The MODEL is never stored or forwarded anywhere. If future milestones want to display the substage model in the TUI, the infrastructure to pass it in is already present at the call site (`${CLAUDE_SCOUT_MODEL:-}`) but the receiving code is absent. Either document the ignore explicitly with a `local _model="${2:-}"` binding, or remove MODEL from the public signature in the header comment to avoid confusion.
- [2026-04-21 | "Implement Milestone 113: TUI Hierarchical Substage API"] [lib/milestone_split_dag.sh:77-78] Security agent flagged a LOW path-traversal risk (pre-existing from M111): `sub_file` is written without an explicit `*/*` guard, relying solely on `_slugify` to sanitize LLM-generated content. Carried forward from M112 review; cleanup pass owns the one-line fix.
- [2026-04-21 | "architect audit"] **Observation 6a — `get_stage_policy` subshell overhead:** The drift log itself classifies this as "Low-priority until policy lookups move into high-frequency paths." Eliminating the subshell would require replacing a clean function-call pattern with a nameref or global-variable side-channel. No demonstrated performance problem exists. Out of scope. **Observation 6b — `_INIT_FILES_WRITTEN` scatter risk:** Only two non-`init.sh` files touch the array; `lib/init_wizard.sh` already uses the cleaner signal-variable protocol (`_WIZARD_VENV_CREATED`). No scatter has materialized. Adding `_init_register_file()` now is speculative indirection. Out of scope.

## Resolved
