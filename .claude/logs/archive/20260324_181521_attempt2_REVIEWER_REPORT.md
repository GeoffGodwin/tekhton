# Reviewer Report — Milestone 22: Init UX Overhaul

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/init_report.sh` is 351 lines (51 over the 300-line soft ceiling); `lib/init_config_sections.sh` is 305 lines (5 over). Both work correctly — log for next cleanup pass.
- `init_report.sh` calls `_best_command()` (defined in `init_config.sh`) without declaring that dependency in its header comment. Works at runtime due to sourcing order in `init.sh`, but undeclared cross-file dependency.
- `init_config_sections.sh` is sourced twice: once inside `init_config.sh` (line 13) and once directly in `init.sh` (line 25). Harmless (just re-defines the same functions), but redundant — one source site should be removed.
- `format_detection_summary()` added to `detect_report.sh` and claimed in coder summary as "consumed by emit_init_summary() and emit_init_report_file()" — neither of those functions actually calls it. The function is dead code at present; remove or wire it up in a future pass.
- Old flat config emitters in `init_config.sh` (`_emit_header`, `_emit_tools`, `_emit_models`, `_emit_turns`, `_emit_commands`, `_emit_command_line`, `_emit_paths`, `_emit_workspace_config`, lines 209–412) are now unreachable — `_generate_smart_config` delegates entirely to `generate_sectioned_config`. These orphaned functions add ~200 lines of dead code; log for cleanup.

## Coverage Gaps
- No test coverage for `_merge_preserved_values()` edge cases: keys whose values contain `|`, `\`, or `&` would break the `sed -i "s|...|...|"` replacement. Tester should add a unit test with a value containing `/` to verify the `|`-delimited sed doesn't break on path values.
- No test for `emit_init_report_file()` verifying the HTML comment metadata block format matches what `emit_dashboard_init()` parses (both exist but are tested independently).

## ACP Verdicts
(No Architecture Change Proposals in CODER_SUMMARY.md)

## Drift Observations
- `init_config.sh:209–412` — ~200 lines of old flat config emitters (`_emit_header`, `_emit_tools`, etc.) are now dead code post-M22. Same concept (command-with-confidence annotation) duplicated between `_emit_command_line` (old) and `_emit_verified_line` (new in `init_config_sections.sh`). Will accumulate if not cleaned up.
- `detect_report.sh:93–117` — `format_detection_summary()` has a different field ordering convention than the existing `detect_commands()` output: commands output is `TYPE|CMD|SOURCE|CONF` but `format_detection_summary` emits `COMMAND_${type}|${cmd}|${conf}|${source}` (conf and source swapped). If this function is ever wired up, the field positions will silently produce wrong data.
