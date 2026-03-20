# Scout Report: Milestone 15.1.2

## Relevant Files
- `lib/drift_cleanup.sh` — Contains non-blocking notes management; `clear_resolved_nonblocking_notes()` already implemented (lines 220-265)
- `lib/config_defaults.sh` — Holds default values for all pipeline config; AUTO_COMMIT currently set unconditionally to true (line 129)
- `lib/config.sh` — Contains `load_config()` and `apply_milestone_overrides()` function; sourced before argument parsing
- `tekhton.sh` — Main entry point; initializes MILESTONE_MODE=false (line 149), sources config.sh (line 288), calls load_config (line 320), parses args including --milestone (lines 466-469, 471-475), calls apply_milestone_overrides() after setting MILESTONE_MODE
- `tests/test_auto_commit_conditional_default.sh` — Test file exists but expects OLD behavior (AUTO_COMMIT always defaults to true); needs update for NEW behavior (conditional on MILESTONE_MODE)

## Key Symbols
- `clear_resolved_nonblocking_notes()` — lib/drift_cleanup.sh:220-265 (ALREADY IMPLEMENTED)
- `apply_milestone_overrides()` — lib/config.sh (called when MILESTONE_MODE=true)
- `load_config()` — lib/config.sh (sources config_defaults.sh)
- `AUTO_COMMIT` — lib/config_defaults.sh:129 (current: unconditional `=true`)
- `MILESTONE_MODE` — tekhton.sh:149 (initialized false, set true at lines 467, 473)

## Suspected Root Cause Areas
- **config_defaults.sh line 129** — Currently sets AUTO_COMMIT=true unconditionally; needs conditional logic based on MILESTONE_MODE value at sourcing time
- **Execution order mismatch** — config_defaults.sh sourced during load_config (before argument parsing); MILESTONE_MODE not yet set to true by --milestone flag when defaults apply
- **apply_milestone_overrides()** — Should apply AUTO_COMMIT conditional default after MILESTONE_MODE is set, or fallback logic for user-unset AUTO_COMMIT
- **Test expectations** — test_auto_commit_conditional_default.sh expects AUTO_COMMIT=true in ALL scenarios (tests 1, 2, 5, 6, 7, 8); needs rewrite to expect false in non-milestone mode

## Complexity Estimate
Files to modify: 3
Estimated lines of change: 35
Interconnected systems: low
Recommended coder turns: 20
Recommended reviewer turns: 8
Recommended tester turns: 15
