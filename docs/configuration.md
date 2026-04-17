# Configuration

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.

Edit `.claude/pipeline.conf` in your project. A minimal config:

```bash
PROJECT_NAME="My App"
ANALYZE_CMD="cargo clippy -- -D warnings"
TEST_CMD="cargo test"
BUILD_CHECK_CMD="cargo check"
```

Key configuration areas:

| Category | Key Examples | Notes |
|----------|-------------|-------|
| **Models** | `CLAUDE_CODER_MODEL`, `CLAUDE_STANDARD_MODEL`, etc. | One model per agent role |
| **Turn limits** | `CODER_MAX_TURNS=35`, `REVIEWER_MAX_TURNS=10` | Per-stage limits |
| **Dynamic turns** | `DYNAMIC_TURNS_ENABLED=true` | Scout adjusts limits based on complexity |
| **Turn bounds** | `CODER_MIN_TURNS=15`, `CODER_MAX_TURNS_CAP=200` | Clamp scout recommendations |
| **Milestone overrides** | `MILESTONE_CODER_MAX_TURNS=100` | Custom limits for `--milestone` |
| **Autonomous loop** | `MAX_PIPELINE_ATTEMPTS=5`, `AUTONOMOUS_TIMEOUT=7200` | `--complete` bounds |
| **Continuation** | `CONTINUATION_ENABLED=true`, `MAX_CONTINUATION_ATTEMPTS=3` | Turn-exhaustion resume |
| **Transient retry** | `TRANSIENT_RETRY_ENABLED=true`, `MAX_TRANSIENT_RETRIES=3` | API error recovery |
| **Milestone splitting** | `MILESTONE_SPLIT_ENABLED=true`, `MILESTONE_AUTO_RETRY=true` | Auto-decomposition |
| **Build & analysis** | `BUILD_CHECK_CMD`, `ANALYZE_CMD`, `TEST_CMD` | Your project's toolchain |
| **Drift thresholds** | `DRIFT_OBSERVATION_THRESHOLD=8` | When to trigger architect audit |
| **Agent resilience** | `AGENT_ACTIVITY_TIMEOUT=600`, `AGENT_TIMEOUT=7200` | Timeout controls |
| **Context** | `CONTEXT_BUDGET_PCT=50`, `CONTEXT_COMPILER_ENABLED=false` | Token budget management |
| **Specialists** | `SPECIALIST_SECURITY_ENABLED=false`, etc. | Opt-in focused reviews |
| **Cleanup** | `CLEANUP_ENABLED=false`, `CLEANUP_BATCH_SIZE=5` | Autonomous debt sweeps |
| **Metrics** | `METRICS_ENABLED=true`, `METRICS_ADAPTIVE_TURNS=true` | Run history & calibration |
| **Clarifications** | `CLARIFICATION_ENABLED=true` | Mid-run human Q&A |
| **Role files** | `CODER_ROLE_FILE=".claude/agents/coder.md"` | Agent persona definitions |
| **Planning** | `PLAN_INTERVIEW_MODEL="opus"` | Planning phase model/turn config |
| **Security agent** | `SECURITY_AGENT_ENABLED=true`, `SECURITY_BLOCK_SEVERITY=HIGH` | Dedicated security stage |
| **Docs agent** | `DOCS_AGENT_ENABLED=false`, `DOCS_AGENT_MODEL=claude-haiku-4-5-20251001` | Optional docs maintenance stage |
| **Intake agent** | `INTAKE_AGENT_ENABLED=true`, `INTAKE_CLARITY_THRESHOLD=40` | Task clarity/scope gate |
| **Watchtower** | `DASHBOARD_ENABLED=true`, `DASHBOARD_REFRESH_INTERVAL=10` | Browser-based dashboard |
| **Health** | `HEALTH_ENABLED=true`, `HEALTH_SHOW_BELT=true` | Project health scoring |
| **Milestone DAG** | `MILESTONE_DAG_ENABLED=true`, `MILESTONE_WINDOW_PCT=30` | File-based milestones |
| **Repo map** | `REPO_MAP_ENABLED=false`, `REPO_MAP_TOKEN_BUDGET=2048` | Tree-sitter indexing |
| **Causal log** | `CAUSAL_LOG_ENABLED=true` | Structured event logging |
| **Test baseline** | `TEST_BASELINE_ENABLED=true`, `TEST_BASELINE_PASS_ON_PREEXISTING=false` | Pre-existing failure detection + pristine-state gate. Set `PASS_ON_PREEXISTING=true` only if you genuinely cannot fix some tests — it masks failures. |
| **Pre-coder clean sweep** | `PRE_RUN_CLEAN_ENABLED=true`, `PRE_RUN_FIX_MAX_TURNS=20`, `PRE_RUN_FIX_MAX_ATTEMPTS=1` | Spawn a fix agent if tests fail before the coder runs. Set `PRE_RUN_CLEAN_ENABLED=false` for projects with intentionally failing tests. |
| **Tester fix** | `TESTER_FIX_ENABLED=false`, `FINAL_FIX_ENABLED=true`, `FINAL_FIX_MAX_ATTEMPTS=2` | Surgical fix mode on test failures |
| **Pre-flight** | `PREFLIGHT_ENABLED=true`, `PREFLIGHT_AUTO_FIX=true`, `PREFLIGHT_FAIL_ON_WARN=false` | Environment validation + auto-remediation |
| **UI specialist** | `SPECIALIST_UI_ENABLED=auto`, `UI_PLATFORM=auto` | Auto-on for UI projects; platform adapter selection |
| **Run memory** | `RUN_MEMORY_MAX_ENTRIES=50` | Cross-run JSONL learning store |
| **Pipeline order** | `PIPELINE_ORDER=standard` | `standard` or `test_first` (TDD) |

See [templates/pipeline.conf.example](../templates/pipeline.conf.example) for the full annotated reference with all options and defaults.
