# V4 Environment Contract

The Tekhton pipeline crosses a bash ↔ Go seam every time the Go runner
launches a stage subprocess via `internal/stagerunner.BashAdapter`. That
boundary exports a fixed set of contract variables — the union of
`StageEnvV1` runtime fields (hand-emitted in
`internal/runner/env.go::AsKV`) and every pipeline.conf key declared in
`internal/config/defaults.go::baseDefaults`. Bash files in `lib/` and
`stages/` may read any of these variables, but they must do so safely:
the stage subprocess runs under `set -euo pipefail`, so a bare
`${VAR}` read of an unset variable aborts the wrapper before the stage
entry point runs.

This document is the one-page reference for that contract. It exists so
operators adding a new bash file or extending an existing one know:

1. **Which variables are part of the contract** (the table at the bottom).
2. **What rule applies at every read site** (the next section).
3. **Which automated checks enforce the rule** (CI gates section).

> **Header note — regenerate when the contract changes.** The table below
> is a manual snapshot taken at `make build && tekhton config defaults
> --emit shell` time. A future milestone may automate regeneration from
> `internal/proto/agent_v1.go` + `internal/config/defaults.go`. For now,
> if you add or rename a default in `internal/config/defaults.go`,
> regenerate the table block manually:
>
> ```bash
> mkdir -p /tmp/envdoc && \
> ./bin/tekhton config defaults --emit shell --project-dir /tmp/envdoc \
>   | sed -E "s|$PWD|<PROJECT_DIR>|g; s|/tmp/envdoc|<PROJECT_DIR>|g" \
>   | sed -nE "s/^export ([A-Z_][A-Z0-9_]*)='([^']*)'\$/| \`\1\` | \`\2\` |/p"
> ```

## Producer side

The contract is emitted by the Go runner once per pipeline attempt:

| Source | What it provides |
|--------|------------------|
| `internal/runner/env.go::EnvBuilder.AsKV` | The 11 runtime-only fields of `StageEnvV1` (`MILESTONE_MODE`, `_CURRENT_MILESTONE`, `TASK`, `AUTO_ADVANCE`, `AUTO_ADVANCE_LIMIT`, `HUMAN_MODE`, `HUMAN_NOTES_TAG`, `LOG_DIR`, `TIMESTAMP`, `LOG_FILE`, `TEKHTON_SESSION_DIR`). These are computed per-run, never read from pipeline.conf. |
| `internal/config/defaults.go::baseDefaults` | Every pipeline.conf default. Loaded by `internal/config.Load` and folded into the same env block applied uniformly to every stage in `internal/runner/single.go::defaultStageOrder`. |

Both sources flow through `stagerunner.BashAdapter::buildEnv`, which
adds `TEKHTON_STAGE_REQUEST_FILE` / `_RESULT_FILE` / `_LOG_FILE` /
`_NAME` and any per-request `EnvOverrides`, then exec's the bash
wrapper that sources `lib/*.sh` and `stages/*.sh`.

## Consumer rule

**Every bash read of a contract variable MUST use the
`${VAR:-DEFAULT}` form.** This is the only form that survives
`set -u` regardless of which subset of the contract the runner
populates in a given call path.

Equivalent guards `${VAR-DEFAULT}`, `${VAR:+…}`, `${VAR+…}`,
`${VAR:=…}`, `${VAR:?…}`, `${VAR?…}` are all acceptable; the
audit script accepts them too. The forbidden form is bare `${VAR}` or
bare `$VAR` at any read site, including inside function bodies and
inside command substitutions.

Why `:-DEFAULT` and not just `:-` (empty): the canonical default is
the value the Go side would have written, so reads at the bash boundary
match what `pipeline.conf` would produce. Setting it to empty when the
real default is e.g. `.tekhton` silently changes program behavior. The
audit script does not enforce *which* default you supply — only that
*some* guard is present — so use the canonical value from the table.

See `MILESTONE_TEMPLATE.md` "Watch For" guidance for the form to use
when writing new milestones that add bash files.

## CI gates that enforce the rule

| Gate | Where it runs | What it catches |
|------|---------------|-----------------|
| `scripts/audit-bash-env.sh` | `make dogfood` (m27.1 + m27.3) | Static grep for unguarded `${VAR}` / `$VAR` reads of any contract variable in `lib/` and `stages/`. Fast (~1s), per-file:line output. |
| `tests/test_stage_env_setu.sh` | `make dogfood` (m27.3) | Live execution of every stage in `defaultStageOrder` under `set -euo pipefail`; fails on any `unbound variable` trip. Catches dynamically-named reads, runtime sourcing, and `eval` sites the static audit cannot resolve. |
| `scripts/wedge-audit.sh` | `make dogfood` (m04 + m27.3) | Asserts the two gates above still exist and are wired from `Makefile`. Catches a future cleanup pass that accidentally removes the env-contract gate itself. |

A new bash file in `lib/` or `stages/` that lands an unguarded read
trips the static audit at PR time, well before the live parity test
needs to fire.

## Contract variables (snapshot)

The table below is the union of the StageEnvV1 hand-emitted fields and
every pipeline.conf default. `<PROJECT_DIR>` is the placeholder for the
caller's `PROJECT_DIR` resolution (the Go side substitutes the
absolute path at emit time).

| Variable | Contract default |
|----------|------------------|
| `ACTION_ITEMS_CRITICAL_THRESHOLD` | `10` |
| `ACTION_ITEMS_WARN_THRESHOLD` | `5` |
| `AGENT_ACTIVITY_TIMEOUT` | `1800` |
| `AGENT_NULL_RUN_THRESHOLD` | `2` |
| `AGENT_SKIP_PERMISSIONS` | `false` |
| `ANALYZE_ERROR_PATTERN` | `error` |
| `ARCHITECTURE_FILE` | `ARCHITECTURE.md` |
| `ARCHITECTURE_LOG_FILE` | `.tekhton/ARCHITECTURE_LOG.md` |
| `ARCHITECT_MAX_TURNS` | `25` |
| `ARCHITECT_PLAN_FILE` | `.tekhton/ARCHITECT_PLAN.md` |
| `ARCHITECT_ROLE_FILE` | `.claude/agents/architect.md` |
| `ARTIFACT_ARCHIVE_DIR` | `.claude/archived-ai-config` |
| `ARTIFACT_DETECTION_ENABLED` | `true` |
| `ARTIFACT_HANDLING_DEFAULT` | `` |
| `ARTIFACT_MERGE_MAX_TURNS` | `10` |
| `ARTIFACT_MERGE_MODEL` | `claude-sonnet-4-6` |
| `AUTONOMOUS_PROGRESS_CHECK` | `true` |
| `AUTONOMOUS_TIMEOUT` | `14400` |
| `AUTO_ADVANCE_CONFIRM` | `true` |
| `AUTO_ADVANCE_ENABLED` | `false` |
| `AUTO_ADVANCE_LIMIT` | `3` |
| `AUTO_COMMIT` | `false` |
| `BUG_TURN_MULTIPLIER` | `1.0` |
| `BUILD_CHECK_CMD` | `bash -n tekhton.sh && for f in lib/*.sh stages/*.sh; do bash -n \"\$f\"; done` |
| `BUILD_ERRORS_FILE` | `.tekhton/BUILD_ERRORS.md` |
| `BUILD_ERROR_PATTERN` | `error` |
| `BUILD_FIX_BASE_TURN_DIVISOR` | `3` |
| `BUILD_FIX_CLASSIFICATION_REQUIRED` | `true` |
| `BUILD_FIX_ENABLED` | `true` |
| `BUILD_FIX_MAX_ATTEMPTS` | `3` |
| `BUILD_FIX_MAX_TURN_MULTIPLIER` | `100` |
| `BUILD_FIX_REPORT_FILE` | `.tekhton/BUILD_FIX_REPORT.md` |
| `BUILD_FIX_REQUIRE_PROGRESS` | `true` |
| `BUILD_FIX_TOTAL_TURN_CAP` | `120` |
| `BUILD_GATE_ANALYZE_TIMEOUT` | `300` |
| `BUILD_GATE_COMPILE_TIMEOUT` | `120` |
| `BUILD_GATE_CONSTRAINT_TIMEOUT` | `60` |
| `BUILD_GATE_TIMEOUT` | `600` |
| `BUILD_RAW_ERRORS_FILE` | `.tekhton/BUILD_RAW_ERRORS.txt` |
| `BUILD_ROUTING_DIAGNOSIS_FILE` | `.tekhton/BUILD_ROUTING_DIAGNOSIS.md` |
| `CAUSAL_LOG_ENABLED` | `true` |
| `CAUSAL_LOG_FILE` | `<PROJECT_DIR>/.claude/logs/CAUSAL_LOG.jsonl` |
| `CAUSAL_LOG_MAX_EVENTS` | `2000` |
| `CAUSAL_LOG_RETENTION_RUNS` | `50` |
| `CHANGELOG_ENABLED` | `true` |
| `CHANGELOG_FILE` | `CHANGELOG.md` |
| `CHANGELOG_FORMAT` | `keep-a-changelog` |
| `CHANGELOG_INIT_IF_MISSING` | `true` |
| `CHARS_PER_TOKEN` | `4` |
| `CHECKPOINT_ENABLED` | `true` |
| `CHECKPOINT_FILE` | `.claude/CHECKPOINT_META.json` |
| `CLARIFICATIONS_FILE` | `.tekhton/CLARIFICATIONS.md` |
| `CLARIFICATION_ENABLED` | `true` |
| `CLAUDE_ARCHITECT_MODEL` | `claude-sonnet-4-6` |
| `CLAUDE_CODER_MODEL` | `claude-opus-4-7` |
| `CLAUDE_INTAKE_MODEL` | `claude-sonnet-4-6` |
| `CLAUDE_JR_CODER_MODEL` | `claude-sonnet-4-6` |
| `CLAUDE_QUOTA_CHECK_CMD` | `` |
| `CLAUDE_REVIEWER_MODEL` | `claude-sonnet-4-6` |
| `CLAUDE_SCOUT_MODEL` | `claude-sonnet-4-6` |
| `CLAUDE_SECURITY_MODEL` | `claude-sonnet-4-6` |
| `CLAUDE_STANDARD_MODEL` | `claude-sonnet-4-6` |
| `CLAUDE_TESTER_MODEL` | `claude-sonnet-4-6` |
| `CLEANUP_BATCH_SIZE` | `5` |
| `CLEANUP_ENABLED` | `true` |
| `CLEANUP_MAX_TURNS` | `15` |
| `CLEANUP_REPORT_FILE` | `.tekhton/CLEANUP_REPORT.md` |
| `CLEANUP_TRIGGER_THRESHOLD` | `5` |
| `CODER_MAX_TURNS` | `200` |
| `CODER_MAX_TURNS_CAP` | `200` |
| `CODER_MIN_TURNS` | `60` |
| `CODER_ROLE_FILE` | `.claude/agents/coder.md` |
| `CODER_SUMMARY_FILE` | `.tekhton/CODER_SUMMARY.md` |
| `CODER_TDD_TURN_MULTIPLIER` | `1.2` |
| `COMPLETE_MODE_ENABLED` | `true` |
| `COMPLETION_GATE_TEST_ENABLED` | `true` |
| `CONTEXT_BUDGET_ENABLED` | `true` |
| `CONTEXT_BUDGET_PCT` | `50` |
| `CONTEXT_COMPILER_ENABLED` | `true` |
| `CONTINUATION_ENABLED` | `true` |
| `DASHBOARD_DIR` | `.claude/dashboard` |
| `DASHBOARD_ENABLED` | `true` |
| `DASHBOARD_HISTORY_DEPTH` | `50` |
| `DASHBOARD_MAX_TIMELINE_EVENTS` | `500` |
| `DASHBOARD_REFRESH_INTERVAL` | `10` |
| `DASHBOARD_VERBOSITY` | `normal` |
| `DEPENDENCY_CONSTRAINTS_FILE` | `` |
| `DESIGN_FILE` | `.tekhton/DESIGN.md` |
| `DETECT_CI_ENABLED` | `true` |
| `DETECT_INFRASTRUCTURE_ENABLED` | `true` |
| `DETECT_SERVICES_ENABLED` | `true` |
| `DETECT_TEST_FRAMEWORKS_ENABLED` | `true` |
| `DETECT_WORKSPACES_ENABLED` | `true` |
| `DIAGNOSIS_FILE` | `.tekhton/DIAGNOSIS.md` |
| `DOCS_AGENT_ENABLED` | `true` |
| `DOCS_AGENT_MAX_TURNS` | `10` |
| `DOCS_AGENT_MODEL` | `claude-haiku-4-5-20251001` |
| `DOCS_AGENT_REPORT_FILE` | `.tekhton/DOCS_AGENT_REPORT.md` |
| `DOCS_DIRS` | `docs/` |
| `DOCS_ENFORCEMENT_ENABLED` | `true` |
| `DOCS_README_FILE` | `README.md` |
| `DOCS_STRICT_MODE` | `false` |
| `DOC_QUALITY_ASSESSMENT_ENABLED` | `true` |
| `DRAFT_MILESTONES_AUTO_WRITE` | `false` |
| `DRAFT_MILESTONES_MAX_TURNS` | `40` |
| `DRAFT_MILESTONES_MODEL` | `claude-sonnet-4-6` |
| `DRAFT_MILESTONES_SEED_EXEMPLARS` | `3` |
| `DRIFT_ARCHIVE_FILE` | `.tekhton/DRIFT_ARCHIVE.md` |
| `DRIFT_LOG_FILE` | `.tekhton/DRIFT_LOG.md` |
| `DRIFT_OBSERVATION_THRESHOLD` | `8` |
| `DRIFT_RESOLVED_KEEP_COUNT` | `20` |
| `DRIFT_RUNS_SINCE_AUDIT_THRESHOLD` | `5` |
| `DRY_RUN_CACHE_DIR` | `./.claude/dry_run_cache` |
| `DRY_RUN_CACHE_TTL` | `3600` |
| `DYNAMIC_TURNS_ENABLED` | `true` |
| `EXPRESS_PERSIST_CONFIG` | `true` |
| `EXPRESS_PERSIST_ROLES` | `false` |
| `FEAT_TURN_MULTIPLIER` | `1.0` |
| `FINAL_FIX_ENABLED` | `true` |
| `FINAL_FIX_MAX_ATTEMPTS` | `2` |
| `FINAL_FIX_MAX_TURNS` | `26` |
| `FIX_DRIFT_MAX_PASSES` | `3` |
| `FIX_NONBLOCKERS_MAX_PASSES` | `3` |
| `GLOSSARY_FILE` | `` |
| `HEALTH_BASELINE_FILE` | `.claude/HEALTH_BASELINE.json` |
| `HEALTH_ENABLED` | `true` |
| `HEALTH_REASSESS_ON_COMPLETE` | `false` |
| `HEALTH_REPORT_FILE` | `.tekhton/HEALTH_REPORT.md` |
| `HEALTH_RUN_TESTS` | `false` |
| `HEALTH_SAMPLE_SIZE` | `20` |
| `HEALTH_SHOW_BELT` | `true` |
| `HEALTH_WEIGHT_DEPS` | `15` |
| `HEALTH_WEIGHT_DOCS` | `15` |
| `HEALTH_WEIGHT_HYGIENE` | `15` |
| `HEALTH_WEIGHT_QUALITY` | `25` |
| `HEALTH_WEIGHT_TESTS` | `30` |
| `HUMAN_ACTION_FILE` | `.tekhton/HUMAN_ACTION_REQUIRED.md` |
| `HUMAN_NOTES_CRITICAL_THRESHOLD` | `20` |
| `HUMAN_NOTES_FILE` | `.tekhton/HUMAN_NOTES.md` |
| `HUMAN_NOTES_PROMOTE_MODE` | `confirm` |
| `HUMAN_NOTES_PROMOTE_THRESHOLD` | `20` |
| `HUMAN_NOTES_TRIAGE_ENABLED` | `true` |
| `HUMAN_NOTES_TRIAGE_MODEL` | `haiku` |
| `HUMAN_NOTES_WARN_THRESHOLD` | `10` |
| `INDEXER_STARTUP_AUDIT` | `true` |
| `INIT_AUTO_PROMPT` | `false` |
| `INLINE_CONTRACT_PATTERN` | `` |
| `INLINE_CONTRACT_SEARCH_CMD` | `` |
| `INTAKE_AGENT_ENABLED` | `true` |
| `INTAKE_AUTO_SPLIT` | `false` |
| `INTAKE_CLARITY_THRESHOLD` | `40` |
| `INTAKE_CONFIRM_TWEAKS` | `false` |
| `INTAKE_MAX_TURNS` | `10` |
| `INTAKE_REPORT_FILE` | `.tekhton/INTAKE_REPORT.md` |
| `INTAKE_ROLE_FILE` | `.claude/agents/intake.md` |
| `INTAKE_TWEAK_THRESHOLD` | `70` |
| `JR_CODER_MAX_TURNS` | `65` |
| `JR_CODER_ROLE_FILE` | `.claude/agents/jr-coder.md` |
| `JR_CODER_SUMMARY_FILE` | `.tekhton/JR_CODER_SUMMARY.md` |
| `LOG_DIR` | `<PROJECT_DIR>/.claude/logs` |
| `MAX_AUTONOMOUS_AGENT_CALLS` | `200` |
| `MAX_CONTINUATION_ATTEMPTS` | `3` |
| `MAX_PIPELINE_ATTEMPTS` | `5` |
| `MAX_REVIEW_CYCLES` | `6` |
| `MAX_TRANSIENT_RETRIES` | `3` |
| `MERGE_CONTEXT_FILE` | `.tekhton/MERGE_CONTEXT.md` |
| `METRICS_ADAPTIVE_TURNS` | `true` |
| `METRICS_ENABLED` | `true` |
| `METRICS_MIN_RUNS` | `5` |
| `MIGRATION_AUTO` | `true` |
| `MIGRATION_BACKUP_DIR` | `.claude/migration-backups` |
| `MILESTONE_ACTIVITY_TIMEOUT_MULTIPLIER` | `3` |
| `MILESTONE_ARCHITECT_MAX_TURNS` | `50` |
| `MILESTONE_AUTO_MIGRATE` | `true` |
| `MILESTONE_AUTO_RETRY` | `true` |
| `MILESTONE_CODER_MAX_TURNS` | `200` |
| `MILESTONE_DAG_ENABLED` | `true` |
| `MILESTONE_DIR` | `<PROJECT_DIR>/.claude/milestones` |
| `MILESTONE_JR_CODER_MAX_TURNS` | `65` |
| `MILESTONE_MANIFEST` | `MANIFEST.cfg` |
| `MILESTONE_MAX_REVIEW_CYCLES` | `6` |
| `MILESTONE_MAX_SPLIT_DEPTH` | `6` |
| `MILESTONE_REVIEWER_MAX_TURNS` | `60` |
| `MILESTONE_SECURITY_MAX_TURNS` | `30` |
| `MILESTONE_SPLIT_ENABLED` | `true` |
| `MILESTONE_SPLIT_MAX_TURNS` | `15` |
| `MILESTONE_SPLIT_MODEL` | `claude-opus-4-7` |
| `MILESTONE_SPLIT_THRESHOLD_PCT` | `120` |
| `MILESTONE_TAG_ON_COMPLETE` | `false` |
| `MILESTONE_TESTER_MAX_TURNS` | `120` |
| `MILESTONE_TESTER_MODEL` | `claude-sonnet-4-6` |
| `MILESTONE_WINDOW_MAX_CHARS` | `20000` |
| `MILESTONE_WINDOW_PCT` | `30` |
| `NON_BLOCKING_INJECTION_THRESHOLD` | `8` |
| `NON_BLOCKING_LOG_FILE` | `.tekhton/NON_BLOCKING_LOG.md` |
| `NOTES_FILTER_CATEGORIES` | `BUG|FEAT|POLISH` |
| `PIPELINE_ORDER` | `standard` |
| `PIPELINE_STATE_FILE` | `<PROJECT_DIR>/.claude/PIPELINE_STATE.md` |
| `POLISH_LOGIC_FILE_PATTERNS` | `*.py *.js *.ts *.sh *.go *.rs *.java *.rb *.c *.cpp *.h` |
| `POLISH_SKIP_REVIEW` | `true` |
| `POLISH_SKIP_REVIEW_PATTERNS` | `*.css *.scss *.less *.json *.yaml *.yml *.toml *.cfg *.ini *.svg *.png *.md` |
| `POLISH_TURN_MULTIPLIER` | `0.6` |
| `PREFLIGHT_AUTO_FIX` | `true` |
| `PREFLIGHT_BAK_RETAIN_COUNT` | `5` |
| `PREFLIGHT_ENABLED` | `true` |
| `PREFLIGHT_ERRORS_FILE` | `.tekhton/PREFLIGHT_ERRORS.md` |
| `PREFLIGHT_FAIL_ON_WARN` | `false` |
| `PREFLIGHT_FIX_ENABLED` | `true` |
| `PREFLIGHT_FIX_MAX_ATTEMPTS` | `2` |
| `PREFLIGHT_FIX_MAX_TURNS` | `35` |
| `PREFLIGHT_FIX_MODEL` | `claude-sonnet-4-6` |
| `PREFLIGHT_REPORT_FILE` | `.tekhton/PREFLIGHT_REPORT.md` |
| `PREFLIGHT_UI_CONFIG_AUDIT_ENABLED` | `true` |
| `PREFLIGHT_UI_CONFIG_AUTO_FIX` | `true` |
| `PRE_RUN_CLEAN_ENABLED` | `true` |
| `PRE_RUN_FIX_MAX_ATTEMPTS` | `1` |
| `PRE_RUN_FIX_MAX_TURNS` | `20` |
| `PROJECT_DESCRIPTION` | `multi-agent development pipeline — self-build (V3 brownfield)` |
| `PROJECT_INDEX_BUDGET` | `120000` |
| `PROJECT_INDEX_FILE` | `.tekhton/PROJECT_INDEX.md` |
| `PROJECT_RULES_FILE` | `CLAUDE.md` |
| `PROJECT_STRUCTURE` | `single` |
| `PROJECT_VERSION_AUTO_DETECT` | `true` |
| `PROJECT_VERSION_CONFIG` | `.claude/project_version.cfg` |
| `PROJECT_VERSION_DEFAULT_BUMP` | `patch` |
| `PROJECT_VERSION_ENABLED` | `true` |
| `PROJECT_VERSION_STRATEGY` | `milestone` |
| `PROJECT_VERSION_TAG_ON_BUMP` | `false` |
| `QUOTA_MAX_PAUSE_DURATION` | `18900` |
| `QUOTA_PROBE_MAX_INTERVAL` | `1800` |
| `QUOTA_PROBE_MIN_INTERVAL` | `600` |
| `QUOTA_RESERVE_PCT` | `10` |
| `QUOTA_RETRY_INTERVAL` | `300` |
| `QUOTA_SLEEP_CHUNK` | `5` |
| `REPLAN_DELTA_FILE` | `.tekhton/REPLAN_DELTA.md` |
| `REPLAN_ENABLED` | `true` |
| `REPLAN_MAX_TURNS` | `50` |
| `REPLAN_MODEL` | `opus` |
| `REPO_MAP_CACHE_DIR` | `.claude/index` |
| `REPO_MAP_ENABLED` | `true` |
| `REPO_MAP_HISTORY_ENABLED` | `true` |
| `REPO_MAP_HISTORY_MAX_RECORDS` | `200` |
| `REPO_MAP_LANGUAGES` | `bash,python,go` |
| `REPO_MAP_TOKEN_BUDGET` | `2048` |
| `REPO_MAP_VENV_DIR` | `.claude/indexer-venv` |
| `REQUIRED_TOOLS` | `claude git bash go` |
| `REVIEWER_MAX_TURNS` | `60` |
| `REVIEWER_MAX_TURNS_CAP` | `60` |
| `REVIEWER_MIN_TURNS` | `20` |
| `REVIEWER_REPORT_FILE` | `.tekhton/REVIEWER_REPORT.md` |
| `REVIEWER_ROLE_FILE` | `.claude/agents/reviewer.md` |
| `REVIEW_SKIP_THRESHOLD` | `0` |
| `REWORK_TURN_ESCALATION_ENABLED` | `true` |
| `REWORK_TURN_ESCALATION_FACTOR` | `1.5` |
| `REWORK_TURN_MAX_CAP` | `200` |
| `RUN_MEMORY_MAX_ENTRIES` | `50` |
| `SCOUT_MAX_TURNS` | `30` |
| `SCOUT_ON_BUG` | `always` |
| `SCOUT_ON_FEAT` | `auto` |
| `SCOUT_ON_POLISH` | `never` |
| `SCOUT_REPORT_FILE` | `.tekhton/SCOUT_REPORT.md` |
| `SCOUT_REPO_MAP_TOOLS_ONLY` | `true` |
| `SECURITY_AGENT_ENABLED` | `true` |
| `SECURITY_BLOCK_SEVERITY` | `HIGH` |
| `SECURITY_MAX_REWORK_CYCLES` | `2` |
| `SECURITY_MAX_TURNS` | `15` |
| `SECURITY_MAX_TURNS_CAP` | `30` |
| `SECURITY_MIN_TURNS` | `8` |
| `SECURITY_NOTES_FILE` | `.tekhton/SECURITY_NOTES.md` |
| `SECURITY_OFFLINE_MODE` | `auto` |
| `SECURITY_ONLINE_SOURCES` | `` |
| `SECURITY_REPORT_FILE` | `.tekhton/SECURITY_REPORT.md` |
| `SECURITY_ROLE_FILE` | `.claude/agents/security.md` |
| `SECURITY_UNFIXABLE_POLICY` | `escalate` |
| `SECURITY_WAIVER_FILE` | `` |
| `SEED_CONTRACTS_ENABLED` | `false` |
| `SEED_CONTRACTS_MAX_TURNS` | `30` |
| `SERENA_CONFIG_PATH` | `` |
| `SERENA_ENABLED` | `true` |
| `SERENA_LANGUAGE_SERVERS` | `pylsp,gopls,bash-language-server` |
| `SERENA_MAX_RETRIES` | `2` |
| `SERENA_PATH` | `.claude/serena` |
| `SERENA_STARTUP_TIMEOUT` | `30` |
| `SPECIALIST_API_ENABLED` | `false` |
| `SPECIALIST_API_MAX_TURNS` | `8` |
| `SPECIALIST_API_MODEL` | `claude-sonnet-4-6` |
| `SPECIALIST_PERFORMANCE_ENABLED` | `false` |
| `SPECIALIST_PERFORMANCE_MAX_TURNS` | `8` |
| `SPECIALIST_PERFORMANCE_MODEL` | `claude-sonnet-4-6` |
| `SPECIALIST_REPORT_FILE` | `.tekhton/SPECIALIST_REPORT.md` |
| `SPECIALIST_SECURITY_ENABLED` | `false` |
| `SPECIALIST_SECURITY_MAX_TURNS` | `8` |
| `SPECIALIST_SECURITY_MODEL` | `claude-sonnet-4-6` |
| `SPECIALIST_SKIP_IRRELEVANT` | `true` |
| `SPECIALIST_UI_ENABLED` | `auto` |
| `SPECIALIST_UI_MAX_TURNS` | `8` |
| `SPECIALIST_UI_MODEL` | `claude-sonnet-4-6` |
| `TDD_PREFLIGHT_FILE` | `.tekhton/TESTER_PREFLIGHT.md` |
| `TEKHTON_CI_ENVIRONMENT_DETECTED` | `0` |
| `TEKHTON_CONFIG_VERSION` | `3.72` |
| `TEKHTON_DIR` | `.tekhton` |
| `TEKHTON_EXPRESS_ENABLED` | `true` |
| `TEKHTON_PIN_VERSION` | `` |
| `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` | `0` |
| `TEKHTON_UPDATE_CHECK` | `true` |
| `TESTER_FIX_ENABLED` | `false` |
| `TESTER_FIX_MAX_DEPTH` | `1` |
| `TESTER_FIX_MAX_TURNS` | `26` |
| `TESTER_FIX_OUTPUT_LIMIT` | `4000` |
| `TESTER_MAX_TURNS` | `120` |
| `TESTER_MAX_TURNS_CAP` | `120` |
| `TESTER_MIN_TURNS` | `30` |
| `TESTER_REPORT_FILE` | `.tekhton/TESTER_REPORT.md` |
| `TESTER_ROLE_FILE` | `.claude/agents/tester.md` |
| `TESTER_WRITE_FAILING_MAX_TURNS` | `15` |
| `TEST_AUDIT_ENABLED` | `true` |
| `TEST_AUDIT_HISTORY_MAX_RECORDS` | `500` |
| `TEST_AUDIT_MAX_REWORK_CYCLES` | `1` |
| `TEST_AUDIT_MAX_TURNS` | `15` |
| `TEST_AUDIT_ORPHAN_DETECTION` | `true` |
| `TEST_AUDIT_REPORT_FILE` | `.tekhton/TEST_AUDIT_REPORT.md` |
| `TEST_AUDIT_ROLLING_ENABLED` | `true` |
| `TEST_AUDIT_ROLLING_SAMPLE_K` | `3` |
| `TEST_AUDIT_SYMBOL_MAP_ENABLED` | `true` |
| `TEST_AUDIT_WEAKENING_DETECTION` | `true` |
| `TEST_BASELINE_ENABLED` | `true` |
| `TEST_BASELINE_PASS_ON_PREEXISTING` | `false` |
| `TEST_BASELINE_PASS_ON_STUCK` | `false` |
| `TEST_BASELINE_STUCK_THRESHOLD` | `2` |
| `TEST_CMD` | `bash tests/run_tests.sh` |
| `TEST_DEDUP_ENABLED` | `true` |
| `TEST_FIX_FOCUS_ENABLED` | `true` |
| `TRANSIENT_RETRY_BASE_DELAY` | `30` |
| `TRANSIENT_RETRY_ENABLED` | `true` |
| `TRANSIENT_RETRY_MAX_DELAY` | `120` |
| `TUI_COMPLETE_HOLD_TIMEOUT` | `120` |
| `TUI_ENABLED` | `true` |
| `TUI_EVENT_LINES` | `60` |
| `TUI_LIFECYCLE_V2` | `true` |
| `TUI_SIMPLE_LOGO` | `false` |
| `TUI_TICK_MS` | `500` |
| `TUI_VENV_DIR` | `.claude/indexer-venv` |
| `TUI_WATCHDOG_TIMEOUT` | `300` |
| `UI_FRAMEWORK` | `` |
| `UI_GATE_ENV_RETRY_ENABLED` | `true` |
| `UI_GATE_ENV_RETRY_TIMEOUT_FACTOR` | `0.5` |
| `UI_PLATFORM` | `auto` |
| `UI_PROJECT_DETECTED` | `false` |
| `UI_SERVER_STARTUP_TIMEOUT` | `30` |
| `UI_SERVE_CMD` | `` |
| `UI_SERVE_PORT` | `3000` |
| `UI_TEST_CMD` | `` |
| `UI_TEST_ERRORS_FILE` | `.tekhton/UI_TEST_ERRORS.md` |
| `UI_TEST_TIMEOUT` | `120` |
| `UI_VALIDATION_CONSOLE_SEVERITY` | `error` |
| `UI_VALIDATION_ENABLED` | `true` |
| `UI_VALIDATION_FLICKER_THRESHOLD` | `0.05` |
| `UI_VALIDATION_REPORT_FILE` | `.tekhton/UI_VALIDATION_REPORT.md` |
| `UI_VALIDATION_RETRY` | `true` |
| `UI_VALIDATION_SCREENSHOTS` | `true` |
| `UI_VALIDATION_TIMEOUT` | `30` |
| `UI_VALIDATION_VIEWPORTS` | `1280x800,375x812` |
| `USAGE_THRESHOLD_PCT` | `0` |
| `VERBOSE_OUTPUT` | `false` |
| `WATCHTOWER_SELF_TEST` | `true` |
| `WORKSPACE_ENUM_LIMIT` | `50` |

### StageEnvV1 runtime fields (not in the pipeline.conf defaults block)

These 11 fields are computed per-run by `internal/runner/env.go::EnvBuilder.Compose`
and `AsKV` and are never read from pipeline.conf. Listed here for
completeness — they are part of the same contract bash files must guard
against:

| Variable | Source |
|----------|--------|
| `MILESTONE_MODE` | `EnvBuilder.Compose` (`true` when `--milestone` flag is set) |
| `_CURRENT_MILESTONE` | `EnvBuilder.Compose` (milestone id from `--milestone`) |
| `TASK` | `RunRequestV1.Task` |
| `AUTO_ADVANCE` | `RunRequestV1.AutoAdvance` |
| `AUTO_ADVANCE_LIMIT` | `RunRequestV1.AutoAdvanceLimit` |
| `HUMAN_MODE` | `EnvBuilder.Compose` (`true` for `--human` / `RunModeHuman`) |
| `HUMAN_NOTES_TAG` | `RunRequestV1.HumanTag` |
| `LOG_DIR` | `LogContext.LogDir` (per-attempt) |
| `TIMESTAMP` | `LogContext.Timestamp` (per-attempt) |
| `LOG_FILE` | `LogContext.LogFile` (per-attempt) |
| `TEKHTON_SESSION_DIR` | `LogContext.SessionDir` (per-attempt) |

## Notes on doc maintenance

- The snapshot above was generated at the close of m27.3 (`VERSION` 4.27.0).
- Subsequent milestones that add a key to `internal/config/defaults.go` should
  regenerate the table block; the rest of the doc is stable.
- The placeholder `<PROJECT_DIR>` stands in for the caller's resolved
  project directory. Tools that read this doc programmatically should
  treat that token as the substitution point, not the literal string.
