# Milestone 83: Config Self-Documentation & Validation Gate
<!-- milestone-meta
id: "83"
status: "done"
-->

## Overview

Generated pipeline configs are opaque — values appear with no provenance,
placeholders go unnoticed, and misconfigured commands silently waste agent
turns. This milestone makes configs self-documenting (detection source
annotations) and adds a lightweight validation gate that catches common
misconfigurations before the first API call.

## Design Decisions

### 1. Detection source annotations in generated config

When `--init` generates pipeline.conf, annotate auto-detected values:

```bash
# Detected from: package.json scripts.test (confidence: high)
TEST_CMD="npm test"

# Detected from: .eslintrc.json + package.json scripts.lint (confidence: high)
ANALYZE_CMD="npx eslint ."

# Detected from: package.json scripts.build (confidence: medium)
BUILD_CHECK_CMD="npm run build"

# Not auto-detected — fill in manually
# PROJECT_DESCRIPTION="(fill in a one-line description)"
```

**Implementation path — `--init` flow:**

The detection engine (`detect_commands()` in `lib/detect_commands.sh`) already
returns `CMD_TYPE|CMD|SOURCE|CONFIDENCE` pipe-delimited tuples. The source
field is available but discarded at config-write time.

Modify `_emit_command_line()` in `lib/init_config_emitters.sh` to accept a
4th parameter (`source`):

```bash
# Current: _emit_command_line "$key" "$cmd" "$confidence"
# New:     _emit_command_line "$key" "$cmd" "$confidence" "$source"
_emit_command_line() {
    local key="$1" cmd="$2" conf="$3" source="${4:-}"
    # If source is non-empty, emit: "# Detected from: $source (confidence: $conf)"
    # Then emit the key=value line (existing confidence-based logic unchanged)
}
```

Thread the source field through the call chain:
- `_emit_section_essential()` in `lib/init_config_sections.sh` receives
  detected commands and passes all four fields to `_emit_command_line()`
- `generate_sectioned_config()` in `lib/init_config_emitters.sh` already
  parses the pipe-delimited output — extract the source field alongside the
  existing cmd/confidence extraction

For non-command keys (e.g., `PROJECT_NAME`, `PROJECT_DESCRIPTION`), annotate
in `_emit_section_essential()` directly:
- Keys set from detection → `# Detected from: <source>`
- Keys requiring manual input → `# Not auto-detected — fill in manually`

**Implementation path — express persist flow:**

`persist_express_config()` in `lib/express_persist.sh` currently reads
template variables from globals (`TEST_CMD`, `ANALYZE_CMD`, etc.) that
contain only the command string, not the source/confidence metadata.

The raw detection data exists in `_EXPRESS_COMMANDS` (set in
`lib/express.sh:35` from `detect_commands()`), which holds the full
`CMD_TYPE|CMD|SOURCE|CONFIDENCE` tuples. Modify `persist_express_config()` to:

1. Accept `_EXPRESS_COMMANDS` as a parameter (or read it as a global)
2. Instead of simple template substitution on `templates/express_pipeline.conf`,
   build the config file programmatically using `_emit_command_line()` —
   the same function used by `--init`
3. This avoids duplicating annotation logic and keeps the two paths consistent

Alternatively, if template substitution must be preserved: parse
`_EXPRESS_COMMANDS` in `persist_express_config()` to extract source/confidence
per command, then inject comment lines before each `{{VAR}}` substitution in
the template output.

### 2. `--validate` subcommand — config health check

New early-exit command:

```
Config validation: my-project
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✓ PROJECT_NAME set (my-project)
  ⚠ PROJECT_DESCRIPTION is placeholder — edit pipeline.conf line 14
  ✓ TEST_CMD configured (npm test)
  ✓ ANALYZE_CMD configured (npx eslint .)
  ⚠ ARCHITECTURE_FILE="ARCHITECTURE.md" — file not found on disk
  ✓ Agent role files present (4/4)
  ✓ Milestone manifest valid (8 milestones, 0 errors)
  ⚠ TEKHTON_CONFIG_VERSION absent — run tekhton --migrate --status

5 passed, 3 warnings, 0 errors
```

**Implementation:** New file `lib/validate_config.sh` (~100–150 lines).

Main function: `validate_config()`
- Returns 0 on all-pass or warnings-only, 1 on errors
- Prints structured output to stdout
- Uses `_is_utf8_terminal()` for symbol selection (`✓`/`+`, `⚠`/`!`,
  `✗`/`x`) and respects `NO_COLOR=1` (from M82's color guard)

**Checks performed:**

| # | Check | Severity | Logic |
|---|-------|----------|-------|
| 1 | `PROJECT_NAME` present and non-empty | error | `[[ -n "${PROJECT_NAME:-}" ]]` |
| 2 | `PROJECT_DESCRIPTION` not placeholder | warning | Reject patterns: `(fill in`, `TODO`, `CHANGEME`, empty |
| 3 | `TEST_CMD` not a no-op | warning | Reject: `echo`, `true`, `: `, `exit 0`, empty |
| 4 | `ANALYZE_CMD` not a no-op | warning | Same pattern as TEST_CMD |
| 5 | `ARCHITECTURE_FILE` exists on disk | warning | `[[ -f "$ARCHITECTURE_FILE" ]]` |
| 6 | `DESIGN_FILE` exists on disk (if set) | warning | `[[ -z "$DESIGN_FILE" ]] \|\| [[ -f "$DESIGN_FILE" ]]` |
| 7 | Agent role files exist | error | Check `CODER_ROLE_FILE`, `REVIEWER_ROLE_FILE`, `TESTER_ROLE_FILE`, `JR_CODER_ROLE_FILE` |
| 8 | Milestone manifest valid (if exists) | error | Delegate to `validate_manifest()` from `lib/milestone_dag_validate.sh` |
| 9 | Model names recognized | warning | Match pattern `claude-(opus\|sonnet\|haiku)-*` |
| 10 | `TEKHTON_CONFIG_VERSION` present | warning | Config version watermark check |
| 11 | No stale PIPELINE_STATE.md | warning | If exists, compare task string against last-run task |

Pure-read function. No agent invocation, no network calls, no new
dependencies.

**CLI parsing:** Add `--validate` as an early-exit command in `tekhton.sh`:

```bash
--validate)
    VALIDATE_CMD=true
    shift
    ;;
```

Early-exit block loads config (via `load_config()`), then calls
`validate_config()` and exits with its return code.

### 3. Automatic validation hint on first pipeline run

On first pipeline run, print a brief validation summary before the pipeline
starts:

```
[tekhton] Config check: 5 passed, 2 warnings (run --validate for details)
```

**First-run detection:** Check for absence of **both**:
- `${LOG_DIR}/RUN_SUMMARY.json` (default: `.claude/logs/RUN_SUMMARY.json`)
- `${CAUSAL_LOG_FILE}` (default: `.claude/logs/CAUSAL_LOG.jsonl`)

Using the config variables (not hardcoded paths) ensures this works with
custom `LOG_DIR` or `CAUSAL_LOG_FILE` settings.

**Edge case — deleted artifacts:** If a user deletes run artifacts but has a
valid config, they get the validation hint again. This is acceptable — the
check is lightweight (<100ms) and informational. It's not a gate that blocks
workflow.

**Behavior:**
- Warnings → print one-liner summary, continue pipeline
- Errors → print full `validate_config()` output, prompt
  `Continue anyway? [y/N]` (interactive) or abort (non-interactive /
  `--yes` flag)
- Runs on first run only — subsequent runs skip (artifacts exist)

**Location:** Insert in `tekhton.sh` after config loading and before pipeline
execution begins (after the preflight checks block).

### 4. Backwards compatibility

- Source annotations are bash comments — no behavior change to config parsing
- `--validate` is a new command — no existing behavior changes
- First-run hint is gated on "no prior run data" — existing projects with
  run history never see it
- No migration needed. Existing configs without annotations work identically

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| New subcommands | 1 | `--validate` (early-exit) |
| New files | 1 | `lib/validate_config.sh` |
| Modified files | ~3 | `tekhton.sh`, `lib/init_config_emitters.sh`, `lib/express_persist.sh` |
| New config vars | 0 | — |
| Tests | 2 | Validation logic, annotation rendering |
| Migration | None | Pure additive |

## Acceptance Criteria

- [ ] `tekhton --init` generates pipeline.conf with detection source
      annotations above each auto-detected key
- [ ] Annotations include source description and confidence level
- [ ] Keys with no detection source are annotated with
      "Not auto-detected — fill in manually"
- [ ] `_emit_command_line()` accepts a 4th `source` parameter and emits
      a `# Detected from:` comment when source is non-empty
- [ ] `persist_express_config()` includes source annotations in the
      persisted config (sourced from `_EXPRESS_COMMANDS` tuples)
- [ ] `tekhton --validate` prints a structured summary of config health
- [ ] Validation checks: placeholder values, no-op commands, missing files,
      model names, config version watermark, manifest validity
- [ ] `tekhton --validate` returns exit code 0 (all pass or warnings only)
      or exit code 1 (errors found)
- [ ] First pipeline run on a new project prints a one-line validation summary
- [ ] First-run detection uses `LOG_DIR` and `CAUSAL_LOG_FILE` config
      variables (not hardcoded paths)
- [ ] First-run hint does not appear on projects with existing run history
- [ ] Existing configs without annotations parse and load identically
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `shellcheck` on modified files reports zero warnings

## Dependencies

Depends on M81 (M81 establishes `_INIT_FILES_WRITTEN` tracking in init, which
this milestone's annotation system augments).

## Backwards Compatibility

Pure additive. Annotations are comments. New CLI command. First-run gate is
conditional. No migration needed.
