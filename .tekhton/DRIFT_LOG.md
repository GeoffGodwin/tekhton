# Drift Log

## Metadata
- Last audit: 2026-04-22
- Runs since audit: 5

## Unresolved Observations
- [2026-04-22 | "M121"] `lib/milestone_split_dag.sh:81` — pre-existing: the `*/*` path-traversal guard does not explicitly reject the degenerate `..` case (no slash); OS-level safety means no actual traversal is possible, but the defensive intent would be cleaner with an explicit `|| [[ "$sub_file" == ".." ]]`. Not introduced by M121 — surfaces here from the security agent's low-severity finding.
- [2026-04-22 | "M120 - Planning Mode DESIGN_FILE Default Restoration"] `lib/common.sh:1-17` — File has been over the 300-line ceiling since before M120 (415 lines after M120 reduced it from 446). The box-drawing helpers (_build_box_hline, _print_box_line, _setup_box_chars, _print_box_frame) are a natural extraction candidate for a future cleanup milestone.
- [2026-04-22 | "M120 - Planning Mode DESIGN_FILE Default Restoration"] `lib/init_helpers_maturity.sh:26` and `lib/init.sh:225-229` — Redundant design-doc disk probes: the caller builds `_m120_design_file` by checking `.tekhton/DESIGN.md` and `DESIGN.md`, then passes it to `_classify_project_maturity`, which makes the same on-disk checks again internally. One of the two lookups is unnecessary.
- [2026-04-22 | "architect audit"] | Observation | Justification | |---|---| | Obs-4: `tui_substage_begin` MODEL arg not bound | **Already fixed.** Current code at `lib/tui_ops_substage.sh:33-34` has `local _model="${2:-}"` and `: "$_model"`. The function header comment at line 21 documents the signature correctly. No action required. | | Obs-5: `milestone_split_dag.sh` path-traversal risk (LOW, M111) | **Already fixed.** Current code at `lib/milestone_split_dag.sh:81-84` has an explicit `*/*` guard: `if [[ "$sub_file" == */* ]]; then error "Refusing to write milestone file with path separator: ${sub_file}"; return 1; fi`. The guard is exactly what the security agent recommended. | | Obs-6a: `get_stage_policy` subshell overhead | **Out of scope by prior audit.** No demonstrated performance problem; eliminating the subshell requires replacing a clean function-call pattern with a nameref or global-variable side-channel. Carried forward without change. | | Obs-6b: `_INIT_FILES_WRITTEN` scatter risk | **Out of scope by prior audit.** No scatter has materialized; `lib/init_wizard.sh` uses the cleaner signal-variable protocol. Adding `_init_register_file()` now is speculative indirection. Carried forward without change. |

## Resolved
