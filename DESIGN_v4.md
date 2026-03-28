# Tekhton 4.0 — Dev Shop in a Box: Multi-Provider, Parallel, Enterprise-Ready

## Problem Statement

Tekhton 3.0 delivered intelligent context management (milestone DAG, tree-sitter
repo maps, sliding windows), pipeline quality gates (security agent, intake/PM
agent, AI artifact detection), real-time observability (Watchtower dashboard,
causal event log, project health scoring), and significant developer experience
improvements (express mode, TDD support, dry-run, diagnostics, browser-based
planning). The pipeline is now a capable, context-aware development tool.

However, four fundamental limitations prevent Tekhton from achieving its vision
of being a complete "dev shop in a box":

**Vendor lock-in.** Tekhton is hard-wired to the `claude` CLI and Anthropic's
models. Users cannot switch to OpenAI, local Ollama models, or any other provider
without rewriting the agent invocation layer. In a market where providers change
pricing, throttle usage, and shift capabilities on a daily basis, this dependency
is a strategic liability. When Anthropic silently halved usage quotas for non-
enterprise plans, Tekhton users had no recourse — no failover, no alternative,
no visibility into the throttling.

**Sequential execution.** Despite V3's DAG infrastructure tracking parallel groups
and dependency edges, milestones still execute one at a time. A project with 10
independent milestones runs them serially, wasting wall-clock time and leaving
API quota unused between stages. The data model is parallel-ready; the execution
engine is not.

**Engineer-only interface.** Tekhton assumes its user is a software engineer
comfortable with CLI output, config files, and reading code diffs. The CLI output
is verbose but unclear — debug-level diagnostics shown as default output. A
project owner who wants to turn an idea into software cannot use Tekhton without
deep engineering knowledge. The tool builds software but doesn't help manage
software projects.

**Enterprise blind spots.** No audit trail beyond git commits. No integration
with corporate tooling (GitHub Issues, Slack, DataDog, Splunk). No identity
management. No non-functional requirement enforcement (performance budgets,
accessibility gates, SLAs). No structured logging suitable for enterprise
observability platforms. Tekhton works on a developer's laptop but not in a
corporate environment.

Tekhton 4.0 addresses all four: a **provider abstraction layer** that frees users
from vendor lock-in, a **parallel execution engine** that runs independent
milestones concurrently, a **project owner experience** that makes the user a
CEO/CTO rather than a terminal operator, and **enterprise-grade infrastructure**
(structured logging, integrations, NFR enforcement, identity stubs) that makes
Tekhton deployable in professional environments.

## Design Philosophy

1. **Provider freedom, not provider agnosticism for its own sake.** The goal is
   user choice, not abstract purity. Anthropic via `claude` CLI remains the
   optimized fast path. Other providers work through the bridge. Users can mix
   providers per stage. The system never forces a provider choice.

2. **The user is a project owner.** Tekhton's audience expands from "engineer
   who codes" to "person who ships products." Task intake accepts natural language.
   Progress reporting speaks in milestones and deliverables, not turns and tokens.
   Cost visibility and release notes are first-class outputs. Deep engineering
   knowledge is helpful but not required.

3. **Observe everything, show what matters.** Debug-level logging always runs and
   always writes to disk. The user sees clean, structured summaries. Enterprise
   tools ingest the full debug stream. Three tiers (default, verbose, debug) with
   the tier controlling user-facing output only — never suppressing what gets
   recorded.

4. **Parallel by default, serial by choice.** When the DAG permits it, milestones
   run concurrently. Serial execution is a degenerate case of parallel (one team).
   Resource budgeting, conflict detection, and shared gates are the parallel
   engine's responsibilities, not the user's.

5. **Enterprise is a spectrum.** V4 delivers "auditable in practice" — structured
   logs, immutable run records, cost tracking, identity stubs. V5 delivers formal
   certification (SOC 2, compliance frameworks). Each V4 feature is useful on a
   developer's laptop AND in a corporate environment.

6. **Tests are infrastructure.** Flaky tests are pipeline bugs, not acceptable
   noise. Every test owns its resources and cleans up deterministically. Self-test
   failures are quarantined — they flag issues without blocking unrelated pipeline
   work. Tekhton's own test suite is held to the same standard as the tests it
   writes for target projects.

7. **Backward compatible.** All V3 workflows work unchanged. New features are
   additive or opt-in. Users who run `tekhton "fix bug"` with a single Anthropic
   model see identical behavior to V3 unless they enable V4 features.

8. **Self-applicable.** Tekhton builds Tekhton. Complex features are sequenced
   later so the pipeline is more capable by the time it builds them. Each
   milestone adds value independently.

## Target User

V4 expands the target user from V3:

**Primary: The Product Builder.** A person with a product idea and basic technical
literacy (can install tools, edit config files, read a dashboard) but who does
not need to be a professional software engineer. They describe what they want,
Tekhton decomposes it into milestones, builds it, and reports progress in terms
they understand. They approve demos and release notes, not diffs.

**Secondary: The Professional Developer.** Same as V3 — experienced developers
who use Tekhton to accelerate their workflow. They benefit from parallel execution,
multi-provider support, and cost optimization. They use verbose/debug output and
fine-tune per-stage model assignments.

**Tertiary: The Enterprise Team.** Organizations deploying Tekhton as part of
their development toolchain. They need audit trails, identity integration,
structured logging for their observability stack, and NFR enforcement. They run
Tekhton in CI/CD pipelines and across multiple projects.

## Current Architecture (3.0 Baseline)

Tekhton 3.0 has five architectural layers:

1. **Entry point** (`tekhton.sh`) — argument parsing, library loading, DAG init,
   auto-migration, express mode, stage orchestration
2. **Stages** (`stages/*.sh`) — intake, architect, coder, review, tester, security,
   cleanup, plus planning stages (interview, followup, generate)
3. **Libraries** (`lib/*.sh`) — 60+ modules covering agent invocation, config,
   context budgeting, milestone DAG, sliding window, indexer orchestration,
   drift detection, diagnostics, health scoring, watchtower data layer, and more
4. **Python tools** (`tools/`) — tree-sitter repo map generator, tag cache,
   language detection, indexer setup (optional dependency)
5. **Prompt templates** (`prompts/*.prompt.md`) — `{{VAR}}` substitution with
   `{{IF:VAR}}...{{ENDIF:VAR}}` conditionals

**Key data flow:** `tekhton.sh` → `load_config()` → `load_manifest()` →
`build_milestone_window()` → stages in sequence → `run_agent()` per stage →
artifact parsing → gate checks → next stage or rework routing.

**Agent invocation** goes through `run_agent()` in `lib/agent.sh`, which calls
`claude --print -p "prompt" --model MODEL --max-turns N`. This is the single
point of coupling to the `claude` CLI that V4's provider abstraction must address.

**Context assembly** uses the context compiler (`lib/context_compiler.sh`) to
build task-scoped context with character budgets. The milestone sliding window
(`lib/milestone_window.sh`) injects only relevant milestones. The repo map
(`lib/indexer.sh` → `tools/repo_map.py`) provides ranked file signatures.

**Watchtower** (`templates/watchtower/`) is a static HTML dashboard with four
tabs (Live Run, Milestone Map, Reports, Trends) that reads JSON data files
generated by the pipeline. Auto-refreshes via polling.

**Observability** uses a causal event log (`lib/causality.sh`) writing JSONL
events, run summary JSON (`lib/finalize_summary.sh`), and stage-level metrics.
All output goes to stderr with `[tekhton]` prefixed tags at a single log level.

**Statistics (3.0):**
- 37,094 lines of shell (lib + stages + tekhton.sh)
- ~49,580 lines of tests (195 test files, 1.41:1 test-to-source ratio)
- 137+ config keys
- 37 milestones completed
- 6 agent roles (Coder, Reviewer, Tester, Jr Coder, Architect, Security)

---

## System Design: Provider Abstraction Layer (tekhton-bridge)

### Problem

Every agent invocation in Tekhton calls `claude --print -p "prompt" --model MODEL
--max-turns N` directly. This hard-codes Anthropic as the sole provider. Users
cannot use OpenAI, Ollama/HuggingFace local models, or any other provider. There
is no failover when Anthropic throttles or goes down. There is no cost tracking
per provider. There is no way to assign different providers to different stages
(e.g., cheap model for scout, expensive model for coder).

### Design

**Architecture: Bridge alongside Claude CLI (B2).**

The `tekhton-bridge` is a Python package that provides a unified agent invocation
interface for all non-Anthropic providers. For Anthropic, the `claude` CLI remains
the default path (preserving MCP, session management, permissions). The bridge
handles everything else.

```
Shell (run_agent)
    │
    ├──▶ [Anthropic] claude --print -p ... --model ... --max-turns ...
    │    (unchanged V3 path — MCP, permissions, sessions preserved)
    │
    └──▶ [Other providers] tekhton-bridge call \
             --provider openai \
             --model gpt-4o \
             --prompt-file /tmp/prompt.md \
             --max-turns 35 \
             --tools-file /tmp/tools.json \
             --output-format structured
         (bridge handles API calls, streaming, token counting, tool use)
```

**Provider adapter interface:**

Each provider implements a Python module in `tools/bridge/providers/`:

```python
class ProviderAdapter:
    """Base interface for all provider adapters."""

    def call(self, request: AgentRequest) -> AgentResponse:
        """Execute an agent call. Handles streaming internally."""
        ...

    def count_tokens(self, text: str) -> int:
        """Count tokens using provider's tokenizer."""
        ...

    def list_models(self) -> list[ModelInfo]:
        """Return available models with capabilities."""
        ...

    def supports_tool_use(self) -> bool:
        """Whether this provider supports native tool calling."""
        ...

    def supports_mcp(self) -> bool:
        """Whether this provider can connect to MCP servers."""
        ...

    def health_check(self) -> ProviderStatus:
        """Check provider availability, rate limits, quota."""
        ...
```

**Shipped adapters (V4):**
- `anthropic.py` — Direct Anthropic API adapter (for non-CLI use cases)
- `openai.py` — OpenAI API adapter (GPT-4o, GPT-4-turbo, o1, o3)
- `ollama.py` — Local Ollama adapter (any HuggingFace model)
- `openai_compat.py` — Generic OpenAI-compatible endpoint adapter (Together,
  Groq, vLLM, Azure OpenAI, etc.)

**MCP gateway for non-Anthropic providers:**

The `claude` CLI handles MCP natively for Anthropic. For other providers, the
bridge implements an MCP client that:
1. Connects to configured MCP servers (same config format as claude CLI)
2. Translates MCP tool definitions to the provider's tool calling format
3. Executes tool calls when the model requests them
4. Translates responses back to the model's expected format
5. For models without native tool use, falls back to prompt-based tool injection
   (tool definitions embedded in system prompt, tool calls parsed from output)

**Provider failover:**

```
Primary Provider (configured)
    │
    ├── Success → continue
    │
    └── Failure (rate limit / quota / outage)
            │
            ├── Retry with backoff (same provider, transient errors)
            │
            └── Failover to secondary provider
                    │
                    ├── Load pre-computed provider profile
                    ├── Apply prompt adjustments from profile
                    ├── Log degraded-provider event to audit trail
                    └── Continue with secondary
```

**Provider profiles (pre-computed calibration):**

When a user configures a fallback provider, `tekhton-bridge calibrate --provider
openai` runs a one-time calibration:
- Sends 3-5 representative prompts from Tekhton's prompt library
- Validates output structure (format markers, constraint compliance)
- Records any necessary prompt adjustments (e.g., "needs explicit JSON format
  instructions," "shorter system prompts perform better")
- Stores profile in `.claude/bridge/profiles/openai.json`
- Takes ~5 minutes, runs once per provider configuration

At failover time, the bridge loads the profile and applies adjustments
automatically. No intelligence required at failover time.

**Cost ledger:**

Every agent invocation records to `.claude/bridge/cost_ledger.jsonl`:
```json
{
  "timestamp": "2026-04-01T10:23:45Z",
  "run_id": "run_abc123",
  "stage": "coder",
  "provider": "anthropic",
  "model": "claude-opus-4-6",
  "input_tokens": 45230,
  "output_tokens": 12840,
  "cost_usd": 1.23,
  "duration_ms": 48200,
  "failover": false
}
```

Costs are calculated using provider-specific pricing tables shipped with
the bridge and updatable via `tekhton-bridge update-pricing`.

**Per-stage model assignment:**

```bash
# pipeline.conf
CLAUDE_SCOUT_MODEL=sonnet          # Cheap model for estimation
CLAUDE_CODER_MODEL=opus            # Best model for coding
CLAUDE_REVIEWER_MODEL=gpt-4o      # Cross-provider review
CLAUDE_TESTER_MODEL=ollama/llama3  # Local model for test writing
CLAUDE_SECURITY_MODEL=opus         # Best model for security
```

The bridge resolves model names to provider + model ID:
- `opus` / `sonnet` / `haiku` → Anthropic (via claude CLI)
- `gpt-4o` / `o3` → OpenAI (via bridge)
- `ollama/llama3` → Ollama (via bridge)
- `together/mixtral` → Together (via bridge, openai_compat adapter)

**Shell integration:**

`run_agent()` in `lib/agent.sh` gains a provider-routing preamble:

```bash
_resolve_provider() {
    local model="$1"
    case "$model" in
        opus*|sonnet*|haiku*|claude-*)  echo "anthropic" ;;
        gpt-*|o1*|o3*)                  echo "openai" ;;
        ollama/*)                        echo "ollama" ;;
        *)                               echo "bridge" ;;  # generic
    esac
}
```

If provider is `anthropic`, use existing `claude` CLI path. Otherwise, invoke
`tekhton-bridge call ...` with equivalent parameters.

### Config Keys

```bash
# Provider configuration
BRIDGE_ENABLED=false                    # Enable multi-provider support
BRIDGE_DEFAULT_PROVIDER=anthropic       # Default when model name is ambiguous
BRIDGE_FAILOVER_ENABLED=false           # Enable automatic provider failover
BRIDGE_FAILOVER_PROVIDER=""             # Secondary provider for failover
BRIDGE_COST_TRACKING=true               # Enable cost ledger
BRIDGE_MCP_GATEWAY=true                 # Enable MCP for non-Anthropic providers
BRIDGE_PROFILE_DIR=".claude/bridge/profiles"
BRIDGE_COST_LEDGER=".claude/bridge/cost_ledger.jsonl"

# Per-stage provider override (empty = use stage's model default)
BRIDGE_SCOUT_PROVIDER=""
BRIDGE_CODER_PROVIDER=""
BRIDGE_REVIEWER_PROVIDER=""
BRIDGE_TESTER_PROVIDER=""
BRIDGE_SECURITY_PROVIDER=""
```

### Why This Design

- **B2 (bridge alongside CLI) preserves all V3 capabilities** for Anthropic users
  with zero migration cost. The `claude` CLI handles MCP, permissions, and session
  management — capabilities we don't need to reimplement.
- **Python bridge reuses the existing optional Python dependency** (tree-sitter
  indexer). No new runtime dependency category.
- **Provider adapters are isolated modules.** Adding a new provider is one Python
  file implementing the adapter interface. Community contributions are easy.
- **Pre-computed profiles solve the failover prompt problem** without requiring
  intelligence at failover time. Calibration cost is paid once, at setup.
- **The cost ledger enables the Project Owner Experience** — cost dashboards,
  budget forecasting, and per-milestone cost reporting all consume this data.
- **MCP gateway in the bridge** ensures enterprise users get cross-repo awareness
  regardless of which provider they use.

---

## System Design: Structured Logging & Observability

### Problem

Tekhton's current logging is a single tier: every message goes to stderr with
`[tekhton]` prefix tags. Debug diagnostics, context breakdowns, and human-
readable status updates are intermixed. The output is useful for pipeline
developers (Tekhton building Tekhton) but noisy and unclear for users building
their own projects. There is no structured format suitable for enterprise
observability tools (DataDog, Splunk, Prometheus).

Example of current output (Tester stage):
```
[tekhton] [context-compiler] Extracted keywords: app,index,location,style,tk_reports
[tekhton] [context-compiler] ARCHITECTURE_CONTENT: filtered from 276 to 225 lines
[tekhton] [context] tester context breakdown:
[tekhton]     Architecture: 18475 chars (~4619 tokens)
[tekhton]     Repo Map: 8342 chars (~2086 tokens)
[tekhton]   Total: 26817 chars (~6705 tokens, 3% of 200000 window)
[tekhton] [tester-diag] Prompt: 31501 chars (~7876 tokens)
[tekhton] [tester-diag] Turn budget: 35 | Model: claude-sonnet-4-6
[tekhton] [tester-diag] Mode: FRESH (full tester prompt)
[tekhton] Invoking tester agent (max 35 turns)...
[tekhton] [Tester] Turns: 27/35 | Time: 8m8s
[tekhton] [tester-diag] Primary invocation: 27/35 turns, 8m8s, exit=0
```

This is all debug-level information shown as default. The user cannot tell at a
glance what happened or whether it succeeded.

### Design

**Three-tier logging with split output:**

```
User-facing (stderr)          Log file (always debug)        Structured (JSONL)
┌─────────────────┐          ┌──────────────────────┐       ┌─────────────────┐
│ default/verbose/ │          │ Full debug output     │       │ Machine-readable │
│ debug (flag)     │          │ .claude/logs/run.log  │       │ .claude/logs/    │
│                  │          │                       │       │ events.jsonl     │
│ Controls what    │          │ ALWAYS written        │       │                  │
│ the user SEES    │          │ regardless of flag    │       │ ALWAYS written   │
└─────────────────┘          └──────────────────────┘       └─────────────────┘
```

**Tier definitions:**

**Default** — What happened. Did it succeed. How long.
```
── Tester ──────────────────────── Stage 4/4
   Model: sonnet-4-6 | Budget: 35 turns
   Completed in 8m 8s (27 turns used)
```

**Verbose** (`--verbose` or `TEKHTON_LOG_LEVEL=verbose`) — Add context economics
and model details. For the power user.
```
── Tester ──────────────────────── Stage 4/4
   Context: 6,705 tokens (3% of window)
     Architecture: 4,619 tok | Repo Map: 2,086 tok
   Model: sonnet-4-6 | Budget: 35 turns
   Mode: fresh (full prompt, 7,876 tokens)
   Completed in 8m 8s (27/35 turns, exit 0)
```

**Debug** (`--debug` or `TEKHTON_LOG_LEVEL=debug`) — Everything. For pipeline
development.
```
[context-compiler] Extracted keywords: app,index,location,style,tk_reports
[context-compiler] ARCHITECTURE_CONTENT: filtered from 276 to 225 lines
[context] tester context breakdown:
    Architecture: 18475 chars (~4619 tokens)
    Repo Map: 8342 chars (~2086 tokens)
  Total: 26817 chars (~6705 tokens, 3% of 200000 window)
[tester-diag] Prompt: 31501 chars (~7876 tokens)
[tester-diag] Turn budget: 35 | Model: claude-sonnet-4-6
[tester-diag] Mode: FRESH (full tester prompt)
Invoking tester agent (max 35 turns)...
[Tester] Turns: 27/35 | Time: 8m8s
[tester-diag] Primary invocation: 27/35 turns, 8m8s, exit=0
```

**Implementation in `lib/common.sh`:**

```bash
# Log levels: 0=default, 1=verbose, 2=debug
declare -g _LOG_LEVEL=0
declare -g _LOG_FILE=""        # Always-written debug log
declare -g _EVENT_FILE=""      # Always-written structured JSONL

log_default() { echo "$*" >&2; _log_to_file "INFO" "$*"; }
log_verbose() { [[ $_LOG_LEVEL -ge 1 ]] && echo "$*" >&2; _log_to_file "VERBOSE" "$*"; }
log_debug()   { [[ $_LOG_LEVEL -ge 2 ]] && echo "$*" >&2; _log_to_file "DEBUG" "$*"; }

_log_to_file() {
    local level="$1"; shift
    [[ -n "$_LOG_FILE" ]] && printf '%s [%-7s] %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >> "$_LOG_FILE"
}

emit_event() {
    # Structured JSONL event for machine consumption
    local event_type="$1"; shift
    [[ -n "$_EVENT_FILE" ]] && printf '{"ts":"%s","type":"%s","data":{%s}}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event_type" "$*" >> "$_EVENT_FILE"
}
```

**Structured event format** (for DataDog/Splunk ingestion):

```json
{
  "ts": "2026-04-01T10:23:45Z",
  "type": "stage.complete",
  "run_id": "run_abc123",
  "data": {
    "stage": "tester",
    "model": "claude-sonnet-4-6",
    "turns_used": 27,
    "turns_budget": 35,
    "duration_s": 488,
    "exit_code": 0,
    "context_tokens": 6705,
    "context_pct": 3,
    "cost_usd": 0.42
  }
}
```

**Event types emitted:**
- `pipeline.start` / `pipeline.complete` / `pipeline.fail`
- `stage.start` / `stage.complete` / `stage.fail` / `stage.skip`
- `milestone.start` / `milestone.complete` / `milestone.fail`
- `agent.invoke` / `agent.complete` / `agent.failover`
- `gate.build` / `gate.acceptance` / `gate.security`
- `rework.start` / `rework.complete`
- `cost.update` (per-invocation cost record)
- `nfr.check` / `nfr.violation` (NFR framework events)

**Stage banners:**

Each stage renders a consistent default-level banner:

```bash
_stage_banner() {
    local stage="$1" num="$2" total="$3" model="$4" budget="$5"
    log_default "── ${stage} $(printf '─%.0s' {1..40}) Stage ${num}/${total}"
    log_default "   Model: ${model} | Budget: ${budget} turns"
}

_stage_complete() {
    local stage="$1" turns="$2" duration="$3" status="$4"
    if [[ "$status" == "0" ]]; then
        log_default "   Completed in ${duration} (${turns} turns used)"
    else
        log_default "   FAILED after ${duration} (${turns} turns, exit ${status})"
    fi
}
```

**Log file management:**

- Debug log: `.claude/logs/run_<RUN_ID>.log` (rotated, last 50 retained)
- Event log: `.claude/logs/run_<RUN_ID>.events.jsonl` (same retention)
- Symlinks: `.claude/logs/latest.log` → most recent run
- The causal event log (`CAUSAL_LOG.jsonl`) is superseded by the structured
  event stream — both continue to be written for backward compatibility, but
  the events.jsonl format is the canonical machine-readable output.

### Config Keys

```bash
TEKHTON_LOG_LEVEL=default              # default | verbose | debug
TEKHTON_LOG_DIR=".claude/logs"         # Directory for log files
TEKHTON_LOG_RETENTION=50               # Number of run logs to retain
TEKHTON_STRUCTURED_EVENTS=true         # Emit structured JSONL events
TEKHTON_LOG_COST_EVENTS=true           # Include cost events in JSONL
```

### Why This Design

- **Three tiers match professional CLI tools** (terraform, kubectl, docker) that
  users encounter in corporate environments. Familiar UX.
- **Debug always written to disk** means catastrophic failures are always
  diagnosable, regardless of what the user was seeing on screen.
- **Structured JSONL** is the universal format for log aggregation tools. DataDog,
  Splunk, ELK, and Loki all ingest JSONL natively. No custom parsers needed.
- **The stage banner pattern** gives every stage a consistent, scannable summary
  that tells the user what matters: what ran, what model, how long, did it pass.
- **Backward compatibility**: existing `log_info()` / `log_warn()` calls map to
  `log_default()`. No existing code breaks.

---

## System Design: Test Robustness Overhaul

### Problem

V3's self-test suite (195 files, ~50k lines) has become a source of pipeline
brittleness. The browser test for Watchtower spawned zombie processes that
consumed port space, causing multiple milestones to falsely report failure and
triggering unnecessary rework cycles. This pattern — a self-test breaking the
pipeline that depends on self-tests passing — is a systemic risk that grows worse
as the test suite grows.

Root causes:
1. **Resource leaks.** Tests that spawn background processes (HTTP servers,
   watchers, browsers) don't always clean up, especially on failure paths.
2. **Port conflicts.** Multiple tests compete for the same port ranges. Parallel
   test runs (or zombie leftovers) cause binding failures.
3. **No isolation.** Tests share the filesystem, environment variables, and
   process space. One test's side effects can break another.
4. **No flakiness detection.** A test that passes 9/10 times ships as "passing"
   until it fails at the worst possible moment.
5. **No quarantine.** A failing self-test blocks the entire pipeline even when
   the failure is unrelated to the current task.

### Design

**Test isolation framework:**

Every test that creates resources operates within a managed lifecycle:

```bash
# lib/test_harness.sh — sourced by test files

_test_setup() {
    # Create isolated temp directory per test
    TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/tekhton-test-XXXXXX")"
    # Track spawned PIDs for cleanup
    declare -g -a _TEST_PIDS=()
    # Allocate a unique port from a range (no conflicts)
    TEST_PORT="$(_allocate_port)"
    # Set trap for cleanup on ANY exit
    trap '_test_teardown' EXIT INT TERM
}

_test_teardown() {
    # Kill all tracked processes
    for pid in "${_TEST_PIDS[@]}"; do
        kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
    done
    # Release allocated port
    _release_port "$TEST_PORT"
    # Remove temp directory
    [[ -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
}

_spawn_tracked() {
    # Launch a background process and track its PID
    "$@" &
    _TEST_PIDS+=($!)
}
```

**Port allocation:**

```bash
# Deterministic port allocation from a reserved range
# Each test gets a unique port — no conflicts possible
_PORT_RANGE_START=18100
_PORT_RANGE_END=18999
_PORT_LOCK_DIR="${TMPDIR:-/tmp}/tekhton-ports"

_allocate_port() {
    mkdir -p "$_PORT_LOCK_DIR"
    for port in $(seq $_PORT_RANGE_START $_PORT_RANGE_END); do
        if mkdir "$_PORT_LOCK_DIR/$port" 2>/dev/null; then
            echo "$port"
            return 0
        fi
    done
    return 1  # No ports available
}

_release_port() {
    rmdir "$_PORT_LOCK_DIR/$1" 2>/dev/null
}
```

**Flakiness detection:**

A new test runner mode: `bash tests/run_tests.sh --flake-check N`

- Runs each test N times (default: 5)
- Any test that produces inconsistent results is flagged
- Flaky tests are recorded in `.claude/test_flakiness.json`
- Pipeline can be configured to quarantine known-flaky tests

**Test quarantine:**

```bash
# pipeline.conf
TEST_QUARANTINE_ENABLED=true           # Enable self-test quarantine
TEST_QUARANTINE_FILE=".claude/test_quarantine.json"
```

When a self-test is quarantined:
- It still runs, but its result doesn't block the pipeline
- Its failure is logged as a warning, not an error
- The quarantine entry includes: test name, reason, date quarantined, ticket/issue
- Quarantined tests are surfaced in Watchtower's Reports tab
- `tekhton --test-health` reports quarantine status

**Test categorization:**

Tests are categorized by what they exercise:

| Category | Description | Quarantine eligible? |
|----------|-------------|---------------------|
| `unit` | Pure logic, no I/O | No — must always pass |
| `integration` | File I/O, process spawning | Yes |
| `browser` | Watchtower UI tests | Yes |
| `network` | Port binding, HTTP servers | Yes |
| `e2e` | Full pipeline stages | Yes |

Categories are declared in each test file:
```bash
# test_category: integration
```

**Zombie process detection:**

Pre-test and post-test hooks detect orphaned processes:

```bash
_check_zombies() {
    local orphans
    orphans=$(pgrep -f "tekhton-test" 2>/dev/null | grep -v "$$" || true)
    if [[ -n "$orphans" ]]; then
        log_warn "Orphaned test processes detected: $orphans"
        # Optionally kill: kill $orphans
    fi
}
```

### Config Keys

```bash
TEST_QUARANTINE_ENABLED=true
TEST_QUARANTINE_FILE=".claude/test_quarantine.json"
TEST_FLAKE_CHECK_RUNS=5               # Runs per test in flake-check mode
TEST_ISOLATION_PORTS=true              # Use port allocator
TEST_ZOMBIE_CHECK=true                 # Pre/post zombie detection
TEST_PORT_RANGE_START=18100
TEST_PORT_RANGE_END=18999
```

### Why This Design

- **Isolation via temp directories + port allocation** eliminates the two most
  common failure modes (filesystem conflicts, port conflicts) without requiring
  containers or heavy infrastructure.
- **Tracked process lifecycle** ensures cleanup runs on ALL exit paths — including
  `set -e` failures, signals, and test assertion failures.
- **Quarantine** breaks the "flaky test blocks the whole pipeline" cascade without
  silently ignoring failures. Quarantined tests are visible and tracked.
- **Flakiness detection** is a one-time diagnostic, not a runtime cost. Run it
  before cutting a release, not on every pipeline invocation.
- **Category declarations** are a single comment line per test. Zero overhead for
  test authors. The runner uses `grep` to extract them.

---

## System Design: Parallel Execution Engine

### Problem

Tekhton's milestone DAG (V3) tracks dependency edges and parallel groups, but
execution is strictly serial. A project with milestones A, B, C where B and C
both depend only on A runs B, then C — even though B and C could run
simultaneously. This wastes wall-clock time and leaves API quota unused during
stage transitions.

### Design

**Milestone-level parallelism only (V4).** Each parallel team runs a complete
Coder → Reviewer → Tester pipeline for one milestone. Stage-level parallelism
(running Coder and Security concurrently within a milestone) is deferred to V5,
with one exception: Scout + Security pre-scan may run in parallel since both are
read-only analysis.

**Team model:**

```
Parallel Execution Engine (lib/parallel.sh)
    │
    ├── Team 1: Milestone B
    │   ├── git worktree: .claude/worktrees/team-1/
    │   ├── Coder → Reviewer → Tester (full pipeline)
    │   └── Merge back to main branch on success
    │
    ├── Team 2: Milestone C
    │   ├── git worktree: .claude/worktrees/team-2/
    │   ├── Coder → Reviewer → Tester (full pipeline)
    │   └── Merge back to main branch on success
    │
    └── Coordinator
        ├── DAG frontier analysis (which milestones can run now?)
        ├── Resource budgeting (how many teams can run concurrently?)
        ├── Conflict detection (do teams touch the same files?)
        ├── Shared build gate (validate merged result)
        └── Progress synchronization (wait for deps before starting)
```

**Git worktree isolation:**

Each parallel team operates in its own git worktree:

```bash
_create_team_worktree() {
    local team_id="$1" milestone_id="$2"
    local worktree_dir=".claude/worktrees/team-${team_id}"
    local branch="tekhton/parallel/${milestone_id}"

    git worktree add "$worktree_dir" -b "$branch" HEAD
    echo "$worktree_dir"
}

_merge_team_result() {
    local team_id="$1" worktree_dir="$2"
    local branch="tekhton/parallel/${_team_milestone[$team_id]}"

    # Attempt merge into main working branch
    if git merge --no-ff "$branch" -m "Merge milestone ${_team_milestone[$team_id]}"; then
        git worktree remove "$worktree_dir"
        git branch -d "$branch"
        return 0
    else
        # Merge conflict — flag for human resolution
        git merge --abort
        return 1
    fi
}
```

**Resource budgeting:**

The coordinator allocates API quota across teams:

```bash
# Total budget for this invocation
PARALLEL_MAX_TEAMS=3                    # Max concurrent teams
PARALLEL_QUOTA_STRATEGY=equal           # equal | weighted | priority

# Equal: each team gets 1/N of the budget
# Weighted: teams get budget proportional to milestone complexity (scout estimate)
# Priority: highest-priority milestone gets full budget, others get remainder
```

Quota tracking integrates with the bridge's cost ledger. When a team exhausts
its budget allocation, it pauses until other teams complete and release quota.

**Conflict detection:**

Before merging team results, the coordinator checks for file-level conflicts:

```bash
_detect_conflicts() {
    local team_a="$1" team_b="$2"
    local files_a files_b overlap

    files_a=$(git diff --name-only "HEAD...tekhton/parallel/${_team_milestone[$team_a]}")
    files_b=$(git diff --name-only "HEAD...tekhton/parallel/${_team_milestone[$team_b]}")

    overlap=$(comm -12 <(echo "$files_a" | sort) <(echo "$files_b" | sort))

    if [[ -n "$overlap" ]]; then
        echo "$overlap"
        return 1  # Conflict detected
    fi
    return 0
}
```

When conflicts are detected:
1. **Non-overlapping changes** in the same file → git auto-merge (usually works)
2. **Overlapping changes** → merge the earlier-completing team first, then re-run
   the later team's milestone with the merged base (sequential fallback)
3. **Persistent conflicts** → flag for human resolution via HUMAN_ACTION_REQUIRED.md

**Shared build gate:**

After all parallel teams in a group complete and merge, a single build gate
validates the combined result:

```bash
_parallel_group_gate() {
    local group="$1"
    # All teams in this group have merged
    # Run build gate on the merged result
    if ! run_build_gate; then
        # Identify which team's changes broke the build
        _bisect_build_failure "$group"
        return 1
    fi
    return 0
}
```

**Coordinator orchestration loop:**

```bash
run_parallel_execution() {
    while has_pending_milestones; do
        # 1. Get DAG frontier (milestones whose deps are all done)
        local frontier
        frontier=$(dag_get_frontier)

        # 2. Group frontier milestones by parallel_group
        local -A groups
        _group_frontier "$frontier" groups

        # 3. For each group, spawn teams up to PARALLEL_MAX_TEAMS
        for group in "${!groups[@]}"; do
            local milestones="${groups[$group]}"
            _spawn_teams "$milestones"
        done

        # 4. Wait for all teams in current wave to complete
        _wait_for_teams

        # 5. Merge results, run shared build gate
        _merge_and_gate

        # 6. Update manifest statuses
        _update_manifest_statuses
    done
}
```

**Progress tracking:**

Each team writes progress to its own status file:
`.claude/worktrees/team-N/TEAM_STATUS.json`

The coordinator reads these for Watchtower integration:
```json
{
  "team_id": 1,
  "milestone_id": "m05",
  "stage": "reviewer",
  "stage_num": 3,
  "stages_total": 5,
  "started_at": "2026-04-01T10:00:00Z",
  "turns_used": 12,
  "status": "running"
}
```

**Serial fallback:**

When `PARALLEL_MAX_TEAMS=1` (default for V4 initial release), the parallel
engine degenerates to serial execution — identical to V3 behavior. This ensures
backward compatibility and lets users opt in to parallelism when ready.

### Config Keys

```bash
PARALLEL_ENABLED=false                  # Enable parallel milestone execution
PARALLEL_MAX_TEAMS=3                    # Max concurrent teams
PARALLEL_QUOTA_STRATEGY=equal           # equal | weighted | priority
PARALLEL_WORKTREE_DIR=".claude/worktrees"
PARALLEL_CONFLICT_STRATEGY=sequential   # sequential | human | abort
PARALLEL_SHARED_GATE=true               # Build gate after group merge
PARALLEL_BISECT_ON_FAILURE=true         # Identify breaking team on gate fail
```

### Why This Design

- **Git worktrees** are the natural isolation mechanism — each team gets a full
  working copy without duplicating the repo. Git manages the branch lifecycle.
- **Milestone-level parallelism** is architecturally simpler than stage-level and
  higher value (running independent milestones concurrently saves more wall-clock
  time than parallelizing stages within a milestone).
- **The coordinator is shell code** — no new runtime dependencies. It spawns
  subshells, monitors status files, and merges results using git.
- **Conflict detection before merge** prevents silent corruption. The escalation
  path (auto-merge → sequential fallback → human resolution) handles progressively
  harder cases.
- **PARALLEL_MAX_TEAMS=1 as default** means zero behavior change on upgrade.
  Users explicitly opt in to parallelism.
- **V3's DAG infrastructure** (frontier detection, parallel groups, dependency
  edges) is consumed directly. No data model changes needed.

---

## System Design: Watchtower as Primary Interface

### Problem

V3's Watchtower is a static HTML dashboard that reads JSON data files and auto-
refreshes via polling. It's read-only — users observe but cannot interact. The
CLI remains the only way to submit tasks, manage milestones, or control the
pipeline. For the project-owner user who isn't a terminal power user, this means
Tekhton is effectively unusable without CLI fluency.

V3 milestones 35-37 seed the transition (smart refresh, interactive controls,
parallel team data model), but V4 must complete it: Watchtower becomes the
primary interface for most users, with the CLI as the power-user path.

### Design

**Dual-mode Watchtower:**

```
Mode 1: Static (V3 default, still supported)
    watchtower.html reads .claude/watchtower/*.json files
    Auto-refresh via polling
    Read-only

Mode 2: Served (V4 default when configured)
    tekhton --watchtower-serve  (or WATCHTOWER_SERVE_ENABLED=true)
    Python HTTP server on localhost:PORT
    WebSocket push for real-time updates
    Interactive controls (task submission, milestone management)
    REST API for external tool integration
```

**Server architecture:**

```
tools/watchtower_server.py
    │
    ├── HTTP Server (default port 8420)
    │   ├── GET /                    → Serve dashboard HTML/JS/CSS
    │   ├── GET /api/v1/runs/latest  → Current run state
    │   ├── GET /api/v1/runs/:id     → Historical run data
    │   ├── GET /api/v1/milestones   → Milestone DAG + statuses
    │   ├── GET /api/v1/costs        → Cost ledger summary
    │   ├── GET /api/v1/health       → Project health score
    │   ├── POST /api/v1/tasks       → Submit new task
    │   ├── POST /api/v1/notes       → Submit human note
    │   ├── POST /api/v1/milestones  → Create/modify milestone
    │   ├── POST /api/v1/control     → Pipeline control (pause/resume/abort)
    │   └── GET /api/v1/events/stream → SSE event stream
    │
    ├── WebSocket Server (same port, /ws)
    │   ├── Real-time run progress events
    │   ├── Stage transition notifications
    │   ├── Parallel team status updates
    │   └── Cost accumulation updates
    │
    └── File Watcher
        ├── Monitors .claude/watchtower/*.json for changes
        ├── Monitors .claude/logs/events.jsonl for new events
        └── Pushes updates via WebSocket on change
```

**Interactive controls (V4 additions to UI):**

1. **Task Submission Panel**
   - Text field for natural language task description
   - Milestone selector (run against specific milestone or auto-detect)
   - Model/provider selector (dropdown populated from bridge config)
   - "Dry Run" toggle
   - Submit button → writes to `.claude/inbox/task_<timestamp>.json`

2. **Milestone Manager**
   - Visual DAG editor (drag-drop to reorder, draw dependency edges)
   - Status overrides (mark done, skip, reset to pending)
   - Inline milestone editing (title, description, acceptance criteria)
   - Split/merge milestone controls

3. **Run Control**
   - Pause/resume current run
   - Abort with rollback option
   - Force-advance past stuck stages
   - Re-run failed stages

4. **Cost Dashboard**
   - Per-run cost breakdown (by stage, by provider, by model)
   - Cumulative project cost with trend line
   - Budget alerts (configurable thresholds)
   - Provider comparison (same task, different providers)

5. **Parallel Team View** (when parallel execution is active)
   - Team cards showing stage progress per team
   - Unified timeline with team swimlanes
   - Conflict detection alerts
   - Merge status indicators

**Inbox pattern (V3 M36 foundation):**

Watchtower writes task/note/control files to `.claude/inbox/`. The pipeline
checks the inbox at startup and between stages:

```bash
_process_inbox() {
    local inbox_dir="${PROJECT_DIR}/.claude/inbox"
    [[ -d "$inbox_dir" ]] || return 0

    for item in "$inbox_dir"/*.json; do
        [[ -f "$item" ]] || continue
        local type
        type=$(grep -o '"type":"[^"]*"' "$item" | head -1 | cut -d'"' -f4)
        case "$type" in
            task)    _enqueue_task "$item" ;;
            note)    _enqueue_note "$item" ;;
            control) _process_control "$item" ;;
        esac
        mv "$item" "${inbox_dir}/processed/"
    done
}
```

**Server lifecycle:**

The Watchtower server is managed as a background process:

```bash
# Start: tekhton --watchtower-serve
# Or: WATCHTOWER_SERVE_ENABLED=true in pipeline.conf (auto-start)
# Stop: tekhton --watchtower-stop
# Status: tekhton --watchtower-status

_watchtower_serve() {
    local port="${WATCHTOWER_PORT:-8420}"
    python3 "${TEKHTON_HOME}/tools/watchtower_server.py" \
        --port "$port" \
        --data-dir "${PROJECT_DIR}/.claude/watchtower" \
        --log-dir "${PROJECT_DIR}/.claude/logs" \
        --inbox-dir "${PROJECT_DIR}/.claude/inbox" &
    local pid=$!
    echo "$pid" > "${PROJECT_DIR}/.claude/watchtower.pid"
    log_default "Watchtower serving at http://localhost:${port}"
}
```

### Config Keys

```bash
WATCHTOWER_SERVE_ENABLED=false         # Auto-start served Watchtower
WATCHTOWER_PORT=8420                    # Server port
WATCHTOWER_API_ENABLED=true            # Enable REST API
WATCHTOWER_WS_ENABLED=true             # Enable WebSocket push
WATCHTOWER_INBOX_ENABLED=true          # Enable file-based inbox
WATCHTOWER_INBOX_DIR=".claude/inbox"   # Inbox directory
WATCHTOWER_COST_DASHBOARD=true         # Show cost panel
WATCHTOWER_PARALLEL_VIEW=true          # Show parallel team view
```

### Why This Design

- **Dual-mode** preserves the V3 static-file experience for users who don't need
  a server, while enabling the full interactive experience for those who do.
- **WATCHTOWER_SERVE_ENABLED** config var means "set it once, forget it" —
  the user doesn't need to pass `--watchtower-serve` every time.
- **Python HTTP server** reuses the existing optional Python dependency. The
  server is lightweight (~500 lines) — it's a file watcher + API wrapper, not a
  full web framework.
- **The inbox pattern** decouples the UI from the pipeline. Watchtower writes
  files; the pipeline reads files. No IPC, no sockets, no shared state. This is
  the safest possible integration pattern.
- **REST API** enables external tools (scripts, CI/CD, other dashboards) to
  interact with Tekhton programmatically without the CLI.

---

## System Design: Project Owner Experience

### Problem

Tekhton assumes its user is a software engineer. Task intake requires precise
engineering language. Progress reporting uses turns, tokens, and exit codes.
There are no release notes, no changelogs, no cost forecasts. A product owner
who wants to build software using Tekhton cannot effectively manage the process
without deep engineering knowledge.

### Design

**Enhanced task intake:**

The PM/intake agent (V3 M10) is extended to accept natural language from non-
engineers and decompose it into actionable milestones:

```
User input:  "I want a login page with email and password,
              social sign-in with Google and GitHub,
              and a forgot-password flow"

PM Agent output:
  Milestone 1: Email/Password Authentication
    - User registration form with validation
    - Login form with session management
    - Password hashing and secure storage
    Tests: registration flow, login flow, invalid inputs

  Milestone 2: Social Sign-In (Google + GitHub)
    - OAuth 2.0 integration for Google
    - OAuth 2.0 integration for GitHub
    - Account linking for existing users
    Tests: OAuth redirect flow, account linking

  Milestone 3: Forgot Password Flow
    - Password reset request form
    - Email sending with reset token
    - Token validation and password update
    Tests: reset request, token expiry, password update
```

The PM agent uses the project's existing CLAUDE.md and DESIGN.md context to
ground the decomposition in the project's architecture and conventions.

**Progress reporting for project owners:**

```
── Run Summary ─────────────────────────────────────────
   Task: Add user authentication
   Status: COMPLETE (3 milestones)
   Duration: 47 minutes | Cost: $8.40

   Milestone 1: Email/Password Auth .............. Done
   Milestone 2: Social Sign-In ................... Done
   Milestone 3: Forgot Password .................. Done

   What was built:
   - Registration page at /register with email validation
   - Login page at /login with session cookies
   - Google and GitHub OAuth sign-in buttons
   - Forgot password flow with email reset tokens
   - 12 new tests, all passing

   What to review:
   - OAuth client secrets need to be configured (.env.example updated)
   - Email sending uses console transport in dev mode

   Files changed: 14 added, 3 modified
   Tests: 12 new, 47 total, all passing
────────────────────────────────────────────────────────
```

**Release notes generation:**

After milestone completion, Tekhton generates human-readable release notes:

```bash
_generate_release_notes() {
    local milestone_id="$1"
    local notes_file="${PROJECT_DIR}/.claude/releases/release_${milestone_id}.md"

    # Extract: what changed, why, what to test, known limitations
    # Sources: git diff, milestone spec, reviewer report, tester report
    # Format: non-technical summary + technical details
}
```

Output format:
```markdown
# Release: User Authentication (v1.2.0)
**Date:** 2026-04-01 | **Cost:** $8.40 | **Duration:** 47 min

## What's New
- Users can register and sign in with email/password
- Google and GitHub social sign-in options
- Forgot password flow with email verification

## Setup Required
- Add OAuth credentials to `.env` (see `.env.example`)
- Configure email provider for password reset (default: console)

## Technical Details
- 14 new files, 3 modified
- 12 new tests (all passing)
- Authentication via express-session + passport.js
```

**Changelog automation:**

Each completed milestone appends to `CHANGELOG.md` in the project:

```markdown
## [1.2.0] - 2026-04-01
### Added
- User registration with email validation
- Login with session management
- Google OAuth sign-in
- GitHub OAuth sign-in
- Forgot password with email reset tokens
```

Format follows [Keep a Changelog](https://keepachangelog.com/) conventions.

**Cost forecasting:**

Based on the cost ledger and historical data:

```bash
_forecast_cost() {
    local remaining_milestones="$1"
    # Calculate average cost per milestone from history
    # Adjust for milestone complexity (scout estimates)
    # Report: estimated remaining cost, estimated total project cost
}
```

Watchtower's cost dashboard displays:
- Cost so far (actual)
- Estimated cost to completion (forecast)
- Cost per milestone (historical)
- Cost trend (is the project getting more/less expensive per milestone?)

**Deliverable artifacts:**

Every completed run produces a summary package in `.claude/deliverables/`:
- `summary.md` — plain-language summary of what was done
- `release_notes.md` — formatted release notes
- `changelog_entry.md` — entry for CHANGELOG.md
- `cost_report.json` — detailed cost breakdown
- `test_report.md` — test results in readable format
- `diff_summary.md` — human-readable description of code changes

### Config Keys

```bash
RELEASE_NOTES_ENABLED=true             # Generate release notes per milestone
CHANGELOG_ENABLED=true                 # Auto-update CHANGELOG.md
CHANGELOG_FILE="CHANGELOG.md"          # Changelog path
COST_FORECAST_ENABLED=true             # Enable cost forecasting
DELIVERABLES_DIR=".claude/deliverables"
DELIVERABLES_SUMMARY=true              # Generate plain-language summary
PM_NATURAL_LANGUAGE=true               # Accept non-technical task descriptions
PM_AUTO_DECOMPOSE=true                 # Auto-decompose into milestones
```

### Why This Design

- **Natural language intake** extends the existing PM agent (V3 M10) rather than
  replacing it. The clarity evaluation rubric still applies — it just has a
  broader input acceptance range.
- **Release notes and changelogs** are generated from data already captured
  (git diffs, milestone specs, test reports). No additional agent calls needed
  for basic release notes; an agent call is optional for polished summaries.
- **Cost forecasting from historical data** gets more accurate over time as the
  cost ledger accumulates. First-run estimates use scout complexity estimates.
- **Keep a Changelog format** is the most widely adopted changelog convention.
  Following it means Tekhton's output integrates with existing tooling.
- **Deliverable artifacts** give the project owner a "package" they can review
  without looking at code. This is the key UX shift from "engineer tool" to
  "project owner tool."

---

## System Design: External Integrations

### Problem

Tekhton operates in isolation. It cannot pull tasks from issue trackers, push
results to team communication tools, ship logs to observability platforms, or
participate in CI/CD workflows. In an enterprise environment, this isolation makes
Tekhton invisible to the organization's existing toolchain.

### Design

**Integration framework:**

Integrations are implemented as adapter modules in `lib/integrations/`. Each
adapter implements a standard interface and is activated via config:

```bash
# lib/integrations/adapter.sh — base interface

# Each adapter implements:
# _integration_<name>_init()      — setup, auth check
# _integration_<name>_on_event()  — handle pipeline events
# _integration_<name>_health()    — connectivity check
```

**GitHub integration:**

Bidirectional sync with GitHub Issues and Pull Requests:

```bash
# Inbound: pull tasks from GitHub Issues
_integration_github_pull_issues() {
    # Fetch issues with configurable label filter (e.g., "tekhton")
    # Convert to Tekhton task format
    # Queue in inbox for next run
}

# Outbound: push results to GitHub
_integration_github_on_event() {
    local event_type="$1"
    case "$event_type" in
        milestone.complete)
            # Create PR with milestone changes
            # Comment on linked issue with summary
            # Update issue labels (in-progress → done)
            ;;
        pipeline.fail)
            # Comment on linked issue with failure details
            # Add "needs-attention" label
            ;;
        release.ready)
            # Create GitHub Release with release notes
            ;;
    esac
}
```

**Slack / Teams notification:**

```bash
_integration_slack_on_event() {
    local event_type="$1"
    case "$event_type" in
        pipeline.start)    _slack_post "Pipeline started: ${TASK}" ;;
        milestone.complete) _slack_post "Milestone complete: ${MILESTONE_TITLE}" ;;
        pipeline.complete) _slack_post "Pipeline complete. ${SUMMARY}" ;;
        pipeline.fail)     _slack_post "ALERT: Pipeline failed. ${ERROR}" ;;
        human.required)    _slack_post "ACTION NEEDED: ${DESCRIPTION}" ;;
    esac
}

_slack_post() {
    local message="$1"
    curl -s -X POST "${SLACK_WEBHOOK_URL}" \
        -H 'Content-Type: application/json' \
        -d "{\"text\": \"[Tekhton] ${message}\"}"
}
```

**Log shipping (DataDog / Splunk):**

The structured JSONL event stream (from the Logging system design) is the
integration point. Log shipping is implemented as a lightweight forwarder:

```bash
# Option 1: Direct API shipping
_integration_datadog_ship() {
    local events_file="$1"
    # Batch events and POST to DataDog Logs API
    # Includes: dd-api-key header, source=tekhton, service tag
}

# Option 2: File-based (agent picks up)
# DataDog/Splunk agents monitor .claude/logs/events.jsonl directly
# No custom code needed — just configure the agent's log path

# Option 3: Syslog forwarding
_integration_syslog_forward() {
    # Forward structured events to syslog for enterprise ingestion
}
```

Recommendation: Ship Option 2 (file-based) as default since enterprise
environments typically already have log collection agents. Option 1 (direct API)
as opt-in for standalone deployments.

**CI/CD integration:**

Tekhton as a CI/CD step:

```yaml
# GitHub Actions example
- name: Run Tekhton
  uses: tekhton/tekhton-action@v4
  with:
    task: "Implement feature from issue #42"
    model: opus
    max-milestones: 3
    watchtower: true
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

The CI/CD adapter:
- Reads task from environment/input parameters
- Outputs structured results as CI artifacts
- Sets exit code based on pipeline outcome
- Posts status checks to the PR

**Webhook support (generic):**

For tools not covered by specific adapters:

```bash
_integration_webhook_on_event() {
    local event_type="$1" payload="$2"
    curl -s -X POST "${WEBHOOK_URL}" \
        -H 'Content-Type: application/json' \
        -H "X-Tekhton-Event: ${event_type}" \
        -H "X-Tekhton-Signature: $(echo -n "$payload" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET")" \
        -d "$payload"
}
```

### Config Keys

```bash
# GitHub
INTEGRATION_GITHUB_ENABLED=false
INTEGRATION_GITHUB_TOKEN=""            # or use GITHUB_TOKEN env var
INTEGRATION_GITHUB_REPO=""             # owner/repo
INTEGRATION_GITHUB_ISSUE_LABEL="tekhton"
INTEGRATION_GITHUB_AUTO_PR=true        # Create PR on milestone complete
INTEGRATION_GITHUB_AUTO_RELEASE=true   # Create release on project complete

# Slack
INTEGRATION_SLACK_ENABLED=false
INTEGRATION_SLACK_WEBHOOK_URL=""
INTEGRATION_SLACK_CHANNEL=""
INTEGRATION_SLACK_EVENTS="pipeline.complete,pipeline.fail,human.required"

# Log shipping
INTEGRATION_LOG_SHIPPING=none          # none | datadog | splunk | syslog | file
INTEGRATION_DATADOG_API_KEY=""
INTEGRATION_SPLUNK_HEC_URL=""
INTEGRATION_SPLUNK_HEC_TOKEN=""

# Webhook
INTEGRATION_WEBHOOK_ENABLED=false
INTEGRATION_WEBHOOK_URL=""
INTEGRATION_WEBHOOK_SECRET=""
INTEGRATION_WEBHOOK_EVENTS="*"         # or comma-separated event types

# CI/CD
INTEGRATION_CI_MODE=false              # Running in CI environment
INTEGRATION_CI_ARTIFACT_DIR=""         # Where to write CI artifacts
```

### Why This Design

- **Event-driven adapters** mean integrations react to pipeline events, not poll
  for state. Low overhead, real-time notifications.
- **File-based log shipping as default** is the enterprise-friendly choice. IT
  teams configure their existing agents; Tekhton just writes structured files.
- **Webhook support** is the escape hatch — any tool with an HTTP endpoint can
  receive Tekhton events without a custom adapter.
- **GitHub integration** is the highest-value specific integration because most
  Tekhton users are already on GitHub. Issue-to-milestone-to-PR-to-release is
  the complete lifecycle.
- **CI/CD mode** makes Tekhton a step in existing workflows rather than a
  standalone tool. This is critical for enterprise adoption.

---

## System Design: NFR Framework

### Problem

Tekhton enforces functional correctness (tests pass, build succeeds, code
reviews approve) but has no framework for non-functional requirements. There are
no performance budgets, no accessibility gates, no SLAs on pipeline execution
itself, no cost ceilings, and no detection of out-of-band behavior. As Tekhton
scales to enterprise use, NFR enforcement becomes a hard requirement.

### Design

**NFR categories:**

| Category | What It Measures | Example Threshold |
|----------|-----------------|-------------------|
| **Performance** | Page load, API response, bundle size | Page load < 2s, API < 200ms |
| **Accessibility** | WCAG compliance level | WCAG 2.1 AA |
| **Security** | Vulnerability severity, dependency audit | No CRITICAL/HIGH unfixed |
| **Cost** | Per-run, per-milestone, per-project | Max $50/milestone |
| **Pipeline SLA** | Execution time, stage duration | Max 2h/milestone |
| **Test Coverage** | Line/branch coverage thresholds | Min 80% line coverage |
| **Bundle/Size** | Output artifact size limits | Bundle < 500KB |
| **License** | Dependency license compliance | No GPL in commercial project |

**NFR specification:**

NFRs are declared in `pipeline.conf` or a dedicated `.claude/nfr.conf`:

```bash
# .claude/nfr.conf

# Performance budgets
NFR_PERF_ENABLED=true
NFR_PERF_PAGE_LOAD_MS=2000
NFR_PERF_API_RESPONSE_MS=200
NFR_PERF_BUNDLE_SIZE_KB=500

# Accessibility
NFR_A11Y_ENABLED=false
NFR_A11Y_STANDARD=WCAG21_AA
NFR_A11Y_TOOL=axe                      # axe | pa11y | lighthouse

# Cost ceilings
NFR_COST_ENABLED=true
NFR_COST_MAX_PER_MILESTONE=50.00
NFR_COST_MAX_PER_RUN=100.00
NFR_COST_MAX_PER_PROJECT=1000.00
NFR_COST_ALERT_PCT=80                   # Alert at 80% of ceiling

# Pipeline SLAs
NFR_SLA_ENABLED=true
NFR_SLA_MILESTONE_TIMEOUT_S=7200       # 2 hours per milestone
NFR_SLA_STAGE_TIMEOUT_S=1800           # 30 min per stage
NFR_SLA_TOTAL_TIMEOUT_S=28800          # 8 hours total

# Test coverage
NFR_COVERAGE_ENABLED=false
NFR_COVERAGE_MIN_LINE_PCT=80
NFR_COVERAGE_MIN_BRANCH_PCT=70
NFR_COVERAGE_TOOL=auto                  # auto-detect from project

# License compliance
NFR_LICENSE_ENABLED=false
NFR_LICENSE_DENY="GPL-2.0,GPL-3.0,AGPL-3.0"
NFR_LICENSE_TOOL=auto                   # license-checker, cargo-deny, etc.
```

**NFR check engine:**

```bash
# lib/nfr.sh

run_nfr_checks() {
    local stage="$1"  # post-build | post-test | post-milestone | post-run
    local violations=0

    for check in $(get_enabled_nfr_checks "$stage"); do
        local result
        result=$(_run_nfr_check "$check")
        local status=$?

        emit_event "nfr.check" "\"check\":\"$check\",\"status\":$status"

        if [[ $status -ne 0 ]]; then
            ((violations++))
            emit_event "nfr.violation" "\"check\":\"$check\",\"detail\":\"$result\""

            case "$(_nfr_violation_policy "$check")" in
                block)  log_default "   NFR VIOLATION (blocking): $check — $result"
                        return 1 ;;
                warn)   log_default "   NFR WARNING: $check — $result" ;;
                log)    log_verbose "   NFR note: $check — $result" ;;
            esac
        fi
    done

    return 0
}
```

**Check timing:**

| Check | When It Runs |
|-------|-------------|
| Cost ceiling | After every agent invocation |
| Pipeline SLA | Continuously (timer-based) |
| Stage timeout | Per-stage wrapper |
| Performance budget | After build gate (if perf test command configured) |
| Accessibility | After build gate (if a11y tool configured) |
| Test coverage | After tester stage |
| License compliance | After dependency changes detected |
| Bundle size | After build gate |

**Violation policies:**

Each NFR check has a configurable violation policy:
- `block` — Pipeline stops. Rework required.
- `warn` — Pipeline continues. Warning in output and Watchtower.
- `log` — Recorded in event log. No user-visible warning.

```bash
# Default policies (overridable per-check)
NFR_POLICY_COST=block                   # Cost overruns block
NFR_POLICY_SLA=warn                     # SLA violations warn
NFR_POLICY_PERF=warn                    # Performance budget violations warn
NFR_POLICY_A11Y=warn                    # Accessibility violations warn
NFR_POLICY_COVERAGE=warn                # Coverage shortfalls warn
NFR_POLICY_LICENSE=block                # License violations block
```

**Out-of-band behavior detection:**

The NFR framework includes anomaly detection for the pipeline itself:

```bash
_check_pipeline_anomalies() {
    # Stage took 3x longer than historical average → warn
    # Cost per turn is 2x higher than normal → warn
    # Agent used max turns 3 consecutive times → warn (possible stuck)
    # Rework cycles exceeded historical max → warn
    # Turn-exhaustion continuations hit max → block
}
```

Historical baselines are computed from the metrics database (V3 M15).

### Why This Design

- **Config-driven NFRs** mean enforcement rules live alongside other project
  config. No code changes needed to add or modify thresholds.
- **Check timing** is stage-aware — expensive checks (perf, a11y) run only after
  build, not on every invocation. Cost checks run on every invocation because
  they're cheap (read the ledger).
- **Three-tier violation policies** prevent NFRs from being either ignored (too
  permissive) or pipeline-blocking (too strict). Project owners configure the
  balance.
- **Anomaly detection** catches emergent problems (stuck loops, cost spirals)
  that aren't covered by static thresholds.

---

## System Design: Auth & Identity Stub

### Problem

Tekhton has no concept of user identity. In an enterprise environment, this
means: no audit trail tied to a person, no access control for who can run what,
no integration with corporate SSO providers, and no way to distinguish between
team members in a shared environment.

### Design (V4 Stub — Full Build in V5)

V4 implements the **abstraction layer and one concrete adapter**. The goal is
to establish the identity model and integration points so V5 can add providers
without architectural changes.

**Identity model:**

```bash
# .claude/auth.conf

AUTH_ENABLED=false                      # Enable identity layer
AUTH_PROVIDER=local                     # local | oidc | env
AUTH_USER_ID=""                         # Explicit user ID (local mode)
AUTH_OIDC_ISSUER=""                     # OIDC discovery URL
AUTH_OIDC_CLIENT_ID=""                  # Client ID for OIDC
AUTH_OIDC_CLIENT_SECRET_FILE=""         # Path to client secret
```

**Three modes (V4):**

1. **Local (default)** — User identity from `AUTH_USER_ID` config or `$USER`
   environment variable. No authentication. Just a label for audit trail.

2. **Environment** — User identity from environment variables set by the
   deployment platform (CI/CD, container orchestrator, corporate tooling).
   ```bash
   AUTH_PROVIDER=env
   AUTH_ENV_USER_VAR=TEKHTON_USER       # or CI_COMMIT_AUTHOR, etc.
   AUTH_ENV_ROLE_VAR=TEKHTON_ROLE       # optional
   ```

3. **OIDC stub** — The abstraction layer for Okta, Auth0, Microsoft Entra ID,
   PingID. V4 implements token validation (verify JWT from these providers).
   V5 implements the full OAuth flow (redirect, consent, token exchange).
   ```bash
   AUTH_PROVIDER=oidc
   AUTH_OIDC_ISSUER="https://login.microsoftonline.com/TENANT/v2.0"
   # V4: validates existing tokens (user brings token)
   # V5: handles full OAuth redirect flow
   ```

**Audit trail enrichment:**

When auth is enabled, every structured event and log entry includes identity:

```json
{
  "ts": "2026-04-01T10:23:45Z",
  "type": "stage.complete",
  "user": {
    "id": "jdoe@company.com",
    "provider": "oidc",
    "role": "developer"
  },
  "data": { ... }
}
```

**Access control (V5 preview — data model only in V4):**

```bash
# V5 will enforce these; V4 just records them
AUTH_ROLE_ADMIN="*"                     # Can do everything
AUTH_ROLE_DEVELOPER="run,view"          # Can run pipeline, view results
AUTH_ROLE_VIEWER="view"                 # Can only view Watchtower
```

V4 records the user's role in the audit trail. V5 enforces role-based access.

### Config Keys

```bash
AUTH_ENABLED=false
AUTH_PROVIDER=local                     # local | env | oidc
AUTH_USER_ID=""
AUTH_ENV_USER_VAR="USER"
AUTH_ENV_ROLE_VAR=""
AUTH_OIDC_ISSUER=""
AUTH_OIDC_CLIENT_ID=""
AUTH_OIDC_CLIENT_SECRET_FILE=""
AUTH_OIDC_TOKEN_FILE=""                 # Path to pre-obtained token (V4)
AUTH_AUDIT_IDENTITY=true                # Include identity in audit events
```

### Why This Design

- **Three modes** cover the realistic V4 deployment scenarios: local dev (local),
  CI/CD (env), enterprise with existing SSO (oidc stub).
- **OIDC as the stub protocol** covers Okta, Auth0, Entra ID, and PingID — all
  of which implement OIDC. One protocol, four providers.
- **Token validation without OAuth flow** is the right V4 scope. Enterprise users
  already have tokens from their SSO tooling (CLI login, service accounts). V4
  verifies them; V5 obtains them.
- **~2 milestones of work** — one for the abstraction + local/env, one for OIDC
  validation. Well within the V4 budget.
- **Audit enrichment** is the immediate payoff. Even with local mode, knowing
  who ran what and when is valuable.

---

## System Design: Learning & Adaptation

### Problem

Tekhton captures rich data — causal event logs, run metrics, cost ledgers,
verdict histories, rework cycle counts — but doesn't close the feedback loop.
Each run starts fresh without learning from prior runs. Scout estimates don't
improve with experience. Prompt templates don't adapt to which formulations
produce better agent outcomes. Failure patterns aren't recognized across runs.

### Design

**Historical knowledge base:**

```
.claude/knowledge/
    run_history.jsonl          # Summary of each run (cost, duration, outcome)
    stage_performance.jsonl    # Per-stage metrics across runs
    failure_patterns.jsonl     # Classified failure modes + resolutions
    prompt_effectiveness.jsonl # Prompt variant → outcome correlation
    task_complexity.jsonl      # Task description → actual complexity mapping
```

**Scout accuracy calibration (extends V3 M15):**

V3's metrics system tracks scout estimates vs actual turns. V4 uses this data
to calibrate future estimates:

```bash
_calibrate_scout_estimate() {
    local raw_estimate="$1"
    local task_type="$2"  # extracted from task keywords

    # Load historical accuracy for this task type
    local accuracy
    accuracy=$(_get_historical_accuracy "$task_type")

    # If scout historically overestimates by 30%, deflate
    # If scout historically underestimates by 20%, inflate
    local calibrated
    calibrated=$(echo "$raw_estimate * $accuracy" | bc)

    echo "$calibrated"
}
```

**Failure pattern recognition:**

When a pipeline fails, the failure classifier checks against known patterns:

```bash
_classify_failure() {
    local error_output="$1"

    # Check against known patterns
    while IFS='|' read -r pattern category resolution; do
        if echo "$error_output" | grep -qE "$pattern"; then
            log_default "   Known failure pattern: $category"
            log_default "   Suggested resolution: $resolution"
            emit_event "failure.recognized" \
                "\"pattern\":\"$category\",\"resolution\":\"$resolution\""
            return 0
        fi
    done < "${TEKHTON_HOME}/.claude/knowledge/failure_patterns.jsonl"

    # Unknown pattern — record for future recognition
    _record_new_failure "$error_output"
    return 1
}
```

New failure patterns are recorded automatically. After N occurrences of a similar
failure (configurable), the pattern is promoted to "known" with the resolution
that worked.

**Prompt effectiveness tracking:**

The system tracks which prompt formulations produce better outcomes:

```bash
# After each stage completion, record effectiveness signals
_record_prompt_effectiveness() {
    local stage="$1" prompt_hash="$2"
    local turns_used="$3" rework_count="$4" outcome="$5"

    # Lower turns + fewer reworks + passing outcome = better prompt
    local effectiveness_score
    effectiveness_score=$(_compute_effectiveness "$turns_used" "$rework_count" "$outcome")

    echo "{\"stage\":\"$stage\",\"prompt_hash\":\"$prompt_hash\",\"score\":$effectiveness_score}" \
        >> ".claude/knowledge/prompt_effectiveness.jsonl"
}
```

V4 tracks effectiveness data. Prompt auto-tuning (selecting between prompt
variants based on historical effectiveness) is deferred to V5 — V4 provides
the data foundation.

**Cross-project learning (V4 scope: local only):**

When a user runs Tekhton across multiple projects on the same machine, patterns
from one project can inform another:

```bash
# ~/.tekhton/global_knowledge/
#     failure_patterns.jsonl    # Cross-project failure patterns
#     provider_profiles.jsonl   # Provider performance across projects
#     cost_benchmarks.jsonl     # Cost per complexity-tier per provider
```

V4 writes to both project-local and global knowledge bases. Reading from the
global base is opt-in (`LEARNING_GLOBAL_ENABLED=true`).

### Config Keys

```bash
LEARNING_ENABLED=true                   # Enable learning subsystem
LEARNING_HISTORY_MAX_RUNS=100           # Max runs to retain in history
LEARNING_CALIBRATION_ENABLED=true       # Use history for scout calibration
LEARNING_FAILURE_PATTERNS=true          # Record and match failure patterns
LEARNING_FAILURE_PROMOTE_THRESHOLD=3    # Occurrences before pattern promoted
LEARNING_PROMPT_TRACKING=true           # Track prompt effectiveness
LEARNING_GLOBAL_ENABLED=false           # Cross-project knowledge sharing
LEARNING_GLOBAL_DIR="~/.tekhton/global_knowledge"
```

### Why This Design

- **Data first, automation later.** V4 collects and uses data for calibration
  and pattern matching. V5 adds prompt auto-tuning. This mirrors V2's "measure
  before optimizing" philosophy.
- **Known failure patterns** reduce the "same failure, same 10 minutes debugging"
  cycle. The system learns from its own mistakes.
- **Local-first cross-project learning** avoids privacy and security concerns.
  No data leaves the machine. Enterprise sharing (team knowledge bases) is V5.
- **Scout calibration** directly reduces wasted turns (over-allocation) and
  stuck runs (under-allocation). Immediate ROI.

---

## System Design: Language & Domain Intelligence

### Problem

Tekhton treats all code the same. The coder prompt doesn't distinguish between
writing a React component and a Rust FFI binding. The reviewer doesn't check
for language-specific pitfalls (JavaScript prototype pollution, Go goroutine
leaks, Python type annotation correctness). The tester doesn't know that
frontend code needs different test strategies than backend APIs.

V3's tree-sitter integration understands syntax. V4 needs to understand
semantics — how professionals write each language and what makes a codebase
good in that language's ecosystem.

### Design

**Language profile system:**

```
tools/bridge/language_profiles/
    javascript.json
    typescript.json
    python.json
    rust.json
    go.json
    java.json
    csharp.json
    lua.json
    shell.json
    c.json
    cpp.json
```

Each profile contains:

```json
{
  "language": "javascript",
  "domain_hints": {
    "frontend": {
      "indicators": ["react", "vue", "angular", "svelte", "next"],
      "test_frameworks": ["jest", "vitest", "cypress", "playwright"],
      "review_focus": ["bundle-size", "accessibility", "xss-prevention", "async-patterns"],
      "conventions": ["component-per-file", "hooks-rules", "prop-types-or-ts"]
    },
    "backend": {
      "indicators": ["express", "fastify", "nestjs", "koa"],
      "test_frameworks": ["jest", "mocha", "supertest"],
      "review_focus": ["sql-injection", "auth-middleware", "error-handling", "rate-limiting"],
      "conventions": ["controller-service-repo", "middleware-chain", "env-config"]
    }
  },
  "pitfalls": [
    "prototype-pollution via object spread from user input",
    "async/await without error handling (unhandled rejection)",
    "== instead of === for type-coercive comparison",
    "missing dependency array in useEffect"
  ],
  "ecosystem": {
    "package_manager": "npm|yarn|pnpm",
    "lockfile": "package-lock.json|yarn.lock|pnpm-lock.yaml",
    "build_tools": ["webpack", "vite", "esbuild", "rollup"],
    "lint_tools": ["eslint", "prettier", "biome"]
  }
}
```

**Domain detection:**

At pipeline start, Tekhton detects the project's language(s) and domain(s):

```bash
_detect_language_domains() {
    # V3's detect.sh already identifies languages and frameworks
    # V4 maps those to language profiles + domain hints
    # Output: LANGUAGE_PROFILES=("javascript:frontend" "python:backend")

    for lang in "${DETECTED_LANGUAGES[@]}"; do
        local profile="${TEKHTON_HOME}/tools/bridge/language_profiles/${lang}.json"
        [[ -f "$profile" ]] || continue

        local domain
        domain=$(_match_domain "$profile")
        LANGUAGE_PROFILES+=("${lang}:${domain}")
    done
}
```

**Prompt enrichment:**

Language and domain intelligence is injected into agent prompts via template
variables:

```bash
# In lib/prompts.sh
LANGUAGE_REVIEW_FOCUS=""    # "Check for: XSS prevention, async error handling..."
LANGUAGE_CONVENTIONS=""     # "Follow: component-per-file, hooks rules..."
LANGUAGE_PITFALLS=""        # "Watch for: prototype pollution, missing deps..."
LANGUAGE_TEST_STRATEGY=""   # "Use: jest for unit, playwright for e2e..."
```

These are assembled from the detected language profiles and injected into
coder, reviewer, and tester prompts via `{{IF:LANGUAGE_REVIEW_FOCUS}}` blocks.

**Frontend vs backend awareness:**

The pipeline treats frontend and backend code differently:

| Aspect | Frontend | Backend |
|--------|----------|---------|
| **Test strategy** | Component tests + E2E + visual regression | Unit + integration + API contract |
| **Review focus** | Accessibility, bundle size, XSS | SQL injection, auth, rate limiting |
| **Build gate** | Build + lint + type check + bundle analysis | Build + lint + type check + migration check |
| **NFR checks** | Page load time, Lighthouse score | API response time, memory usage |
| **Security focus** | CSP, CORS, client-side storage | Input validation, auth, secrets |

Domain detection determines which profile applies. Mixed projects (fullstack)
get both profiles, with file-level routing based on directory structure
(e.g., `src/client/` → frontend, `src/server/` → backend).

### Config Keys

```bash
LANGUAGE_PROFILES_ENABLED=true          # Enable language-specific intelligence
LANGUAGE_PROFILES_DIR=""                # Custom profiles directory (override)
LANGUAGE_DOMAIN_AUTO_DETECT=true        # Auto-detect frontend/backend/fullstack
LANGUAGE_DOMAIN_OVERRIDE=""             # Manual: frontend | backend | fullstack
LANGUAGE_PITFALLS_IN_REVIEW=true        # Inject pitfalls into reviewer prompt
LANGUAGE_CONVENTIONS_IN_CODER=true      # Inject conventions into coder prompt
```

### Why This Design

- **JSON profiles** are data, not code. Adding a new language or updating
  pitfall lists is a JSON edit, not a shell change. Community contributions
  are easy.
- **V3's detection engine** already does the heavy lifting of identifying
  languages and frameworks. V4 adds the semantic layer on top.
- **Frontend/backend awareness** is critical for enterprise users. A bank's
  customer-facing web app has fundamentally different quality requirements than
  its internal API service. Tekhton should know the difference.
- **Pitfall injection** makes the reviewer genuinely language-aware rather than
  relying on the model's training data (which may be outdated or generic).

---

## Scope Boundaries

### In Scope (4.0)

- Provider abstraction layer (tekhton-bridge) with Anthropic, OpenAI, Ollama adapters
- MCP gateway for non-Anthropic providers
- Provider failover with pre-computed profiles
- Cost ledger and per-stage cost tracking
- Per-stage model/provider assignment
- Three-tier structured logging (default/verbose/debug)
- Structured JSONL event stream for enterprise log ingestion
- Stage banners with clean default output
- Test isolation framework (temp dirs, port allocation, process tracking)
- Test quarantine and flakiness detection
- Parallel milestone execution via git worktrees
- Resource budgeting and conflict detection for parallel teams
- Shared build gate after parallel merge
- Watchtower served mode with WebSocket push and REST API
- Interactive controls (task submission, milestone manager, run control)
- Cost dashboard in Watchtower
- Natural language task intake and milestone decomposition
- Release notes and changelog generation
- Cost forecasting
- Deliverable artifact packages
- GitHub integration (issues, PRs, releases)
- Slack/Teams notifications
- Log shipping (DataDog, Splunk via file-based + direct API)
- Webhook support (generic)
- CI/CD integration mode (GitHub Actions)
- NFR framework (performance, cost, SLA, coverage, license, accessibility)
- NFR violation policies (block/warn/log)
- Pipeline anomaly detection
- Auth abstraction layer with local/env/OIDC-stub modes
- Audit trail with identity enrichment
- Learning subsystem (history, scout calibration, failure patterns)
- Cross-project local knowledge sharing
- Language profiles with domain-specific intelligence
- Frontend/backend awareness in all pipeline stages
- Language-specific pitfall injection in reviews

### Out of Scope (V5)

- Full OAuth flow for SSO providers (V4 stubs token validation only)
- Role-based access control enforcement (V4 records roles, V5 enforces)
- Prompt auto-tuning from effectiveness data (V4 collects, V5 acts)
- Stage-level parallelism within a milestone (except Scout + Security pre-scan)
- Cloud-hosted Watchtower for team visibility
- Team knowledge bases (shared learning across users/machines)
- SOC 2 / compliance certification
- Semantic similarity for task→file matching (vs keyword-based)
- Containerized pipeline execution with permission levels
- Deployment, monitoring, and maintenance automation (the "Maximum" scope)
- Multi-tenancy with RBAC
- Mobile Watchtower interface

### Stretch (V4 if time permits)

- Stage-level parallelism for Scout + Security pre-scan
- Automatic `parallel_group` inference from file overlap analysis
- Provider cost comparison mode (same task, multiple providers, compare quality)
- Visual regression testing integration in frontend domain

---

## New Files Summary

**tools/bridge/ (Python — provider abstraction):**
- `__init__.py` — Package init
- `bridge.py` — CLI entry point (`tekhton-bridge call/calibrate/update-pricing`)
- `types.py` — AgentRequest, AgentResponse, ModelInfo, ProviderStatus
- `cost.py` — Cost calculation, ledger management, pricing tables
- `mcp_gateway.py` — MCP client for non-Anthropic providers
- `calibration.py` — Provider profile calibration
- `providers/anthropic.py` — Direct Anthropic SDK adapter
- `providers/openai.py` — OpenAI SDK adapter
- `providers/ollama.py` — Ollama REST API adapter
- `providers/openai_compat.py` — Generic OpenAI-compatible adapter
- `requirements.txt` — Bridge Python dependencies

**tools/watchtower_server.py** — Watchtower HTTP/WebSocket server

**tools/bridge/language_profiles/*.json** — Language profile data files

**lib/ (shell):**
- `logging.sh` — Three-tier logging, structured event emitter
- `parallel.sh` — Parallel execution coordinator
- `parallel_teams.sh` — Team lifecycle (worktree, merge, conflict)
- `parallel_budget.sh` — Resource budgeting across teams
- `nfr.sh` — NFR check engine
- `nfr_checks.sh` — Individual NFR check implementations
- `auth.sh` — Identity abstraction layer
- `learning.sh` — Historical knowledge base, calibration, failure patterns
- `language.sh` — Language profile loading, domain detection, prompt enrichment
- `integrations/github.sh` — GitHub integration adapter
- `integrations/slack.sh` — Slack/Teams notification adapter
- `integrations/logging_ship.sh` — Log shipping adapter
- `integrations/webhook.sh` — Generic webhook adapter
- `integrations/ci.sh` — CI/CD mode adapter
- `test_harness.sh` — Test isolation framework

**tests/:**
- `test_bridge.sh` — Bridge invocation tests
- `test_logging.sh` — Three-tier logging tests
- `test_parallel.sh` — Parallel execution tests
- `test_nfr.sh` — NFR framework tests
- `test_auth.sh` — Auth abstraction tests
- `test_learning.sh` — Learning subsystem tests
- `test_language.sh` — Language profile tests
- `test_integrations.sh` — Integration adapter tests
- `test_harness.sh` — Test harness self-tests

**Python tests:**
- `tools/tests/test_bridge.py` — Bridge unit tests
- `tools/tests/test_providers.py` — Provider adapter tests
- `tools/tests/test_mcp_gateway.py` — MCP gateway tests
- `tools/tests/test_cost.py` — Cost calculation tests
- `tools/tests/test_calibration.py` — Provider calibration tests

## Modified Files Summary

- `lib/agent.sh` — Provider routing in `run_agent()`, cost recording
- `lib/common.sh` — Replace single-tier logging with three-tier system
- `lib/config.sh` — Load new config sections (bridge, nfr, auth, learning, etc.)
- `lib/config_defaults.sh` — All new config keys + defaults + clamps
- `lib/finalize.sh` — Release notes + changelog generation hooks
- `lib/finalize_summary.sh` — Enhanced RUN_SUMMARY.json with cost + identity
- `lib/finalize_display.sh` — Project-owner-friendly completion banner
- `lib/orchestrate.sh` — Parallel execution integration, inbox processing
- `lib/orchestrate_helpers.sh` — Parallel team coordination
- `lib/gates.sh` — NFR check integration in build gate
- `lib/milestones.sh` — Parallel team status tracking
- `lib/milestone_ops.sh` — Parallel-aware milestone completion
- `lib/intake_helpers.sh` — Natural language decomposition
- `lib/prompts.sh` — Language profile template variable injection
- `lib/detect.sh` — Language domain detection (frontend/backend)
- `lib/dashboard.sh` — Watchtower served mode lifecycle
- `lib/causality.sh` — Identity enrichment in events
- `stages/coder.sh` — Language convention injection
- `stages/review.sh` — Language pitfall injection
- `stages/tester.sh` — Domain-aware test strategy
- `stages/security.sh` — Domain-aware security focus
- `templates/watchtower/` — Interactive UI, cost dashboard, parallel view
- `templates/pipeline.conf.example` — New config sections
- `prompts/*.prompt.md` — Language profile conditional blocks
- `tekhton.sh` — Source new modules, bridge init, parallel mode, served watchtower
- `tests/run_tests.sh` — Test harness integration, quarantine support

## Backward Compatibility

| Feature | Default | Opt-in Mechanism | V3 Behavior When Off |
|---------|---------|-----------------|---------------------|
| Provider bridge | `BRIDGE_ENABLED=false` | Config toggle | claude CLI only |
| Three-tier logging | `TEKHTON_LOG_LEVEL=default` | Config or flag | Current output |
| Test harness | Auto-detected | New test files use it | Old tests unchanged |
| Parallel execution | `PARALLEL_ENABLED=false` | Config toggle | Serial (V3) |
| Watchtower served | `WATCHTOWER_SERVE_ENABLED=false` | Config or flag | Static HTML (V3) |
| Release notes | `RELEASE_NOTES_ENABLED=true` | Config toggle | No release notes |
| NFR framework | `NFR_*_ENABLED=false` (each) | Config per-check | No NFR checks |
| Auth | `AUTH_ENABLED=false` | Config toggle | No identity |
| Learning | `LEARNING_ENABLED=true` | Config toggle | No learning |
| Language profiles | `LANGUAGE_PROFILES_ENABLED=true` | Config toggle | Generic prompts |
| Integrations | Each `_ENABLED=false` | Config per-integration | No integrations |

All V3 workflows work unchanged with default configuration. No breaking changes.

---

## V5 Forward Seeds

The following capabilities are explicitly designed for but not built in V4:

- **Full OAuth SSO flow** — V4's OIDC stub validates tokens; V5 implements the
  complete redirect/consent/exchange flow for Okta, Auth0, Entra ID, PingID.
  The auth abstraction layer and OIDC token validation logic are reusable.

- **Role-based access control** — V4's audit trail records user roles from the
  identity provider. V5 enforces them: viewer can only see Watchtower, developer
  can run pipelines, admin can modify config. The data model exists in V4.

- **Prompt auto-tuning** — V4's prompt effectiveness tracking collects per-stage,
  per-prompt-variant outcome data. V5 uses this to A/B test prompt variations
  and automatically select the best performer. Requires sufficient data volume
  from V4 usage.

- **Stage-level parallelism** — V4's parallel engine runs independent milestones
  concurrently. V5 extends this to stages within a milestone (e.g., Coder +
  Security in parallel with conflict resolution). Requires V4's conflict
  detection and merge infrastructure.

- **Cloud-hosted Watchtower** — V4's Watchtower server runs on localhost. V5 adds
  authenticated cloud hosting for team visibility, mobile access, and cross-
  project dashboards. The REST API and WebSocket protocol are reusable.

- **Team knowledge bases** — V4's learning subsystem is per-machine. V5 adds
  shared knowledge bases for organizations (failure patterns, prompt calibration,
  cost benchmarks shared across team members). Requires V4's auth for access control.

- **Deployment & monitoring** — V4 builds software. V5 deploys and monitors it.
  Container orchestration, health checks, rollback automation, alerting. The
  "Maximum" scope of the dev shop vision.

- **SOC 2 / compliance** — V4's structured logging and audit trail are
  "auditable in practice." V5 adds formal compliance controls: tamper-evident
  log chains, retention policies, access audit reports, data classification.

- **Semantic similarity** — V4's task→file matching uses keywords. V5 uses
  embedding-based semantic similarity for more accurate context assembly.
  Requires a local embedding model or API call.

- **Multi-tenancy** — V4 is one-instance-per-project. V5 adds multi-tenant
  deployment with project isolation, shared infrastructure, and organizational
  billing aggregation.

- **B1 bridge (full replacement)** — V4's B2 bridge sits alongside the `claude`
  CLI. V5 evaluates whether the bridge has sufficient capability (MCP, sessions,
  permissions) to fully replace the CLI for all providers including Anthropic.

- **Provider cost comparison mode** — V4 tracks costs per provider. V5 adds a
  mode that runs the same task against multiple providers and compares quality +
  cost, helping users make informed provider choices.

- **Auto pipeline ordering** — V4's PM agent decomposes tasks. V5's PM agent
  recommends standard or test-first pipeline order per milestone based on task
  type and historical rework data.

---

## Milestone Plan

### Overview

27 milestones across 4 phases. Each milestone is scoped for a single
`tekhton --milestone` run. Dogfood checkpoints mark optimal points to replace
the working Tekhton copy with the latest V4 build.

```
Phase 1: Foundations (M01-M07)     — Test, logging, provider abstraction
Phase 2: Core (M08-M16)           — Parallel execution, Watchtower, owner UX
Phase 3: Enterprise (M17-M23)     — Integrations, NFRs, auth
Phase 4: Intelligence (M24-M27)   — Learning, language awareness
```

### Dependency Graph (Simplified)

```
M01 ─────────────────────────────────────────────────────────────────────
M02 ──┬──── M03 ──┬── M04 ──┬── M06 ──┬── M10 ── M13
      │           └── M05 ──┘    │     └── M16
      │                └── M07   │     └── M20 ── M21
      ├──── M08 ── M09 ─────────┘          └── M24 ── M25
      ├──── M11 ── M12 ─────────────── M13
      ├──── M14
      ├──── M15 ──┬── M16
      │           └── M17
      ├──── M18
      ├──── M19
      ├──── M22 ── M23
      └──── M26 ── M27
```

---

### Phase 1: Foundations (M01-M07)

#### Milestone 1: Test Harness & Isolation Framework

**Parallel group:** foundation | **Depends on:** (none)

Files to create/modify:
- Create `lib/test_harness.sh` — isolation framework (temp dirs, port allocator,
  process tracking, teardown traps)
- Modify `tests/run_tests.sh` — integrate harness, add `--flake-check` mode,
  quarantine support
- Create `tests/test_harness_self.sh` — self-tests for the harness itself
- Modify existing browser/network tests to use harness lifecycle

Acceptance criteria:
- `_test_setup` creates isolated temp dir, `_test_teardown` removes it on all
  exit paths (normal, error, signal)
- `_allocate_port` / `_release_port` prevent port conflicts across concurrent tests
- `_spawn_tracked` registers PIDs; teardown kills all tracked processes
- `--flake-check 5` runs each test 5 times, reports inconsistent results
- Quarantine file (`.claude/test_quarantine.json`) excludes quarantined tests
  from blocking pipeline while still running and reporting them
- Test categories (`unit`, `integration`, `browser`, `network`, `e2e`) parsed
  from `# test_category:` comment in each test file
- Zombie process detection (`_check_zombies`) runs pre/post test suite
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n lib/test_harness.sh` and `shellcheck lib/test_harness.sh` pass

Watch For:
- Trap chaining — `_test_teardown` trap must not clobber existing traps in test
  files. Use `trap '...; _test_teardown' EXIT` pattern that preserves prior traps.
- Port lock directory cleanup on unclean system reboot — stale lock dirs from
  crashed tests. Add age-based cleanup (locks older than 1 hour = stale).
- macOS vs Linux `mktemp` flag differences (`-d` works on both but template
  handling differs).

Seeds Forward:
- Every subsequent milestone's tests use the harness automatically
- Flakiness data feeds into the Learning subsystem (M24)
- Quarantine status is displayed in Watchtower Reports tab (M13)

---

#### Milestone 2: Three-Tier Logging & Structured Events

**Parallel group:** foundation | **Depends on:** (none)

Files to create/modify:
- Create `lib/logging.sh` — `log_default()`, `log_verbose()`, `log_debug()`,
  `emit_event()`, `_log_to_file()`, log level parsing, file management
- Modify `lib/common.sh` — replace existing `log_info` / `log_warn` / `log_error`
  with three-tier wrappers, source `lib/logging.sh`
- Modify all `stages/*.sh` — add `_stage_banner()` and `_stage_complete()` calls
- Modify `tekhton.sh` — parse `--verbose` / `--debug` flags, init log files
- Modify `lib/config_defaults.sh` — add `TEKHTON_LOG_LEVEL`, `TEKHTON_LOG_DIR`,
  `TEKHTON_LOG_RETENTION`, `TEKHTON_STRUCTURED_EVENTS`
- Create `tests/test_logging.sh` — tier filtering, event format, file rotation

Acceptance criteria:
- `TEKHTON_LOG_LEVEL=default` shows only stage banners and outcomes (no `[tekhton]`
  tagged debug lines)
- `TEKHTON_LOG_LEVEL=verbose` adds context economics and model details
- `TEKHTON_LOG_LEVEL=debug` shows everything (identical to current V3 output)
- Debug log always written to `.claude/logs/run_<RUN_ID>.log` regardless of level
- Structured events always written to `.claude/logs/run_<RUN_ID>.events.jsonl`
- Symlink `.claude/logs/latest.log` points to most recent run
- Log rotation retains last `TEKHTON_LOG_RETENTION` runs (default 50)
- `emit_event()` produces valid JSONL with `ts`, `type`, `run_id`, `data` fields
- Stage banners render consistently: `── Stage ──── Stage N/M` format
- Existing `log_info()` / `log_warn()` calls map to `log_default()` — no breaks
- All existing tests pass
- `bash -n lib/logging.sh` and `shellcheck lib/logging.sh` pass

Watch For:
- High-frequency `emit_event()` calls must not slow the pipeline. Use append-only
  writes (no file locking). JSONL is naturally append-safe.
- `date -u +%Y-%m-%dT%H:%M:%SZ` — the `-u` flag for UTC is critical for
  consistent timestamps across timezones. macOS `date` supports this.
- Log file directory must be created at startup if missing, not assumed to exist.
- The `latest.log` symlink must use relative paths for portability.

Seeds Forward:
- Every subsequent milestone emits structured events automatically
- Watchtower server (M11) reads the events.jsonl stream
- Log shipping (M19) forwards the events.jsonl to DataDog/Splunk
- NFR checks (M20) emit `nfr.check` / `nfr.violation` events

---

### DOGFOOD CHECKPOINT 1: Foundation Complete (After M02)

**Action:** Replace the working Tekhton copy with the latest V4 build.

**What's new:**
- Test harness ensures self-tests are more robust (no more zombie processes)
- Three-tier logging means building M03+ produces cleaner default output
- Debug log always captured to disk for post-mortem analysis

**What to verify after upgrade:**
- `bash tests/run_tests.sh` passes with new harness
- Default CLI output shows stage banners (not debug tags)
- `.claude/logs/` directory populates with run logs

**Safe rollback:** `git checkout v3.XX.0 -- tekhton.sh lib/ stages/` restores
V3 behavior. New files (`lib/logging.sh`, `lib/test_harness.sh`) are harmless
if unused.

**Risk:** Low — purely additive improvements to existing infrastructure. No
behavioral changes to agent invocation or pipeline flow.

---

#### Milestone 3: Bridge Core Architecture & Shell Routing

**Parallel group:** bridge | **Depends on:** M02

Files to create/modify:
- Create `tools/bridge/__init__.py`
- Create `tools/bridge/bridge.py` — CLI entry point
  (`tekhton-bridge call`, `tekhton-bridge calibrate`, `tekhton-bridge list-models`,
  `tekhton-bridge update-pricing`)
- Create `tools/bridge/types.py` — `AgentRequest`, `AgentResponse`, `ModelInfo`,
  `ProviderStatus`, `ProviderProfile`
- Create `tools/bridge/providers/__init__.py` — adapter registry + discovery
- Create `tools/bridge/providers/base.py` — `ProviderAdapter` base class
- Modify `lib/agent.sh` — add `_resolve_provider()` routing, bridge invocation
  path alongside existing `claude` CLI path
- Modify `lib/config_defaults.sh` — add `BRIDGE_ENABLED`, `BRIDGE_DEFAULT_PROVIDER`,
  per-stage provider overrides
- Create `tools/bridge/requirements.txt` — bridge Python dependencies
- Create `tools/tests/test_bridge_core.py` — types, CLI parsing, adapter registry
- Create `tests/test_bridge_routing.sh` — shell-side provider resolution

Acceptance criteria:
- `_resolve_provider("opus")` returns `anthropic`
- `_resolve_provider("gpt-4o")` returns `openai`
- `_resolve_provider("ollama/llama3")` returns `ollama`
- When `BRIDGE_ENABLED=false`, all calls go through `claude` CLI (V3 behavior)
- When `BRIDGE_ENABLED=true` and provider is `anthropic`, still uses `claude` CLI
- When `BRIDGE_ENABLED=true` and provider is non-anthropic, calls `tekhton-bridge`
- `tekhton-bridge call --help` shows usage without errors
- `ProviderAdapter` base class defines: `call()`, `count_tokens()`,
  `list_models()`, `supports_tool_use()`, `supports_mcp()`, `health_check()`
- Adapter registry discovers providers from `providers/` directory automatically
- `python3 -m pytest tools/tests/test_bridge_core.py` passes
- All existing tests pass
- `shellcheck lib/agent.sh` passes

Watch For:
- The bridge subprocess must inherit the project's environment (API keys, paths)
  but not leak sensitive vars in debug output. Sanitize key display.
- `tekhton-bridge` must be invocable both as `python3 -m tools.bridge.bridge`
  and as a standalone script. Support both patterns.
- Provider resolution must be deterministic — no ambiguous model names that
  could map to multiple providers.

Seeds Forward:
- M04 and M05 implement concrete adapters against this base
- M06 adds failover logic to the bridge core
- M07 adds MCP gateway capability
- M14 (NL task decomposition) uses bridge for non-Anthropic PM agents

---

#### Milestone 4: Anthropic Direct API Adapter

**Parallel group:** bridge | **Depends on:** M03

Files to create/modify:
- Create `tools/bridge/providers/anthropic.py` — Anthropic SDK adapter
  (direct API calls, not claude CLI)
- Update `tools/bridge/requirements.txt` — add `anthropic` SDK
- Create `tools/tests/test_provider_anthropic.py` — unit tests with mocked API
- Modify `tools/bridge/bridge.py` — register anthropic adapter

Acceptance criteria:
- `tekhton-bridge call --provider anthropic --model claude-sonnet-4-6
  --prompt-file /tmp/test.md` produces valid agent output
- Adapter uses Anthropic SDK directly (not claude CLI subprocess)
- Token counting uses Anthropic's tokenizer when available, falls back to
  chars/4 estimation
- Tool use / function calling works through the adapter
- Streaming output is supported (tokens stream to stdout as they arrive)
- `health_check()` validates API key and returns quota/rate limit info
- `list_models()` returns available Anthropic models
- Error handling: rate limits → retry with backoff, auth errors → clear message,
  network errors → transient classification
- `python3 -m pytest tools/tests/test_provider_anthropic.py` passes
- All existing tests pass

Watch For:
- Anthropic SDK version pinning — the API changes frequently. Pin to a specific
  minor version in requirements.txt.
- Extended thinking and prompt caching are Anthropic-specific features. The
  adapter should support them when the model allows, but the bridge interface
  must not require them (other providers won't have them).
- Streaming token counting requires accumulating tokens as they arrive. Don't
  count after-the-fact from the final output.

Seeds Forward:
- M06 uses this adapter as the failover target when claude CLI is throttled
- The adapter validates the bridge architecture before adding more providers
- Direct API access enables future features (batching, prompt caching control)

---

#### Milestone 5: OpenAI & Ollama Adapters

**Parallel group:** bridge | **Depends on:** M03

Files to create/modify:
- Create `tools/bridge/providers/openai.py` — OpenAI SDK adapter
- Create `tools/bridge/providers/ollama.py` — Ollama REST API adapter
- Create `tools/bridge/providers/openai_compat.py` — generic OpenAI-compatible
  endpoint adapter (Together, Groq, vLLM, Azure OpenAI)
- Update `tools/bridge/requirements.txt` — add `openai` SDK
- Create `tools/tests/test_provider_openai.py` — unit tests with mocked API
- Create `tools/tests/test_provider_ollama.py` — unit tests with mocked API
- Create `tools/tests/test_provider_compat.py` — generic adapter tests

Acceptance criteria:
- `tekhton-bridge call --provider openai --model gpt-4o --prompt-file /tmp/test.md`
  produces valid agent output (with mocked API in tests)
- `tekhton-bridge call --provider ollama --model llama3 --prompt-file /tmp/test.md`
  produces valid agent output (with mocked API in tests)
- OpenAI adapter supports: GPT-4o, GPT-4-turbo, o1, o3 model families
- Ollama adapter connects to local Ollama instance (configurable host/port)
- OpenAI-compatible adapter works with any endpoint that implements the OpenAI
  chat completions API format
- Tool use / function calling works on OpenAI (native) and Ollama (when model
  supports it; prompt-based fallback when not)
- `list_models()` queries each provider for available models
- `health_check()` validates connectivity and credentials
- `python3 -m pytest tools/tests/test_provider_*.py` passes
- All existing tests pass

Watch For:
- Ollama's tool use support varies by model. The adapter must detect capability
  and fall back gracefully to prompt-based tool injection.
- OpenAI's function calling format differs from Anthropic's tool use format.
  The adapter must normalize both directions (request and response).
- Azure OpenAI uses a different auth mechanism (API key in header vs bearer
  token) and different endpoint URL format. The compat adapter must handle both.
- Ollama may not be running — `health_check()` must return a clear "not available"
  status, not crash.

Seeds Forward:
- M06 uses these adapters for failover targets
- M07 adds MCP gateway capability to these adapters
- Users can immediately start using OpenAI or local models for any stage

---

#### Milestone 6: Provider Failover, Calibration & Cost Ledger

**Parallel group:** bridge | **Depends on:** M04, M05

Files to create/modify:
- Create `tools/bridge/failover.py` — failover logic, provider health monitoring,
  automatic switching
- Create `tools/bridge/calibration.py` — provider profile generation, prompt
  adjustment recording, validation
- Create `tools/bridge/cost.py` — cost calculation, pricing tables, ledger
  management, `update-pricing` command
- Create `.claude/bridge/` directory structure (profiles/, cost_ledger.jsonl)
- Modify `tools/bridge/bridge.py` — integrate failover, calibration, cost tracking
- Modify `lib/config_defaults.sh` — add `BRIDGE_FAILOVER_ENABLED`,
  `BRIDGE_FAILOVER_PROVIDER`, `BRIDGE_COST_TRACKING`
- Create `tools/tests/test_failover.py` — failover scenarios
- Create `tools/tests/test_calibration.py` — profile generation
- Create `tools/tests/test_cost.py` — cost calculation, ledger format
- Create `tests/test_bridge_cost.sh` — shell-side cost ledger verification

Acceptance criteria:
- `tekhton-bridge calibrate --provider openai` runs representative prompts,
  stores profile in `.claude/bridge/profiles/openai.json`
- Provider profile contains prompt adjustments (if any), quality score, and
  validation timestamp
- When primary provider returns rate limit error and failover is enabled, bridge
  automatically switches to secondary provider
- Failover applies pre-computed profile adjustments to prompts
- Failover is logged as `agent.failover` event in structured log
- Cost ledger records every invocation: timestamp, run_id, stage, provider,
  model, input/output tokens, cost_usd, duration_ms
- `tekhton-bridge update-pricing` refreshes pricing tables
- Cost calculation uses provider-specific pricing (Anthropic, OpenAI, Ollama=$0)
- When no calibration profile exists for failover provider, conservative defaults
  are applied and run is flagged as `degraded-provider`
- `python3 -m pytest tools/tests/test_failover.py test_calibration.py test_cost.py`
  passes
- All existing tests pass

Watch For:
- Failover must not create infinite loops — if secondary also fails, report
  error clearly rather than bouncing between providers.
- Cost pricing tables become stale. Ship with current prices at release time,
  but `update-pricing` must be able to refresh from a maintained source.
- Calibration prompts must be representative but small — 5 prompts, not 50.
  The calibration run should complete in under 5 minutes.
- Cost ledger JSONL must be append-only and never rewritten (data integrity).

Seeds Forward:
- M10 (parallel budgeting) distributes quota using cost ledger data
- M13 (Watchtower cost dashboard) reads the cost ledger
- M16 (cost forecasting) uses historical cost data for predictions
- M20 (NFR cost checks) validates against cost ceilings from the ledger

---

#### Milestone 7: MCP Gateway for Non-Anthropic Providers

**Parallel group:** bridge | **Depends on:** M05

Files to create/modify:
- Create `tools/bridge/mcp_gateway.py` — MCP client implementation (JSON-RPC),
  tool definition translation, response normalization
- Modify `tools/bridge/providers/openai.py` — integrate MCP gateway for tool calls
- Modify `tools/bridge/providers/ollama.py` — integrate MCP gateway for tool calls
- Modify `tools/bridge/providers/openai_compat.py` — MCP gateway integration
- Modify `lib/config_defaults.sh` — add `BRIDGE_MCP_GATEWAY`
- Create `tools/tests/test_mcp_gateway.py` — MCP protocol tests, translation tests

Acceptance criteria:
- MCP gateway connects to configured MCP servers using same config format as
  claude CLI (`.claude/mcp_servers.json` or equivalent)
- MCP tool definitions are translated to OpenAI function calling format for
  OpenAI adapter
- MCP tool definitions are translated to prompt-based tool injection for models
  without native tool calling
- Tool call results from the model are translated back to MCP response format
- Gateway handles MCP server lifecycle (start, health check, reconnect)
- For models that don't support tool use at all, MCP tools are presented as
  context in the system prompt (read-only mode)
- `python3 -m pytest tools/tests/test_mcp_gateway.py` passes
- All existing tests pass

Watch For:
- MCP servers may have startup latency. The gateway must wait for readiness
  before declaring tools available.
- MCP tool schemas can be complex (nested objects, arrays). Translation to
  OpenAI's function schema must handle all JSON Schema types.
- Some MCP servers are stateful (Serena LSP). The gateway must maintain a
  single connection per server, not reconnect per tool call.
- Error handling: if an MCP server crashes mid-run, the gateway must report
  the failure clearly rather than hanging.

Seeds Forward:
- Enterprise users get cross-repo awareness on all providers (not just Anthropic)
- Future MCP ecosystem tools (databases, APIs, docs) work with any provider
- V5's B1 bridge (full CLI replacement) builds on this gateway

---

### DOGFOOD CHECKPOINT 2: Bridge Complete (After M07)

**Action:** Replace the working Tekhton copy with the latest V4 build.

**What's new:**
- Full multi-provider support (Anthropic, OpenAI, Ollama)
- If Anthropic throttles during M08+ development, failover kicks in
- Cost tracking is active — see what building Tekhton costs per milestone
- MCP works on all providers (cross-repo awareness preserved)

**What to verify after upgrade:**
- `BRIDGE_ENABLED=true` in pipeline.conf
- `tekhton-bridge call --provider anthropic --model sonnet --prompt-file /tmp/test.md`
  works (validates bridge installation)
- Optional: configure `BRIDGE_FAILOVER_PROVIDER=openai` for resilience
- `.claude/bridge/cost_ledger.jsonl` populates after a run

**Safe rollback:** Set `BRIDGE_ENABLED=false` — all calls revert to claude CLI.
Bridge code is dormant when disabled.

**Risk:** Medium — bridge is new code, but the Anthropic path through claude CLI
is unchanged (B2 architecture). Failover is opt-in.

---

### Phase 2: Core Capabilities (M08-M16)

#### Milestone 8: Parallel Coordinator & Worktree Lifecycle

**Parallel group:** parallel | **Depends on:** M02

Files to create/modify:
- Create `lib/parallel.sh` — coordinator loop, team spawning, wave management,
  progress polling, `run_parallel_execution()`
- Create `lib/parallel_teams.sh` — `_create_team_worktree()`,
  `_remove_team_worktree()`, team status files, team pipeline invocation
- Modify `lib/config_defaults.sh` — add `PARALLEL_ENABLED`, `PARALLEL_MAX_TEAMS`,
  `PARALLEL_WORKTREE_DIR`
- Modify `tekhton.sh` — source parallel modules, parallel mode detection
- Create `tests/test_parallel_basic.sh` — worktree creation/removal, coordinator
  skeleton, team status file format

Acceptance criteria:
- `_create_team_worktree(1, "m05")` creates a git worktree at
  `.claude/worktrees/team-1/` on branch `tekhton/parallel/m05`
- Team status files (`TEAM_STATUS.json`) written with: team_id, milestone_id,
  stage, started_at, status
- Coordinator reads DAG frontier, groups by parallel_group, spawns teams up to
  `PARALLEL_MAX_TEAMS`
- Each team runs a full pipeline (coder → reviewer → tester) in its worktree
- `_remove_team_worktree()` cleans up worktree and branch
- `PARALLEL_ENABLED=false` (default) gives identical V3 serial behavior
- `PARALLEL_MAX_TEAMS=1` gives serial behavior through the parallel engine
- All existing tests pass
- `bash -n lib/parallel.sh lib/parallel_teams.sh` passes
- `shellcheck lib/parallel.sh lib/parallel_teams.sh` passes

Watch For:
- Git worktree creation fails if the branch already exists (leftover from
  previous run). Check and clean up stale worktrees at startup.
- Each team's pipeline invocation must use the worktree as `PROJECT_DIR`, not
  the main repo root. All path resolution must be worktree-aware.
- Team subshells must not share file descriptors or FIFOs with the coordinator.
  Each team gets its own FIFO for agent communication.

Seeds Forward:
- M09 adds conflict detection and merge strategies
- M10 adds resource budgeting and shared build gate
- M13 adds Watchtower visualization of parallel teams

---

#### Milestone 9: Parallel Conflict Detection & Merge

**Parallel group:** parallel | **Depends on:** M08

Files to create/modify:
- Modify `lib/parallel.sh` — merge orchestration after teams complete
- Modify `lib/parallel_teams.sh` — `_merge_team_result()`,
  `_detect_conflicts()`, sequential fallback logic
- Modify `lib/config_defaults.sh` — add `PARALLEL_CONFLICT_STRATEGY`
- Create `tests/test_parallel_merge.sh` — conflict scenarios, merge strategies

Acceptance criteria:
- `_detect_conflicts(team_a, team_b)` compares `git diff --name-only` outputs
  and reports overlapping files
- Non-overlapping changes in the same file → git auto-merge succeeds
- Overlapping changes → sequential fallback (merge earlier team first, re-run
  later team on merged base)
- `PARALLEL_CONFLICT_STRATEGY=sequential` re-runs conflicting milestone
- `PARALLEL_CONFLICT_STRATEGY=human` writes to HUMAN_ACTION_REQUIRED.md
- `PARALLEL_CONFLICT_STRATEGY=abort` stops with clear error message
- Merge commits use format: `Merge milestone <id> from parallel team <n>`
- Failed merges are logged as `parallel.conflict` events
- All existing tests pass

Watch For:
- `git merge --abort` must be called if merge fails, otherwise the repo is left
  in a dirty merge state.
- Sequential fallback means re-running an entire milestone — this could be
  expensive. Log the cost clearly so users can decide if parallelism is worth it.
- Three-way merges can produce unexpected results with generated code. Consider
  a post-merge build gate (M10) as the safety net.

Seeds Forward:
- M10 adds shared build gate after merge to catch subtle merge issues
- V5's stage-level parallelism will reuse conflict detection infrastructure

---

#### Milestone 10: Parallel Resource Budgeting & Shared Build Gate

**Parallel group:** parallel | **Depends on:** M06, M09

Files to create/modify:
- Create `lib/parallel_budget.sh` — quota distribution strategies (equal,
  weighted, priority), budget tracking, pause/resume on exhaustion
- Modify `lib/parallel.sh` — shared build gate after group merge,
  `_parallel_group_gate()`, `_bisect_build_failure()`
- Modify `lib/config_defaults.sh` — add `PARALLEL_QUOTA_STRATEGY`,
  `PARALLEL_SHARED_GATE`, `PARALLEL_BISECT_ON_FAILURE`
- Create `tests/test_parallel_budget.sh` — quota distribution, gate scenarios

Acceptance criteria:
- `equal` strategy: each team gets `1/N` of total budget
- `weighted` strategy: budget proportional to scout complexity estimate
- `priority` strategy: highest-priority milestone gets full budget, others
  get remainder
- When a team exhausts its budget, it pauses until other teams complete
- After all teams in a parallel group merge, shared build gate validates
  combined result
- If shared gate fails, `_bisect_build_failure()` identifies which team's
  changes broke the build (binary search on team merge order)
- Budget tracking integrates with cost ledger (M06) for actual cost data
- All existing tests pass

Watch For:
- Budget exhaustion + pause can create deadlocks if all teams pause
  simultaneously. The coordinator must detect this and release budget from
  the lowest-priority team.
- Build gate bisection requires selectively reverting team merges — this must
  use temporary branches, not destructive operations on the main branch.
- Scout estimates may not be available for all milestones. Fallback to equal
  distribution when weighted is configured but estimates are missing.

Seeds Forward:
- M13 displays budget allocation and consumption in Watchtower
- V5's quota intelligence shares pools across parallel workers

---

#### Milestone 11: Watchtower Server Mode & WebSocket

**Parallel group:** watchtower | **Depends on:** M02

Files to create/modify:
- Create `tools/watchtower_server.py` — HTTP server, WebSocket, file watcher,
  REST API endpoints, SSE event stream
- Modify `lib/dashboard.sh` — `_watchtower_serve()`, `_watchtower_stop()`,
  `_watchtower_status()`, PID management
- Modify `lib/config_defaults.sh` — add `WATCHTOWER_SERVE_ENABLED`,
  `WATCHTOWER_PORT`, `WATCHTOWER_API_ENABLED`, `WATCHTOWER_WS_ENABLED`
- Modify `tekhton.sh` — `--watchtower-serve`, `--watchtower-stop`,
  `--watchtower-status` commands, auto-start when config enabled
- Modify `templates/watchtower/app.js` — WebSocket client, replace polling with
  push updates when server is available, fallback to polling when not
- Create `tools/tests/test_watchtower_server.py` — API endpoint tests, WebSocket tests
- Create `tests/test_watchtower_serve.sh` — server lifecycle, PID management

Acceptance criteria:
- `tekhton --watchtower-serve` starts server on configured port (default 8420)
- `WATCHTOWER_SERVE_ENABLED=true` auto-starts server with pipeline
- `GET /` serves the dashboard HTML/JS/CSS
- `GET /api/v1/runs/latest` returns current run state as JSON
- `GET /api/v1/milestones` returns milestone DAG and statuses
- WebSocket at `/ws` pushes real-time events as they occur
- SSE at `/api/v1/events/stream` provides alternative to WebSocket
- File watcher monitors `.claude/watchtower/*.json` and `.claude/logs/events.jsonl`
- Dashboard auto-detects server vs static mode (WebSocket vs polling)
- `tekhton --watchtower-stop` cleanly shuts down server
- Server PID tracked in `.claude/watchtower.pid`
- All existing tests pass

Watch For:
- Port already in use — detect and report clearly, suggest alternative port.
- Server must not block the pipeline. It runs as a background process.
- WebSocket connections from stale browser tabs — implement heartbeat/ping.
- Static mode must continue to work when server is not running. The dashboard
  detects which mode is available and adapts.

Seeds Forward:
- M12 adds interactive controls through the REST API
- M13 adds cost dashboard and parallel team views
- M19 CI/CD mode may disable served Watchtower (headless environment)

---

#### Milestone 12: Watchtower Interactive Controls

**Parallel group:** watchtower | **Depends on:** M11

Files to create/modify:
- Modify `tools/watchtower_server.py` — add POST endpoints for task submission,
  note submission, milestone management, run control
- Create `lib/inbox.sh` — `_process_inbox()`, inbox file format, task/note/control
  enqueueing
- Modify `lib/orchestrate.sh` — call `_process_inbox()` at startup and between stages
- Modify `templates/watchtower/app.js` — task submission form, milestone manager
  UI, run control buttons (pause/resume/abort)
- Modify `templates/watchtower/index.html` — interactive control panels
- Modify `lib/config_defaults.sh` — add `WATCHTOWER_INBOX_ENABLED`,
  `WATCHTOWER_INBOX_DIR`
- Create `tests/test_inbox.sh` — inbox processing, file format validation

Acceptance criteria:
- Task submission form in Watchtower creates
  `.claude/inbox/task_<timestamp>.json`
- Note submission form creates `.claude/inbox/note_<timestamp>.json`
- Run control (pause/resume/abort) creates `.claude/inbox/control_<timestamp>.json`
- `_process_inbox()` reads and processes inbox files at pipeline checkpoints
- Processed files moved to `.claude/inbox/processed/`
- Milestone manager allows: status override, title editing, dependency editing
- POST endpoints validate input and return appropriate HTTP status codes
- Pause/resume uses a flag file that stages check between operations
- Abort triggers graceful shutdown with state save
- All existing tests pass

Watch For:
- Race condition: Watchtower writes inbox file while pipeline reads it. Use
  atomic write (tmpfile + rename) for inbox files.
- Pause must not interrupt a running agent mid-invocation. It takes effect
  between stages, not mid-stage.
- Milestone editing through Watchtower must write to both the milestone file
  AND the manifest. Use existing `save_manifest()` for atomicity.

Seeds Forward:
- M13 adds cost and parallel views to the interactive UI
- M14 (NL task decomposition) can be triggered from Watchtower's task form
- M17 (GitHub integration) can sync issues to Watchtower's task queue

---

#### Milestone 13: Watchtower Cost Dashboard & Parallel Team View

**Parallel group:** watchtower | **Depends on:** M06, M10, M12

Files to create/modify:
- Modify `tools/watchtower_server.py` — add `GET /api/v1/costs` (cost ledger
  summary, per-stage, per-provider, per-model), `GET /api/v1/teams` (parallel
  team status)
- Modify `templates/watchtower/app.js` — cost dashboard panel (charts, trends,
  budget alerts), parallel team view (team cards, swimlanes, merge status)
- Modify `templates/watchtower/style.css` — cost and parallel view styling
- Create `tests/test_watchtower_cost.sh` — cost API, team status API

Acceptance criteria:
- Cost dashboard shows: per-run breakdown, per-stage costs, per-provider costs,
  cumulative project cost with trend line
- Budget alerts display when cost exceeds configurable threshold percentage
- Parallel team view shows: team cards with stage progress, unified timeline
  with team swimlanes, conflict alerts, merge status
- Cost data sourced from `.claude/bridge/cost_ledger.jsonl`
- Team data sourced from `.claude/worktrees/team-N/TEAM_STATUS.json`
- Dashboard gracefully handles missing data (no cost ledger = no cost panel,
  no parallel teams = no team view)
- Test quarantine status (from M01) displayed in Reports tab
- All existing tests pass

Watch For:
- Cost ledger can grow large over many runs. The API should support pagination
  and date range filtering, not load the entire file.
- Parallel team view must handle teams completing at different rates — the
  UI updates incrementally as each team progresses.
- Chart rendering should use lightweight JS (no heavy charting library). CSS
  bar charts and simple SVG are sufficient for V4.

Seeds Forward:
- M16 (cost forecasting) adds prediction data to the cost dashboard
- V5's cloud-hosted Watchtower reuses these API endpoints and UI components

---

### DOGFOOD CHECKPOINT 3: Parallel Ready (After M10)

**Action:** Optionally enable parallel execution for remaining milestones.

**What's new:**
- Parallel milestone execution via git worktrees
- Conflict detection and merge strategies
- Resource budgeting across teams

**What to verify after upgrade:**
- `PARALLEL_ENABLED=true` and `PARALLEL_MAX_TEAMS=2` in pipeline.conf
- Run two independent milestones — verify both complete and merge cleanly
- Check `.claude/worktrees/` cleanup after run

**Safe rollback:** Set `PARALLEL_ENABLED=false` — reverts to serial execution.

**Risk:** Higher — parallel execution is complex. Start with `PARALLEL_MAX_TEAMS=2`
to limit blast radius. If unstable, revert to serial for remaining milestones.

---

#### Milestone 14: Natural Language Task Decomposition

**Parallel group:** owner | **Depends on:** M03

Files to create/modify:
- Modify `lib/intake_helpers.sh` — extend PM agent to accept natural language
  input, decompose into milestones with acceptance criteria
- Modify `stages/intake.sh` — natural language detection, decomposition flow
- Modify `prompts/intake.prompt.md` — add NL decomposition instructions,
  examples of input→milestone transformation
- Modify `lib/config_defaults.sh` — add `PM_NATURAL_LANGUAGE`,
  `PM_AUTO_DECOMPOSE`
- Create `tests/test_intake_nl.sh` — NL detection, decomposition format

Acceptance criteria:
- PM agent accepts natural language input like "I want a login page with email
  and social sign-in" and decomposes into concrete milestones
- Each generated milestone has: title, description, file list, acceptance
  criteria, test requirements
- Decomposition uses project context (CLAUDE.md, DESIGN.md, detected stack) to
  ground milestones in the project's architecture
- Generated milestones are written to `.claude/milestones/` and MANIFEST.cfg
  in proper DAG format
- `PM_AUTO_DECOMPOSE=true` automatically generates milestones from NL input
- `PM_AUTO_DECOMPOSE=false` presents proposed milestones for user approval
- Existing precise engineering task descriptions still work (backward compatible)
- All existing tests pass

Watch For:
- NL decomposition quality varies by model. The PM prompt must include 2-3
  concrete examples of input→output transformations.
- Over-decomposition risk: "add a button" shouldn't become 5 milestones.
  Include guidance on appropriate granularity.
- The PM agent must respect the project's existing milestone numbering. New
  milestones get IDs after the highest existing one.

Seeds Forward:
- Watchtower's task form (M12) triggers NL decomposition when user submits
  natural language
- V5's "Maximum" scope builds on this for full product requirement → deployment

---

#### Milestone 15: Release Notes & Changelog Automation

**Parallel group:** owner | **Depends on:** M02

Files to create/modify:
- Create `lib/release.sh` — `_generate_release_notes()`,
  `_update_changelog()`, `_generate_deliverable_summary()`
- Modify `lib/finalize.sh` — call release note generation after milestone
  completion
- Modify `lib/finalize_display.sh` — project-owner-friendly completion banner
  (what was built, what to review, files changed, tests status)
- Modify `lib/config_defaults.sh` — add `RELEASE_NOTES_ENABLED`,
  `CHANGELOG_ENABLED`, `CHANGELOG_FILE`, `DELIVERABLES_DIR`
- Create `tests/test_release.sh` — release note format, changelog format,
  deliverable package contents

Acceptance criteria:
- After milestone completion, release notes generated at
  `.claude/deliverables/release_<milestone_id>.md`
- Release notes contain: what's new (non-technical), setup required, technical
  details (files changed, tests added)
- Changelog entry appended to CHANGELOG.md in Keep a Changelog format
- Completion banner shows plain-language summary: task, status, duration, cost
  (if available), what was built, what to review
- Deliverable package (`.claude/deliverables/`) contains: summary.md,
  release_notes.md, changelog_entry.md, test_report.md, diff_summary.md
- `RELEASE_NOTES_ENABLED=false` skips generation (backward compatible)
- All existing tests pass

Watch For:
- Release notes are generated from git diffs and stage reports, NOT from an
  additional agent call. Keep it cheap. An optional agent polish pass can be
  added later.
- CHANGELOG.md must be appended to, not overwritten. Check for existing content.
- The completion banner must fit in a standard terminal width (80 chars).

Seeds Forward:
- M16 adds cost data to release notes and deliverables
- M17 (GitHub integration) uses release notes for GitHub Releases
- Watchtower Reports tab can display deliverable summaries

---

#### Milestone 16: Cost Forecasting & Deliverable Packages

**Parallel group:** owner | **Depends on:** M06, M15

Files to create/modify:
- Modify `lib/release.sh` — add `_forecast_cost()`, integrate cost data into
  release notes and deliverables
- Modify `tools/watchtower_server.py` — add `GET /api/v1/costs/forecast`
- Modify `lib/finalize_display.sh` — add cost summary to completion banner
- Create `lib/cost_forecast.sh` — historical analysis, per-milestone averaging,
  complexity-weighted prediction
- Modify `lib/config_defaults.sh` — add `COST_FORECAST_ENABLED`
- Create `tests/test_cost_forecast.sh` — forecast accuracy, edge cases

Acceptance criteria:
- `_forecast_cost()` estimates remaining project cost from: historical
  cost-per-milestone average, remaining milestone count, scout complexity
  estimates
- Cost summary in completion banner: "Duration: 47m | Cost: $8.40"
- Release notes include cost section: "This milestone cost $X.XX"
- Deliverables include `cost_report.json` with detailed breakdown
- Cost forecast available via Watchtower API: estimated remaining cost,
  estimated total project cost, cost trend (per-milestone)
- Forecast accuracy improves with more historical data (first run uses
  scout estimates only, subsequent runs blend actuals)
- `COST_FORECAST_ENABLED=false` disables forecasting
- All existing tests pass

Watch For:
- First-run forecasts are necessarily inaccurate. Display with appropriate
  confidence indicators ("estimated" vs "based on N prior runs").
- Cost data may not be available if `BRIDGE_COST_TRACKING=false`. Forecast
  must degrade gracefully (show "cost tracking disabled" not an error).

Seeds Forward:
- M13 (Watchtower cost dashboard) displays forecast alongside actuals
- M20 (NFR cost checks) uses forecast data for budget ceiling warnings

---

### DOGFOOD CHECKPOINT 4: Core Complete (After M16)

**Action:** Replace the working Tekhton copy with the latest V4 build.

**What's new:**
- Full V4 experience: parallel execution, interactive Watchtower, cost tracking,
  release notes, natural language task intake
- Building Phase 3-4 with complete project owner tooling active
- Cost forecasting shows what remaining milestones will cost

**What to verify after upgrade:**
- Watchtower served mode active (`WATCHTOWER_SERVE_ENABLED=true`)
- Submit a test task via Watchtower UI — verify inbox processing
- Check cost dashboard after a run — verify ledger data flows through
- Release notes generated in `.claude/deliverables/`

**Safe rollback:** Disable individual features via config. Each feature has its
own `_ENABLED=false` toggle. No all-or-nothing dependency.

**Risk:** Low — Watchtower improvements don't affect pipeline execution. Release
notes and cost tracking are additive outputs.

---

### Phase 3: Enterprise & Integration (M17-M23)

#### Milestone 17: GitHub Integration

**Parallel group:** integration | **Depends on:** M02, M15

Files to create/modify:
- Create `lib/integrations/github.sh` — `_integration_github_init()`,
  `_integration_github_on_event()`, `_integration_github_pull_issues()`,
  PR creation, issue commenting, release creation
- Create `lib/integrations/adapter.sh` — base integration interface,
  event dispatch, adapter registration
- Modify `lib/config_defaults.sh` — add `INTEGRATION_GITHUB_ENABLED`,
  `INTEGRATION_GITHUB_TOKEN`, `INTEGRATION_GITHUB_REPO`, etc.
- Modify `lib/finalize.sh` — dispatch `milestone.complete` and `pipeline.complete`
  events to registered integrations
- Create `tests/test_integration_github.sh` — event dispatch, PR format, issue
  comment format

Acceptance criteria:
- On `milestone.complete`: creates PR with milestone changes (if configured)
- On `milestone.complete`: comments on linked GitHub issue with summary
- On `pipeline.fail`: comments on linked issue with failure details
- On `release.ready`: creates GitHub Release with release notes (from M15)
- `_integration_github_pull_issues()` fetches issues with configurable label
  filter (default: "tekhton") and queues them as tasks
- Integration uses `gh` CLI or GitHub API directly (curl) — whichever is available
- `INTEGRATION_GITHUB_AUTO_PR=true` creates PRs automatically
- `INTEGRATION_GITHUB_AUTO_RELEASE=true` creates releases automatically
- `INTEGRATION_GITHUB_ENABLED=false` disables all GitHub integration
- Adapter base interface supports: `_init()`, `_on_event()`, `_health()`
- All existing tests pass
- `shellcheck lib/integrations/github.sh lib/integrations/adapter.sh` passes

Watch For:
- GitHub token permissions vary. PR creation requires `repo` scope, issue
  comments require `issues` scope. Validate permissions at init and report
  clearly what's missing.
- Rate limiting on GitHub API — implement backoff. Don't fail the pipeline
  because GitHub is slow.
- PR creation should be non-blocking — create the PR and continue. Don't wait
  for CI checks on the PR.

Seeds Forward:
- M19 (CI/CD mode) extends GitHub integration for Actions workflows
- Watchtower can display linked GitHub issues/PRs
- V5 adds bidirectional issue sync (GitHub → Tekhton task queue)

---

#### Milestone 18: Slack/Teams & Webhook Notifications

**Parallel group:** integration | **Depends on:** M02

Files to create/modify:
- Create `lib/integrations/slack.sh` — `_integration_slack_on_event()`,
  webhook posting, message formatting
- Create `lib/integrations/webhook.sh` — `_integration_webhook_on_event()`,
  generic HTTP POST with HMAC signing
- Modify `lib/integrations/adapter.sh` — register slack and webhook adapters
- Modify `lib/config_defaults.sh` — add `INTEGRATION_SLACK_ENABLED`,
  `INTEGRATION_SLACK_WEBHOOK_URL`, `INTEGRATION_WEBHOOK_ENABLED`, etc.
- Create `tests/test_integration_slack.sh` — message format, event filtering
- Create `tests/test_integration_webhook.sh` — payload format, signature

Acceptance criteria:
- Slack notifications sent on configurable events (default:
  `pipeline.complete,pipeline.fail,human.required`)
- Messages include: project name, event type, summary, action items
- Webhook sends JSON payload with `X-Tekhton-Event` header and HMAC signature
- `INTEGRATION_WEBHOOK_SECRET` used for HMAC-SHA256 signature generation
- Event filtering: `INTEGRATION_SLACK_EVENTS="*"` sends all,
  comma-separated list sends only those events
- Notification failures are logged but don't block the pipeline
- All existing tests pass
- `shellcheck lib/integrations/slack.sh lib/integrations/webhook.sh` passes

Watch For:
- Slack webhook URLs are secrets — never log them at any level. Mask in debug output.
- Microsoft Teams uses a different webhook format than Slack. Either support both
  or document Teams setup separately.
- Webhook HMAC signing must use the raw payload bytes, not a re-serialized version.

Seeds Forward:
- V5 adds rich Slack messages (blocks, attachments, thread replies)
- Webhook support enables integration with any tool that accepts HTTP callbacks

---

#### Milestone 19: Log Shipping & CI/CD Mode

**Parallel group:** integration | **Depends on:** M02

Files to create/modify:
- Create `lib/integrations/logging_ship.sh` — DataDog API shipping, Splunk HEC
  shipping, syslog forwarding, file-based agent pickup
- Create `lib/integrations/ci.sh` — CI environment detection, artifact output,
  exit code mapping, status check posting
- Modify `lib/config_defaults.sh` — add `INTEGRATION_LOG_SHIPPING`,
  `INTEGRATION_DATADOG_API_KEY`, `INTEGRATION_SPLUNK_HEC_URL`,
  `INTEGRATION_CI_MODE`, `INTEGRATION_CI_ARTIFACT_DIR`
- Modify `tekhton.sh` — CI mode detection (auto-detect from env vars),
  headless behavior adjustments
- Create `tests/test_integration_logging.sh` — shipping format, API payload
- Create `tests/test_integration_ci.sh` — CI detection, artifact output

Acceptance criteria:
- `INTEGRATION_LOG_SHIPPING=file` (default): structured events written to
  `.claude/logs/events.jsonl` for external agent pickup (DataDog/Splunk agents)
- `INTEGRATION_LOG_SHIPPING=datadog`: events batched and POSTed to DataDog
  Logs API with source=tekhton tag
- `INTEGRATION_LOG_SHIPPING=splunk`: events sent to Splunk HEC endpoint
- `INTEGRATION_LOG_SHIPPING=syslog`: events forwarded to syslog
- `INTEGRATION_CI_MODE=true` (or auto-detected from `CI`, `GITHUB_ACTIONS`,
  `GITLAB_CI` env vars): headless mode, no interactive prompts, structured
  output, artifacts written to `INTEGRATION_CI_ARTIFACT_DIR`
- CI mode exit codes: 0=success, 1=pipeline failure, 2=config error
- CI artifacts include: RUN_SUMMARY.json, deliverables, test reports
- Watchtower served mode disabled in CI (headless environment)
- All existing tests pass

Watch For:
- DataDog and Splunk have payload size limits. Batch events (100 per request
  or 1MB, whichever is smaller).
- CI environments may not have Python installed. Log shipping via curl (DataDog
  API, Splunk HEC) must work without the bridge.
- CI mode must detect and respect existing CI timeouts — don't let the pipeline
  run for 8 hours in a CI job with a 30-minute limit.

Seeds Forward:
- GitHub Actions marketplace action (future) wraps this CI mode
- V5 adds Prometheus metrics endpoint for Kubernetes monitoring

---

#### Milestone 20: NFR Engine & Cost/SLA Checks

**Parallel group:** nfr | **Depends on:** M02, M06

Files to create/modify:
- Create `lib/nfr.sh` — `run_nfr_checks()`, check engine, violation policy
  enforcement, anomaly detection
- Modify `lib/gates.sh` — integrate NFR checks into build gate and acceptance gate
- Modify `lib/orchestrate.sh` — cost ceiling checks after each agent invocation,
  SLA timeout checks continuously
- Modify `lib/config_defaults.sh` — add all `NFR_*` config keys (cost, SLA,
  policy defaults)
- Create `.claude/nfr.conf.example` — example NFR configuration
- Create `tests/test_nfr.sh` — check engine, violation policies, cost/SLA checks

Acceptance criteria:
- `run_nfr_checks("post-build")` runs all enabled checks for that timing point
- Cost ceiling check: blocks pipeline when actual cost exceeds
  `NFR_COST_MAX_PER_MILESTONE` (if policy=block)
- Cost alert: warns when cost exceeds `NFR_COST_ALERT_PCT` of ceiling
- SLA check: warns when milestone duration exceeds `NFR_SLA_MILESTONE_TIMEOUT_S`
- Stage timeout: warns when stage exceeds `NFR_SLA_STAGE_TIMEOUT_S`
- Violation policies: `block` stops pipeline, `warn` logs warning, `log` records silently
- `_check_pipeline_anomalies()` detects: stage 3x longer than historical average,
  cost per turn 2x higher than normal, max turns hit 3 consecutive times
- NFR events emitted: `nfr.check`, `nfr.violation`, `nfr.anomaly`
- All NFR checks disabled by default (`NFR_*_ENABLED=false`) — opt-in
- All existing tests pass
- `shellcheck lib/nfr.sh` passes

Watch For:
- Cost ceiling checks run after EVERY agent invocation. They must be extremely
  cheap (read last line of cost ledger, compare to threshold). No file scanning.
- SLA timeout must be non-blocking — run as a background timer, not a poll loop.
- Anomaly baselines require historical data. First N runs (configurable) use
  generous defaults until baselines are established.

Seeds Forward:
- M21 adds expensive NFR checks (performance, accessibility, coverage)
- M24 (learning) feeds anomaly patterns into the knowledge base

---

#### Milestone 21: NFR Performance, Accessibility, Coverage & License Checks

**Parallel group:** nfr | **Depends on:** M20

Files to create/modify:
- Create `lib/nfr_checks.sh` — individual check implementations for performance
  budgets, accessibility (axe/pa11y/lighthouse), test coverage, bundle size,
  license compliance
- Modify `lib/nfr.sh` — register new checks, timing-point assignment
- Modify `lib/config_defaults.sh` — add `NFR_PERF_*`, `NFR_A11Y_*`,
  `NFR_COVERAGE_*`, `NFR_LICENSE_*`, `NFR_BUNDLE_*` config keys
- Create `tests/test_nfr_checks.sh` — individual check validation

Acceptance criteria:
- Performance budget: runs configured perf test command, checks against thresholds
  (page load, API response time, bundle size)
- Accessibility: invokes configured a11y tool (axe/pa11y/lighthouse), checks
  against WCAG standard level
- Test coverage: reads coverage report (auto-detected format), checks against
  min line/branch percentage
- License compliance: scans dependency licenses, blocks on denied licenses
- Bundle size: checks output artifact size against threshold
- Each check runs at its designated timing point (post-build, post-test, etc.)
- Each check has its own enabled flag and violation policy
- Checks that require external tools (lighthouse, coverage reporter) fail
  gracefully when tool is not installed
- All existing tests pass

Watch For:
- Performance and accessibility checks may require a running application.
  If no start command is configured, skip with a clear message.
- Coverage report formats vary by language/tool (lcov, cobertura, istanbul,
  go cover). Auto-detection must handle the common ones.
- License scanning tools differ by ecosystem (license-checker for npm,
  cargo-deny for Rust, pip-licenses for Python). Support auto-detection.

Seeds Forward:
- V5 adds visual regression testing as an NFR check
- V5's health score incorporates NFR violation history

---

### DOGFOOD CHECKPOINT 5: Enterprise NFR Active (After M21)

**Action:** Enable NFR checks for remaining milestone development.

**What's new:**
- NFR framework catches cost overruns and SLA violations during builds
- Pipeline monitors itself for anomalous behavior

**What to verify after upgrade:**
- `NFR_COST_ENABLED=true` and `NFR_SLA_ENABLED=true` in pipeline.conf
- Set reasonable thresholds (e.g., `NFR_COST_MAX_PER_MILESTONE=25.00`,
  `NFR_SLA_MILESTONE_TIMEOUT_S=7200`)
- Run a milestone — verify NFR events in structured log

**Safe rollback:** Set `NFR_*_ENABLED=false` — all checks disabled.

**Risk:** Low — NFR policies default to `warn`, not `block`. Pipeline continues
even if thresholds are exceeded.

---

#### Milestone 22: Auth Abstraction & Local/Env Modes

**Parallel group:** auth | **Depends on:** M02

Files to create/modify:
- Create `lib/auth.sh` — `_auth_init()`, `_auth_get_identity()`,
  `_auth_enrich_event()`, provider abstraction, local/env mode implementations
- Modify `lib/logging.sh` — call `_auth_enrich_event()` in `emit_event()`
  to include identity in structured events
- Modify `lib/config_defaults.sh` — add `AUTH_ENABLED`, `AUTH_PROVIDER`,
  `AUTH_USER_ID`, `AUTH_ENV_USER_VAR`, `AUTH_AUDIT_IDENTITY`
- Create `.claude/auth.conf.example` — example auth configuration
- Create `tests/test_auth.sh` — identity resolution, event enrichment

Acceptance criteria:
- `AUTH_PROVIDER=local`: identity from `AUTH_USER_ID` config or `$USER` env var
- `AUTH_PROVIDER=env`: identity from configurable env vars (`AUTH_ENV_USER_VAR`,
  `AUTH_ENV_ROLE_VAR`)
- `_auth_get_identity()` returns JSON: `{"id":"...","provider":"...","role":"..."}`
- When `AUTH_AUDIT_IDENTITY=true`, all structured events include `user` field
- When `AUTH_ENABLED=false`, no identity enrichment (V3 behavior)
- Identity is recorded in RUN_SUMMARY.json
- Auth init validates configuration and reports missing/invalid settings clearly
- All existing tests pass
- `shellcheck lib/auth.sh` passes

Watch For:
- `$USER` may not be set in all environments (some containers, CI). Fall back
  to `$(whoami)` or `unknown`.
- Auth config should be in a separate file (`.claude/auth.conf`) not
  `pipeline.conf` — auth settings are sensitive and may have different
  access controls.

Seeds Forward:
- M23 adds OIDC token validation
- V5 adds full OAuth flow and RBAC enforcement
- All audit trail queries can filter by user identity

---

#### Milestone 23: OIDC Token Validation Stub

**Parallel group:** auth | **Depends on:** M22

Files to create/modify:
- Modify `lib/auth.sh` — add OIDC provider mode, JWT validation, issuer
  discovery, token file reading
- Modify `lib/config_defaults.sh` — add `AUTH_OIDC_ISSUER`,
  `AUTH_OIDC_CLIENT_ID`, `AUTH_OIDC_TOKEN_FILE`
- Create `tools/bridge/auth_oidc.py` — OIDC discovery, JWT signature
  validation, claims extraction (Python for crypto)
- Create `tools/tests/test_auth_oidc.py` — JWT validation, claims parsing
- Create `tests/test_auth_oidc.sh` — OIDC mode integration

Acceptance criteria:
- `AUTH_PROVIDER=oidc` reads JWT from `AUTH_OIDC_TOKEN_FILE`
- Token validation: checks signature against issuer's JWKS, validates expiry,
  validates audience (`AUTH_OIDC_CLIENT_ID`)
- Claims extracted: `sub` (user ID), `email`, `groups` or `roles`
- OIDC discovery fetches `.well-known/openid-configuration` from issuer URL
- Works with: Okta, Auth0, Microsoft Entra ID, PingID (all implement OIDC)
- Expired tokens produce clear error message with re-auth instructions
- Invalid tokens produce clear error (not a stack trace)
- V4 does NOT implement OAuth redirect flow — user provides pre-obtained token
- `python3 -m pytest tools/tests/test_auth_oidc.py` passes
- All existing tests pass

Watch For:
- JWKS (JSON Web Key Set) must be cached — don't fetch on every validation.
  Cache with TTL (default: 1 hour).
- Token file must be read-protected (0600 permissions). Warn if permissions
  are too open.
- Different OIDC providers put roles in different claims (`groups`, `roles`,
  `custom:roles`). Make the role claim name configurable.

Seeds Forward:
- V5 implements full OAuth redirect flow (consent, token exchange, refresh)
- V5 enforces RBAC based on roles extracted from OIDC claims

---

### Phase 4: Intelligence (M24-M27)

#### Milestone 24: Knowledge Base & Failure Pattern Recognition

**Parallel group:** learning | **Depends on:** M02, M06

Files to create/modify:
- Create `lib/learning.sh` — `_learning_init()`, `_record_run()`,
  `_calibrate_scout_estimate()`, `_classify_failure()`,
  `_record_new_failure()`, knowledge base file management
- Create `.claude/knowledge/` directory structure (run_history.jsonl,
  stage_performance.jsonl, failure_patterns.jsonl, task_complexity.jsonl)
- Modify `lib/finalize_summary.sh` — call `_record_run()` after each run
- Modify `lib/agent.sh` — call `_record_stage_performance()` after each stage
- Modify `stages/coder.sh` — use `_calibrate_scout_estimate()` for turn budget
- Modify `lib/orchestrate_recovery.sh` — call `_classify_failure()` on errors
- Modify `lib/config_defaults.sh` — add `LEARNING_ENABLED`,
  `LEARNING_HISTORY_MAX_RUNS`, `LEARNING_CALIBRATION_ENABLED`,
  `LEARNING_FAILURE_PATTERNS`, `LEARNING_FAILURE_PROMOTE_THRESHOLD`
- Create `tests/test_learning.sh` — history recording, calibration, pattern
  matching, knowledge base rotation

Acceptance criteria:
- `_record_run()` appends run summary (cost, duration, outcome, stages) to
  `run_history.jsonl`
- `_record_stage_performance()` records per-stage metrics (turns, time, outcome)
- `_calibrate_scout_estimate()` adjusts raw scout estimate based on historical
  accuracy for the task type (over-estimators deflated, under-estimators inflated)
- `_classify_failure()` matches error output against known failure patterns
  and suggests resolution
- New failure patterns auto-recorded after first occurrence
- Pattern promoted to "known" after `LEARNING_FAILURE_PROMOTE_THRESHOLD`
  occurrences (default: 3) with a successful resolution
- Knowledge base files rotated at `LEARNING_HISTORY_MAX_RUNS` (default: 100)
- `LEARNING_ENABLED=false` disables all learning (V3 behavior)
- Cost data from bridge cost ledger (M06) included in run history
- All existing tests pass
- `shellcheck lib/learning.sh` passes

Watch For:
- Scout calibration must handle cold start (no history yet) — return raw
  estimate unchanged, don't apply a default multiplier.
- Failure pattern matching uses regex. Patterns must be specific enough to avoid
  false positives (don't match "error" generically).
- JSONL files grow over time. Rotation must preserve the most recent N records,
  not the oldest. Use tail-based rotation.

Seeds Forward:
- M25 adds prompt effectiveness tracking and cross-project sharing
- V5's prompt auto-tuning consumes the calibration data
- Watchtower Trends tab can display learning metrics (calibration accuracy)

---

#### Milestone 25: Prompt Tracking & Cross-Project Knowledge

**Parallel group:** learning | **Depends on:** M24

Files to create/modify:
- Modify `lib/learning.sh` — add `_record_prompt_effectiveness()`,
  `_compute_effectiveness()`, global knowledge base read/write
- Create `~/.tekhton/global_knowledge/` directory structure (failure_patterns.jsonl,
  provider_profiles.jsonl, cost_benchmarks.jsonl)
- Modify `lib/agent.sh` — call `_record_prompt_effectiveness()` after each
  stage completion with prompt hash, turns used, rework count, outcome
- Modify `lib/config_defaults.sh` — add `LEARNING_PROMPT_TRACKING`,
  `LEARNING_GLOBAL_ENABLED`, `LEARNING_GLOBAL_DIR`
- Create `tests/test_learning_global.sh` — cross-project sharing, prompt tracking

Acceptance criteria:
- `_record_prompt_effectiveness()` records: stage, prompt_hash, effectiveness_score
  (computed from turns, reworks, outcome)
- Prompt effectiveness data written to `prompt_effectiveness.jsonl`
- When `LEARNING_GLOBAL_ENABLED=true`, failure patterns and cost benchmarks
  written to both project-local and global (`~/.tekhton/global_knowledge/`)
- Global knowledge base is read at startup (if enabled) and merged with
  project-local knowledge (local takes priority on conflicts)
- Provider cost benchmarks aggregated across projects (average cost per
  complexity tier per provider)
- `LEARNING_GLOBAL_ENABLED=false` (default) — no cross-project sharing
- All existing tests pass

Watch For:
- Global knowledge directory may not exist on first run. Create it lazily.
- Cross-project knowledge must not leak project-specific data (file paths,
  task descriptions). Only aggregate metrics (cost averages, pattern templates).
- Prompt hashing must be stable across runs. Use content hash, not memory
  address or timestamp.

Seeds Forward:
- V5 uses effectiveness data to A/B test prompt variants
- V5 adds team knowledge bases (shared across users, not just projects)
- Provider cost benchmarks help users choose the most cost-effective provider

---

#### Milestone 26: Language Profiles & Domain Detection

**Parallel group:** language | **Depends on:** M02

Files to create/modify:
- Create `lib/language.sh` — `_detect_language_domains()`, profile loading,
  domain matching, template variable assembly
- Create `tools/bridge/language_profiles/` directory with JSON profiles:
  `javascript.json`, `typescript.json`, `python.json`, `rust.json`, `go.json`,
  `java.json`, `csharp.json`, `lua.json`, `shell.json`, `c.json`, `cpp.json`
- Modify `lib/detect.sh` — extend tech stack detection to classify detected
  languages into frontend/backend/fullstack domains
- Modify `lib/prompts.sh` — inject `LANGUAGE_REVIEW_FOCUS`, `LANGUAGE_CONVENTIONS`,
  `LANGUAGE_PITFALLS`, `LANGUAGE_TEST_STRATEGY` template variables
- Modify `lib/config_defaults.sh` — add `LANGUAGE_PROFILES_ENABLED`,
  `LANGUAGE_DOMAIN_AUTO_DETECT`, `LANGUAGE_DOMAIN_OVERRIDE`
- Create `tests/test_language.sh` — profile loading, domain detection,
  template variable assembly

Acceptance criteria:
- Language profiles loaded from JSON files (one per language)
- Each profile contains: domain hints (frontend/backend indicators, test
  frameworks, review focus, conventions), pitfalls, ecosystem info
- `_detect_language_domains()` maps detected languages + frameworks to
  domain classifications (e.g., "javascript:frontend", "python:backend")
- Template variables assembled from detected profiles:
  - `LANGUAGE_REVIEW_FOCUS` — review priorities for detected languages/domains
  - `LANGUAGE_CONVENTIONS` — coding conventions to follow
  - `LANGUAGE_PITFALLS` — language-specific issues to watch for
  - `LANGUAGE_TEST_STRATEGY` — test framework and strategy recommendations
- `LANGUAGE_DOMAIN_OVERRIDE=frontend` manually sets domain (bypasses detection)
- Mixed projects (fullstack) get both frontend and backend profiles
- `LANGUAGE_PROFILES_ENABLED=false` disables all language intelligence
- All existing tests pass
- `shellcheck lib/language.sh` passes

Watch For:
- JSON parsing in bash is limited. Use Python helper or simple grep/sed for
  structured extraction. Keep profile format flat enough for bash parsing.
- Domain detection may be ambiguous (React app with Express backend). Default
  to fullstack when both frontend and backend indicators are present.
- Profile directory must support user overrides (custom profiles in
  `.claude/language_profiles/` take precedence over shipped profiles).

Seeds Forward:
- M27 integrates language profiles into all pipeline stages
- V5 adds semantic similarity for profile matching (not just keyword indicators)
- Community contributions: new language profiles are a single JSON file

---

#### Milestone 27: Language-Aware Pipeline Stages

**Parallel group:** language | **Depends on:** M26

Files to create/modify:
- Modify `prompts/coder.prompt.md` — add `{{IF:LANGUAGE_CONVENTIONS}}`
  conditional block
- Modify `prompts/reviewer.prompt.md` — add `{{IF:LANGUAGE_REVIEW_FOCUS}}`
  and `{{IF:LANGUAGE_PITFALLS}}` conditional blocks
- Modify `prompts/tester.prompt.md` — add `{{IF:LANGUAGE_TEST_STRATEGY}}`
  conditional block
- Modify `prompts/specialist_security.prompt.md` — add domain-specific
  security focus (frontend: XSS/CSP/CORS, backend: SQLi/auth/secrets)
- Modify `stages/coder.sh` — inject language conventions into prompt context
- Modify `stages/review.sh` — inject review focus and pitfalls
- Modify `stages/tester.sh` — inject test strategy
- Modify `stages/security.sh` — inject domain-specific security focus
- Create `tests/test_language_integration.sh` — prompt injection verification,
  domain-specific behavior

Acceptance criteria:
- Coder prompt includes language conventions when profile is active
- Reviewer prompt includes language-specific pitfalls and review priorities
- Tester prompt includes domain-appropriate test strategy
  (component+e2e for frontend, unit+integration for backend)
- Security agent prompt includes domain-appropriate focus areas
- Prompt injection only occurs when `LANGUAGE_PROFILES_ENABLED=true`
- Conditional blocks are empty (no injection) when profiles are disabled
- Frontend projects get different review focus than backend projects
- Fullstack projects get both frontend and backend guidance
- All existing tests pass

Watch For:
- Prompt injection must not exceed context budget. Language blocks should be
  concise (200-500 chars each). The context compiler should account for them.
- Existing prompt templates have carefully balanced instructions. Language
  blocks must enhance, not override, existing guidance.
- Test the prompts with multiple models — language-specific instructions may
  need different phrasing for different providers (via bridge profiles from M06).

Seeds Forward:
- V5 uses language profiles for automated code review scoring
- V5 adds language-specific refactoring patterns
- Community can contribute domain-specific review checklists

---

### Manifest Summary

```
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group

# Phase 1: Foundations
m01|Test Harness & Isolation Framework|pending||m01-test-harness.md|foundation
m02|Three-Tier Logging & Structured Events|pending||m02-structured-logging.md|foundation
# --- DOGFOOD CHECKPOINT 1 ---
m03|Bridge Core Architecture & Shell Routing|pending|m02|m03-bridge-core.md|bridge
m04|Anthropic Direct API Adapter|pending|m03|m04-anthropic-adapter.md|bridge
m05|OpenAI & Ollama Adapters|pending|m03|m05-openai-ollama-adapters.md|bridge
m06|Provider Failover Calibration & Cost Ledger|pending|m04,m05|m06-failover-cost.md|bridge
m07|MCP Gateway for Non-Anthropic Providers|pending|m05|m07-mcp-gateway.md|bridge
# --- DOGFOOD CHECKPOINT 2 ---

# Phase 2: Core Capabilities
m08|Parallel Coordinator & Worktree Lifecycle|pending|m02|m08-parallel-coordinator.md|parallel
m09|Parallel Conflict Detection & Merge|pending|m08|m09-parallel-merge.md|parallel
m10|Parallel Resource Budgeting & Shared Gate|pending|m06,m09|m10-parallel-budget.md|parallel
# --- DOGFOOD CHECKPOINT 3 ---
m11|Watchtower Server Mode & WebSocket|pending|m02|m11-watchtower-server.md|watchtower
m12|Watchtower Interactive Controls|pending|m11|m12-watchtower-interactive.md|watchtower
m13|Watchtower Cost Dashboard & Parallel View|pending|m06,m10,m12|m13-watchtower-cost-parallel.md|watchtower
m14|Natural Language Task Decomposition|pending|m03|m14-nl-decomposition.md|owner
m15|Release Notes & Changelog Automation|pending|m02|m15-release-notes.md|owner
m16|Cost Forecasting & Deliverable Packages|pending|m06,m15|m16-cost-forecast.md|owner
# --- DOGFOOD CHECKPOINT 4 ---

# Phase 3: Enterprise & Integration
m17|GitHub Integration|pending|m02,m15|m17-github-integration.md|integration
m18|Slack Teams & Webhook Notifications|pending|m02|m18-slack-webhook.md|integration
m19|Log Shipping & CI/CD Mode|pending|m02|m19-log-shipping-ci.md|integration
m20|NFR Engine & Cost SLA Checks|pending|m02,m06|m20-nfr-engine.md|nfr
m21|NFR Performance A11y Coverage & License|pending|m20|m21-nfr-checks.md|nfr
# --- DOGFOOD CHECKPOINT 5 ---
m22|Auth Abstraction & Local Env Modes|pending|m02|m22-auth-local.md|auth
m23|OIDC Token Validation Stub|pending|m22|m23-auth-oidc.md|auth

# Phase 4: Intelligence
m24|Knowledge Base & Failure Pattern Recognition|pending|m02,m06|m24-knowledge-base.md|learning
m25|Prompt Tracking & Cross-Project Knowledge|pending|m24|m25-prompt-tracking.md|learning
m26|Language Profiles & Domain Detection|pending|m02|m26-language-profiles.md|language
m27|Language-Aware Pipeline Stages|pending|m26|m27-language-stages.md|language
```

### Parallel Execution Opportunities

When V4's own parallel engine is active (after M10), these milestones can
run concurrently within their parallel groups:

| Wave | Milestones (concurrent) | Prerequisite |
|------|------------------------|-------------|
| 1 | M01 + M02 | None |
| 2 | M03 + M08 + M11 + M15 + M18 + M19 + M22 + M26 | M02 |
| 3 | M04 + M05 + M09 + M12 + M14 | M03, M08, M11 |
| 4 | M06 + M07 + M17 + M23 + M27 | M04, M05, M22, M26 |
| 5 | M10 + M13 + M16 + M20 + M24 | M06, M09, M12 |
| 6 | M21 + M25 | M20, M24 |

In practice, API quota and team count limits will constrain concurrency.
But the DAG permits up to 8 milestones in a single wave (Wave 2).
