# Coder Summary

## Status: COMPLETE

## What Was Implemented
Addressed all 30 open non-blocking notes in `.tekhton/NON_BLOCKING_LOG.md`. Real
code changes were made for the actionable items; informational/observational
items are acknowledged and marked resolved with rationale below.

### Code & Config Fixes
- **M127 magic literal `60`** (`lib/error_patterns_classify.sh`): named the
  noncode confidence threshold as `_NONCODE_CONFIDENCE_THRESHOLD=60` at the top
  of the file and replaced the inline literal in `classify_routing_decision()`.
- **M128 vestigial `BUILD_GATE_RETRY` block** (`stages/coder.sh:1106–1121`):
  removed the `BUILD_GATE_RETRY=0` / `< 1` guard; `run_build_fix_loop` now owns
  retry depth via `BUILD_FIX_MAX_ATTEMPTS`. Comment updated from "with one retry"
  to reflect config-driven depth. Net `-4` lines.
- **M128 `filter_code_errors` test stub** (`tests/build_fix_loop_fixtures.sh:41`):
  changed from `cat` (read stdin) to `printf '%s\n' "${1:-}"` (positional
  pass-through) so the stub now matches its documented "pass-through" semantics.
- **M127 catch-all in dispatch** (`stages/coder_buildfix.sh`): added an explicit
  `*) warn ...; ;;` arm before the legacy fall-through so unknown future routing
  tokens get a forward-visibility warning instead of silently routing as
  `code_dominant`.
- **M128 `BUILD_FIX_REPORT_FILE` duplicate default**: removed the redundant
  declaration in `lib/config_defaults.sh`; `lib/artifact_defaults.sh` is the
  single source per spec.
- **M129 `echo "$sub_block"`** (`lib/milestone_split_dag.sh:87`): replaced with
  `printf '%s\n'` to remove echo-flag-interpretation risk (also covers the
  duplicate M127 entry of the same finding).
- **M133 `_rule_build_fix_exhausted` source numbering**
  (`lib/diagnose_rules_resilience.sh`): renumbered docstring sources to match
  evaluation order (RUN_SUMMARY → BUILD_FIX_REPORT → LAST_FAILURE_CONTEXT) and
  updated inline `Source N:` comments. Also added a comment on the recursive
  `grep -rqlE` scan in `_rule_ui_gate_interactive_reporter` acknowledging the
  manual-tool trade-off for large log archives.
- **M133 file-size ceiling**: extracted `_rule_preflight_interactive_config`
  into a new sibling file `lib/diagnose_rules_resilience_preflight.sh`
  (sourced from the parent), bringing the parent from 308 → 245 lines.
- **M135 stale gitignore comment**
  (`tests/test_ensure_gitignore_entries.sh:72`): comment updated from "All 18
  Tekhton runtime patterns" to match the actual 20 entries in `EXPECTED_ENTRIES`.
- **M135 / M134 JSON heredoc escaping** (`tests/resilience_arc_fixtures.sh`):
  added a `_arc_json_escape` helper and applied it to the interpolated
  `pri_signal` / `cls` arguments in `_arc_write_v2_failure_context` and
  `_arc_write_v1_failure_context`; the previous direct interpolation was
  flagged LOW by the security agent.
- **M136 `_clamp_config_value BUILD_FIX_MAX_ATTEMPTS 20`**: added the missing
  clamp entry to `lib/config_defaults.sh` to close the defensive-redundancy
  gap (the validator already errors > 20). Closes both M136 and M137 entries
  of the same finding.
- **M138 / M137 milestone-implementation findings**: all four post-acceptance
  observations validated and marked resolved (see file-specific notes).
- **M81 `lib/init_report_banner.sh` 355-line ceiling violation**: extracted
  the post-init-auto-prompt section into `lib/init_report_banner_next.sh`,
  bringing the parent from 355 → 262 lines and adding a clear seam for future
  growth. Sourced from the parent at function-load time.
- **M80 empty `{{IF:DRAFT_SEED_DESCRIPTION}}` block**
  (`prompts/draft_milestones.prompt.md:34-35`): removed the dead empty
  conditional pair.
- **M80 `head -"$count"` integer guard** (`lib/draft_milestones.sh:87`):
  added `[[ "$count" =~ ^[0-9]+$ ]] || count=3` before the pipeline so a
  malformed `DRAFT_MILESTONES_SEED_EXEMPLARS` value falls back to the
  documented default instead of being passed to `head` as a malformed flag.
- **POLISH `tools/tui_render_timings.py:64` comment rot**: rewrote the column
  config comment to describe the actual fix (truncation by the row builder,
  with `no_wrap=False` / `overflow="fold"` as the wrap backstop) rather than
  the old non-working approach.
- **Test split** (M30+ ceiling): `tests/test_output_format.sh` (407 → 204) and
  `tests/test_report.sh` (387 → 182) split into helper fixture files and
  focused per-feature test files (`tests/output_format_fixtures.sh`,
  `tests/report_fixtures.sh`, `tests/test_output_format_json.sh`,
  `tests/test_report_color.sh`).

### Informational items (no code change required)
- **M133 SC2034 inconsistency**: re-checked — all three rules in
  `lib/diagnose_rules_resilience.sh` already have the
  `# shellcheck disable=SC2034` annotations on each `DIAG_*` assignment;
  the original report was inaccurate. Marked resolved.
- **M131 `grep -P` macOS portability**: documented Linux/WSL is the supported
  target. Worth tracking only if macOS support is ever added. Acknowledged.
- **M131 multiple-pass-record verbosity**: minor verbosity, not a correctness
  issue. Acknowledged; no change.
- **M128 `BUILD_FIX_TURN_BUDGET_USED` semantic naming**: the field tracks the
  per-attempt allocated budget, not the actual turns consumed. M132 consumers
  treat it as an upper bound. Documented inline; rename deferred.
- **M128 "stages/coder.sh lines decreased"**: the `BUILD_GATE_RETRY` cleanup
  now removes 4 net lines from `stages/coder.sh`, partially closing the gap.
  The acceptance criterion is non-issue-grade per the original coder's
  rationale (M127 had already extracted the inline block).
- **M137 test placement**: confirmed `bash tests/run_tests.sh` picks up
  `tests/test_validate_config_arc.sh` via its glob — output of the full
  test run shows `PASS test_validate_config_arc.sh`. Acceptance checker
  runs against `run_tests.sh` output, so the placement is fine.
- **M81 `lib/prompts.sh` INIT_AUTO_PROMPT registry**: `lib/prompts.sh` is a
  generic auto-discovery template engine — there is no in-file variable
  registry. The CLAUDE.md "Template Variables" table already lists
  `INIT_AUTO_PROMPT`. No `prompts.sh` change is required.

## Root Cause (bugs only)
- M127 magic literal: untested config tuning; reduced by promoting to a named
  constant.
- M128 vestigial guard: leftover from pre-M128 single-retry pattern.
- M129 `echo "$sub_block"`: echo-flag interpretation in user-controlled paths.
- M133 docstring/code numbering mismatch: refactor drift between source-order
  and evaluation-order during M133 implementation.
- M133 308-line ceiling violation: comment additions on top of an already
  pre-existing 304-line file.
- M81 banner ceiling violation: incremental growth of the brownfield report.
- M80 empty IF and `head -"$count"`: copy-paste residue and missing input
  validation.
- TUI comment rot: documentation drift after the truncation fix landed.

## Files Modified
- `lib/error_patterns_classify.sh` — named threshold constant
- `lib/diagnose_rules_resilience.sh` — source numbering + scan comment + extraction stub
- `lib/diagnose_rules_resilience_preflight.sh` (NEW) — extracted preflight rule
- `lib/draft_milestones.sh` — integer guard for `DRAFT_MILESTONES_SEED_EXEMPLARS`
- `lib/milestone_split_dag.sh` — `echo` → `printf` (M127/M129)
- `lib/config_defaults.sh` — removed duplicate `BUILD_FIX_REPORT_FILE`, added clamp
- `lib/init_report_banner.sh` — extracted post-init helpers
- `lib/init_report_banner_next.sh` (NEW) — extracted helpers
- `prompts/draft_milestones.prompt.md` — removed dead IF block
- `stages/coder.sh` — removed vestigial `BUILD_GATE_RETRY` block + comment
- `stages/coder_buildfix.sh` — explicit unknown-token warn arm
- `tools/tui_render_timings.py` — corrected column-config comment
- `tests/build_fix_loop_fixtures.sh` — pass-through stub fix
- `tests/resilience_arc_fixtures.sh` — JSON-escape helper applied
- `tests/test_ensure_gitignore_entries.sh` — corrected stale 18→20 comment
- `tests/test_milestone_split_path_traversal.sh` — `echo`→`printf` ripple
- `tests/test_output_format.sh` — reduced to 204 lines (split)
- `tests/test_report.sh` — reduced to 182 lines (split)
- `tests/output_format_fixtures.sh` (NEW) — extracted helpers
- `tests/report_fixtures.sh` (NEW) — extracted helpers
- `tests/test_output_format_json.sh` (NEW) — focused JSON test
- `tests/test_report_color.sh` (NEW) — focused color test
- `CLAUDE.md` — registered the new
  `lib/diagnose_rules_resilience_preflight.sh` in the Repository Layout map

## Human Notes Status
- One human note in HUMAN_NOTES.md was the user-supplied task itself; no
  additional notes to claim/resolve.

## Docs Updated
- `CLAUDE.md` Repository Layout — added `diagnose_rules_resilience_preflight.sh`
  entry under `lib/`.
