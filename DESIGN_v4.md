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
with corporate tooling (GitHub Issues, Slack, DataDog, Splunk, Jira, Confluence). No identity
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

1. **Multi-provider is foundational, not optional.** Enterprise deployability
   requires provider choice because some enterprises cannot use specific providers
   for regulatory, contractual, or sovereignty reasons. V4 treats provider choice
   as the default assumption; all project context, agent invocation, and
   documentation conventions are provider-neutral by construction. Anthropic via
   the `claude` CLI remains an optimized fast path for deployments that choose it,
   but the system never forces a provider choice and never assumes one. Users can
   mix providers per stage through the bridge.

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

7. **One-way migration, not backward compatibility.** V4 introduces breaking
   changes in directory layout, context file conventions, NFR vocabulary, provider
   configuration defaults, and scope declaration schema that taken together would
   be compromised by maintaining V3 compatibility. Instead, V4 ships with a
   one-time migration tool that detects V3 projects, surfaces the migration scope,
   and either completes the migration or exits without modification. Post-migration,
   projects are V4-only; V3 Tekhton running against a V4 project produces a clear
   error directing the operator to upgrade their Tekhton CLI. This tradeoff
   privileges architectural clarity over compatibility, which is the right call
   when the architectural step is as substantial as V3 → V4.

8. **Self-applicable.** Tekhton builds Tekhton. Complex features are sequenced
   later so the pipeline is more capable by the time it builds them. Each
   milestone adds value independently.

## Target User

V4 defines five personas as deployment dependencies rather than as customer segments. Each persona produces specific architectural requirements that Tekhton's design accounts for; meeting those requirements is what makes the personas' convergence structural rather than aspirational (see the Architectural Thesis section following).

**Primary: The Product Builder.** A person with a product idea and basic technical literacy (can install tools, edit config files, read a dashboard) but who does not need to be a professional software engineer. They describe what they want, Tekhton decomposes it into milestones, builds it, and reports progress in terms they understand. They approve demos and release notes, not diffs. Their primary inbound surfaces are Natural Language Task Intake and Watchtower Interactive Controls; their primary outbound surfaces are Business-Metric Progress Reporting, Cost Forecasting, and Deliverable Artifact Packages.

**Secondary: The Designer.** A design practitioner who feeds Tekhton design concepts ranging from thin descriptions of UI look-and-feel to complex specifications of user interactions. Designers typically tweak existing tools with their eye for detail and sometimes build POCs and demos from scratch. They author Figma files, screenshots, CSS/HTML mocks, and SVG exports rather than writing code directly. Their primary inbound surface is Design Artifact Intake (Figma adapter, screenshot analysis via vision-capable models, CSS/HTML mock parsing); their primary outbound surfaces are Deliverable Artifact Packages with visual diff summaries and accessibility-category NFR violations they can act on.

**Secondary: The Professional Developer.** Experienced developers who use Tekhton to accelerate their workflow. They benefit from parallel execution, multi-provider support, and cost optimization. They use verbose/debug output and fine-tune per-stage model assignments. They author Goldprints, set NFR thresholds in collaboration with enterprise scopes, use interactive controls, and can submit design artifacts when working full-stack. Their outbound consumption leans toward technical detail rather than non-technical summaries.

**Tertiary: The Enterprise Team (catch-all for vertical slices).** A grouping that spans business analysts, data engineers, software architects, cybersecurity specialists, and compliance officers. Each vertical has distinct concerns but shares the characteristic of requiring Tekhton to comprehend and deliver based on their input. Compliance officers own cost and license thresholds; cybersecurity specialists own vulnerability and security policy thresholds; software architects own performance and SLA budgets; business analysts submit natural language task intake against business requirements; data engineers feed contextual signals from the organization's data systems. Enterprise Team personas' primary inbound surface is the NFR Framework with MoSCoW criticality; their outbound surfaces are filtered views of all three outbound mechanisms, scoped to their vertical's concerns via RBAC.

**Quaternary: The Internal AI Champion (deployment dependency).** A mid-to-senior technical leader (Staff Engineer, Principal Engineer, Engineering Manager, Director of Platform Engineering, or Chief Architect) inside a large organization who has both the technical depth to evaluate Tekhton on architectural merit and the organizational access to advocate for its adoption. They bridge the gap between capability and organizational readiness, navigating procurement, satisfying security review, building internal consensus, and translating Tekhton's value into language that resonates with budget holders. This persona is structurally distinct from the first four in that they typically are also one of the other personas (most often a Professional Developer or Enterprise Team member) with the organizational dimension layered on top. Tekhton doesn't adopt itself; the Champion is the person who bridges capability to organizational readiness, and the architecture accounts for their specific needs through the ROI Analytics view, compliance summary generation, executive-ready report templates, case study artifact generation, and pilot program scaffolding described in M38.

## Architectural Thesis: The Product-Owner Convergence Model

V4's architecture creates structural convergence between product, design, engineering, and enterprise personas, not through aspiration but through specific mechanisms that pull each persona toward a shared operational center. This section names the convergence thesis explicitly and shows how the system design sections that follow implement it. The thesis is descriptive rather than rhetorical: every mechanism named here maps to a concrete component with a file path, a data source, a transformation step, and a storage location. The argument is that naming these components together, as a coordinated system rather than as scattered features, reveals a structural property of Tekhton that isn't visible when the components are described in isolation.

### Bidirectional Translation: Two Categories of Mechanism

Convergence requires translation flowing in both directions. Mechanisms that only translate engineering outputs into non-engineer-legible artifacts describe transparency, which is a weaker claim. True convergence means persona constraints and contributions flow inward to shape execution, and execution state flows outward to inform decisions. V4's architecture provides both.

**Inbound mechanisms** translate persona input into executable infrastructure. They take something a human creates (a natural language description, a compliance policy, a mid-run correction, a codified engineering pattern, a design artifact) and render it as something Tekhton's pipeline can act on directly.

**Outbound mechanisms** translate execution state into persona-legible artifacts. They take what the pipeline produces (stage reports, cost ledger entries, event logs, git diffs) and render it as something a non-engineer can review, approve, or plan against.

V4 includes five inbound mechanisms and three outbound mechanisms, each with concrete architectural grounding:

**Inbound Mechanisms:**

1. **Natural Language Task Intake** (M15). Source: Product Builder input via CLI, Watchtower task form, or V5 inbox integrations. Transformation: PM agent decomposes NL input into milestones grounded in AGENT.md and DESIGN.md project context. Manifestation: structured milestones written to `.tekhton/milestones/` and MANIFEST.cfg in proper DAG format.
2. **NFR Framework** (M24, M25, M26). Source: enterprise persona policy inputs including compliance cost ceilings, cybersecurity vulnerability thresholds, architect performance budgets, design leadership accessibility standards, legal license constraints, and enterprise model governance policies. Transformation: policy thresholds encoded as config keys that map to scheduled checks at defined pipeline points, with MoSCoW criticality determining enforcement severity. Manifestation: runtime gates emitting `nfr.check` and `nfr.violation` events consumable by enterprise observability stacks.
3. **Watchtower Interactive Controls** (M12, M13). Source: Product Builder, Designer, and Enterprise persona input via the dashboard UI for task submissions, human notes, milestone creation and modification, and pipeline control. Transformation: HTTP POST requests to `/api/v1/tasks`, `/api/v1/notes`, `/api/v1/milestones`, and `/api/v1/control` written to the inbox or control channels. Manifestation: live corrections applied to running pipelines with WebSocket-propagated state.
4. **Goldprints** (M18 subsystem, M32 Context Graph bridge). Source: software architects and senior engineers authoring institutional engineering knowledge with LLM assistance. Transformation: markdown + frontmatter files resolved against the Context Graph for domain and adoption filtering, rendered into role-specific prompt sections, and enforced as hard-rule contracts when applicable. Manifestation: agent pipelines produce production code in validated patterns with contractual NFR registrations (see System Design: Goldprints).
5. **Design Artifact Intake** (M16). Source: Designer submissions across Figma files, screenshots (PNG/JPG), CSS/HTML mocks, and SVG exports. Transformation: each format path produces a normalized design spec that the PM agent consumes alongside NL context; screenshots use vision-capable models, Figma uses API extraction, CSS/HTML uses markup parsing. Manifestation: design spec attached to milestone context drives acceptance criteria that include visual match requirements.

**Outbound Mechanisms:**

6. **Business-Metric Progress Reporting** (M14, M19). Source: causal event log, run summary JSON, git diffs, cost ledger, stage reports. Transformation: raw engineering artifacts reframed into milestones completed, cost incurred, duration, what-was-built, and what-to-review. Manifestation: terminal completion banner, Watchtower's dashboard tabs (Live Run, Milestone Map, Reports, Trends), release notes in Keep a Changelog format.
7. **Cost Forecasting from Historical Data** (M20, extended by M34 and M35 for cross-project enrichment). Source: per-project cost ledger, scout complexity estimates, global knowledge at `~/.tekhton/global_knowledge/cost_benchmarks.jsonl`. Transformation: historical per-milestone averages complexity-weighted against scout estimates; first-run forecasts degrade gracefully when history is absent. Manifestation: completion banner cost line, Watchtower API endpoint `GET /api/v1/costs/forecast`, release notes cost section, `cost_report.json` in deliverables.
8. **Deliverable Artifact Packages** (M19, M20). Source: reviewer and tester stage reports, git diffs, milestone specs, cost data, provenance metadata, SBOM. Transformation: engineering artifacts rewritten as reviewable, non-technical documents. Manifestation: file bundle in `.tekhton/deliverables/` containing summary, release notes, changelog entry, cost report, test report, diff summary, SBOM, and provenance.

### Watchtower as the Convergence Meta-Surface

Watchtower isn't a ninth mechanism; it's the operational surface on which the other eight become visible as a unified system rather than as scattered features. Every mechanism eventually surfaces through Watchtower's served-mode interface: the Task Submission Panel (M13) is the surface for Natural Language Task Intake, Watchtower Interactive Controls, and Design Artifact Intake attachments; the Cost Dashboard (M14) surfaces Business-Metric Progress Reporting and Cost Forecasting; the Reports tab surfaces Deliverable Artifact Packages; NFR violations surface in Live Run and the NFR policy view; Goldprint-generated milestones appear in the Milestone Map traceable to their originating Goldprint; the Goldprint UI (M18) surfaces browsing, authoring, promotion workflow, and adoption dashboards; the Organizational Context tab (M33) surfaces overlap detection and historical precedent. Without Watchtower, the mechanisms would be technically present but operationally scattered. Watchtower collapses them into a single interface where all personas meet, which is the operational manifestation of the convergence claim.

### The Context Graph as Convergence Substrate

Where Watchtower is the meta-surface above the outbound mechanisms, the Context Graph (M31-M33, detailed in System Design: Contextual Awareness Layer) is the substrate beneath the inbound mechanisms. Natural Language Task Intake consults the graph for overlap detection before decomposing a new task. NFR Framework threshold authoring surfaces sibling-project policy context. Watchtower Interactive Controls display cross-team awareness alongside the project-local view. Goldprints integrate bidirectionally with the graph through the V4 Goldprint-to-graph bridge (M32) so authoring and consumption events become visible as Artifact nodes and `consumes` edges, and Goldprint resolution queries the graph for domain filtering and adoption metadata. Design Artifact Intake can reference previously-used design assets across the organization. The substrate/surface parallel isn't decorative. It's the architectural reason the convergence claim is structural rather than superficial: persona input enters through inbound mechanisms that sit on top of a shared substrate, execution produces outbound mechanisms that render on a shared surface, and everything in between is Tekhton's actual delivery pipeline.

### RBAC Integration with the Convergence Model

The bidirectional framing makes the RBAC conversation sharper because it clarifies what needs to be authorized where. Inbound mechanisms require persona-specific authorization at their write surfaces; outbound mechanisms require persona-specific filtering at their read surfaces.

**Write surface authorization for inbound mechanisms:**

- Natural Language Task Intake: any authenticated user within a project scope; high-cost tasks may require budget approval scope
- NFR Framework: `compliance` scope for compliance-category thresholds, `cybersec` for security-category, `architect` for performance and SLA, `designer` for accessibility standards; criticality changes (Must vs Should vs Could vs Won't) require elevated scope
- Watchtower Interactive Controls: broad task submission; pipeline control gated by `operator` scope; milestone DAG modification by `project_lead`
- Goldprints: authoring requires `architect` or `senior_engineer` scope; consumption open within project scope
- Design Artifact Intake: `designer` scope or equivalent design team membership

**Read surface filtering for outbound mechanisms:**

- Business-Metric Progress Reporting: cost visibility filtered by scope (finance/exec sees full, engineering sees technical plus aggregate, product and designer see milestone-level without per-turn breakdowns)
- Cost Forecasting: raw historical data restricted to admin scope; aggregates visible broadly; cross-project benchmarks require explicit opt-in per project
- Deliverable Artifact Packages: scoped by project membership first, then by artifact type (compliance sees audit-relevant, security sees vulnerability scans, product sees release notes, designer sees visual diffs)
- Watchtower dashboards: tab-level and field-level filtering; NFR policy view visible only to scopes with modify access; pipeline control surfaces visible to operator scope

**Enterprise identity integration.** V4 federates with existing enterprise identity infrastructure rather than managing users directly. OIDC is the primary authentication protocol with SAML 2.0 as fallback; supported IdPs include Okta, PingID/PingOne, Microsoft Entra ID, Google Workspace, and AWS IAM Identity Center. IdP groups (examples: `tekhton_compliance`, `tekhton_architects`, `tekhton_designers`, `tekhton_operators`, `tekhton_senior_engineers`, `tekhton_project_leads`, `tekhton_cybersec`, `tekhton_context_admins`, `tekhton_context_viewers`, `tekhton_context_contributors`) map to Tekhton scopes declared in `.tekhton/auth.conf`. V4 delivers OIDC stub with scope declaration schema and advisory enforcement (M30); V5 adds SCIM 2.0 provisioning and strict enforcement.

**Audit trail as convergence byproduct.** One consequence of persona-aware authorization across both inbound and outbound surfaces is that the event log becomes a complete audit record of who touched what, when, and why. Every NFR modification carries the identity of the compliance officer or architect who made it. Every Goldprint authoring event carries the senior engineer's identity. Every pipeline control action, every deliverable package access, every design artifact upload: all attributed, all timestamped, all queryable. This isn't a separate audit system; it's a byproduct of the convergence model being implemented with identity-aware authorization. Log shipping (M23) delivers the event log to enterprise SIEM systems for retention and correlation.

### Why This Isn't Marketing Copy

The convergence argument is defensible because each mechanism is already infrastructure, not aspiration. It's the difference between saying "Tekhton helps product owners" (value prop) and saying "Tekhton's intake stage accepts natural language input at `stages/intake.sh` and produces MANIFEST.cfg entries that the execution pipeline consumes without modification, while the NFR engine at `lib/nfr.sh` reads compliance thresholds from `.tekhton/nfr.conf` and enforces them as pipeline gates" (architectural claim). The second statement is auditable against the codebase. The first is rhetoric.

The bidirectional framing also makes the claim more defensible because it acknowledges what convergence actually requires. Outbound-only mechanisms describe transparency, which any good observability stack provides. Inbound-only mechanisms describe configurability, which any enterprise tool provides. Convergence requires both, and naming them as a paired system is what distinguishes Tekhton's architecture from a well-instrumented pipeline that happens to have a good dashboard. The RBAC integration further separates Tekhton from the pattern where convergence is talked about but never enforced, because the same identity and scope infrastructure that gates inbound writes filters outbound reads, producing an audit trail as a structural byproduct rather than as a bolted-on compliance feature.

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
- Stores profile in `.tekhton/bridge/profiles/openai.json`
- Takes ~5 minutes, runs once per provider configuration

At failover time, the bridge loads the profile and applies adjustments
automatically. No intelligence required at failover time.

**Cost ledger:**

Every agent invocation records to `.tekhton/bridge/cost_ledger.jsonl`:
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
BRIDGE_ENABLED=true                     # Multi-provider is foundational (tenet 1)
BRIDGE_DEFAULT_PROVIDER=anthropic       # Default when model name is ambiguous
BRIDGE_FAILOVER_ENABLED=false           # Enable automatic provider failover
BRIDGE_FAILOVER_PROVIDER=""             # Secondary provider for failover
BRIDGE_COST_TRACKING=true               # Enable cost ledger
BRIDGE_MCP_GATEWAY=true                 # Enable MCP for non-Anthropic providers
BRIDGE_PROFILE_DIR=".tekhton/bridge/profiles"
BRIDGE_COST_LEDGER=".tekhton/bridge/cost_ledger.jsonl"

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
│ debug (flag)     │          │ .tekhton/logs/run.log  │       │ .tekhton/logs/    │
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

- Debug log: `.tekhton/logs/run_<RUN_ID>.log` (rotated, last 50 retained)
- Event log: `.tekhton/logs/run_<RUN_ID>.events.jsonl` (same retention)
- Symlinks: `.tekhton/logs/latest.log` → most recent run
- The causal event log (`CAUSAL_LOG.jsonl`) from V3 is superseded by the structured events.jsonl format as the canonical machine-readable output. The V3 → V4 migration tool transforms existing CAUSAL_LOG data into the events.jsonl format as part of the one-time migration.

### Config Keys

```bash
TEKHTON_LOG_LEVEL=default              # default | verbose | debug
TEKHTON_LOG_DIR=".tekhton/logs"         # Directory for log files
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
- Flaky tests are recorded in `.tekhton/test_flakiness.json`
- Pipeline can be configured to quarantine known-flaky tests

**Test quarantine:**

```bash
# pipeline.conf
TEST_QUARANTINE_ENABLED=true           # Enable self-test quarantine
TEST_QUARANTINE_FILE=".tekhton/test_quarantine.json"
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
TEST_QUARANTINE_FILE=".tekhton/test_quarantine.json"
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
    │   ├── git worktree: .tekhton/worktrees/team-1/
    │   ├── Coder → Reviewer → Tester (full pipeline)
    │   └── Merge back to main branch on success
    │
    ├── Team 2: Milestone C
    │   ├── git worktree: .tekhton/worktrees/team-2/
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
    local worktree_dir=".tekhton/worktrees/team-${team_id}"
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
`.tekhton/worktrees/team-N/TEAM_STATUS.json`

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

**Serial as degenerate case:**

When `PARALLEL_MAX_TEAMS=1`, the parallel engine degenerates to serial execution (one team running at a time). This is the degenerate case of the parallel architecture rather than a V3 compatibility mode; serial remains legitimate for local development, constrained environments, or projects where milestone dependencies preclude parallelism. V4 defaults `PARALLEL_MAX_TEAMS` to a value greater than 1 appropriate for the deployment's resource budget.

### Config Keys

```bash
PARALLEL_ENABLED=true                   # Parallel by default (tenet 4); serial is a degenerate case
PARALLEL_MAX_TEAMS=3                    # Max concurrent teams
PARALLEL_QUOTA_STRATEGY=equal           # equal | weighted | priority
PARALLEL_WORKTREE_DIR=".tekhton/worktrees"
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
- **PARALLEL_MAX_TEAMS defaults to the deployment's resource budget** rather than hardcoded to 1. Operator explicitly sets it to 1 only when serial execution is specifically desired (resource-constrained environments, debugging, or milestone dependencies that preclude parallelism).
- **V3's DAG infrastructure** (frontier detection, parallel groups, dependency edges) is transformed during the one-time migration into V4's parallel coordinator schema. No V3 compatibility layer is maintained.

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
Mode 1: Static (fallback mode for air-gapped or read-only deployments)
    watchtower.html reads .tekhton/watchtower/*.json files
    Auto-refresh via polling
    Read-only

Mode 2: Served (V4 default)
    tekhton --watchtower-serve  (or WATCHTOWER_SERVE_ENABLED=true by default)
    Python HTTP server on localhost:PORT
    WebSocket push for real-time updates
    Interactive controls (task submission, milestone management, Goldprint authoring, NFR configuration)
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
        ├── Monitors .tekhton/watchtower/*.json for changes
        ├── Monitors .tekhton/logs/events.jsonl for new events
        └── Pushes updates via WebSocket on change
```

**Interactive controls (V4 additions to UI):**

1. **Task Submission Panel**
   - Text field for natural language task description
   - Milestone selector (run against specific milestone or auto-detect)
   - Model/provider selector (dropdown populated from bridge config)
   - "Dry Run" toggle
   - Submit button → writes to `.tekhton/inbox/task_<timestamp>.json`

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

Watchtower writes task/note/control files to `.tekhton/inbox/`. The pipeline
checks the inbox at startup and between stages:

```bash
_process_inbox() {
    local inbox_dir="${PROJECT_DIR}/.tekhton/inbox"
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
        --data-dir "${PROJECT_DIR}/.tekhton/watchtower" \
        --log-dir "${PROJECT_DIR}/.tekhton/logs" \
        --inbox-dir "${PROJECT_DIR}/.tekhton/inbox" &
    local pid=$!
    echo "$pid" > "${PROJECT_DIR}/.tekhton/watchtower.pid"
    log_default "Watchtower serving at http://localhost:${port}"
}
```

### Config Keys

```bash
WATCHTOWER_SERVE_ENABLED=true          # Watchtower is the primary interface (full UI/UX suite in V4)
WATCHTOWER_PORT=8420                    # Server port
WATCHTOWER_API_ENABLED=true            # Enable REST API
WATCHTOWER_WS_ENABLED=true             # Enable WebSocket push
WATCHTOWER_INBOX_ENABLED=true          # Enable file-based inbox
WATCHTOWER_INBOX_DIR=".tekhton/inbox"   # Inbox directory
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

The PM agent uses the project's existing AGENT.md and DESIGN.md context (with optional provider-specific overlays such as CLAUDE.md layering on top of AGENT.md) to ground the decomposition in the project's architecture and conventions.

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
    local notes_file="${PROJECT_DIR}/.tekhton/releases/release_${milestone_id}.md"

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

Every completed run produces a summary package in `.tekhton/deliverables/`:
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
DELIVERABLES_DIR=".tekhton/deliverables"
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
# DataDog/Splunk agents monitor .tekhton/logs/events.jsonl directly
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

NFRs are declared in `pipeline.conf` or a dedicated `.tekhton/nfr.conf`:

```bash
# .tekhton/nfr.conf

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

            case "$(_nfr_criticality "$check")" in
                must)   log_default "   NFR VIOLATION (Must, blocking): $check — $result"
                        return 1 ;;
                should) log_default "   NFR WARNING (Should): $check — $result" ;;
                could)  log_verbose "   NFR note (Could): $check — $result" ;;
                wont)   : ;;  # Explicit waiver; no enforcement. Rationale recorded elsewhere.
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

**MoSCoW Criticality Levels:**

Each NFR check has a configurable MoSCoW criticality level that determines enforcement severity. The criticality framework is shared across the NFR Framework, Goldprint NFR registrations, and any deployability-related thresholds; see the Goldprints section for the full treatment of how criticality propagates through Goldprint contracts.

- `must` — Mandatory and blocking. Pipeline stops on violation; remediation required before the milestone can proceed. Hard guardrails in the strictest sense.
- `should` — Strongly expected but not blocking. Violations surface as prominent warnings in Watchtower at elevated severity; pipeline continues.
- `could` — Desirable nice-to-haves. Violations are logged with standard severity and appear as low-priority notes.
- `wont` — Explicit non-enforcement. The threshold is consciously waived for this scope with an audit-trail rationale; distinguished from "not configured" to preserve the record of the deliberate choice.

```bash
# Default criticality (overridable per-check)
NFR_CRITICALITY_COST=must               # Cost overruns block
NFR_CRITICALITY_SLA=should              # SLA violations warn prominently
NFR_CRITICALITY_PERF=should             # Performance budget violations warn prominently
NFR_CRITICALITY_A11Y=should             # Accessibility violations warn prominently
NFR_CRITICALITY_COVERAGE=should         # Coverage shortfalls warn prominently
NFR_CRITICALITY_LICENSE=must            # License violations block
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
- **MoSCoW criticality** (must/should/could/wont) gives engineering teams a semantic vocabulary they already know from requirements management. Must blocks, Should warns prominently, Could logs, Won't waives explicitly with an audit-trail rationale. This prevents NFRs from being either ignored (too permissive) or pipeline-blocking (too strict), and the Won't level distinguishes deliberate exclusion from accidental omission.
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
# .tekhton/auth.conf

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
.tekhton/knowledge/
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
    done < "${TEKHTON_HOME}/.tekhton/knowledge/failure_patterns.jsonl"

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
        >> ".tekhton/knowledge/prompt_effectiveness.jsonl"
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

## System Design: Storage Abstraction Layer

### Problem

V3 locks Tekhton's working files and source materials to filesystem-only storage. Enterprise deployments operate in environments where centralized, query-able, access-controlled storage is the norm: PostgreSQL clusters for structured data, S3-compatible object stores for content, git repositories with CODEOWNERS enforcement for versioned artifacts. V4 introduces subsystems that need to participate in these existing infrastructure patterns rather than force enterprises to fit Tekhton into a filesystem-only model. Goldprints particularly need flexible storage: project-tier Goldprints benefit from git-backed PR review flow, org-tier Goldprints benefit from centralized database storage, and enterprise-tier Goldprints may need object-store scale with metadata indexing.

### Design

The storage abstraction layer defines a backend-agnostic interface that V4 subsystems use to persist and retrieve content. The abstraction itself is designed to be Tekhton-wide, but V4 scopes its consumption to Goldprints as the first consumer; V5 migrates design artifacts, releases, deliverables, and Watchtower data files to the same abstraction.

**Interface (`lib/storage/`):**

```bash
# lib/storage/storage.sh

_storage_list() {
    # list(path, filter) — enumerate items at a logical path, optionally filtered by metadata
}

_storage_get() {
    # get(path) — retrieve content and metadata for a single item
}

_storage_put() {
    # put(path, content, metadata) — store or update an item
}

_storage_delete() {
    # delete(path, version) — remove an item or specific version
}

_storage_watch() {
    # watch(path) — subscribe to changes (cache invalidation, Watchtower live updates)
}

_storage_query() {
    # query(criteria) — structured query (database backends); filesystem/object-store fall back to list-and-filter
}
```

Each backend adapter implements this interface against its native storage mechanism:

**`git://`**: git repository backend for project-tier Goldprints (stored in the project repo under `.tekhton/goldprints/`) and for deployments that prefer git-backed enterprise or org Goldprint storage with protected branches and CODEOWNERS enforcement. Preserves PR-based review flow, full version history, and existing git-based access control.

**`postgres://`**: PostgreSQL backend, using the same database instance as the Context Graph's Apache AGE when co-located. Content and metadata in relational tables; native structured queries via `query(criteria)`; version history via temporal columns. Recommended for enterprise deployments that want centralized storage and already operate PostgreSQL.

**`s3://`**: S3 and S3-compatible object storage (MinIO, Cloudflare R2, Backblaze B2). Content stored as objects; metadata stored as object tags plus a sidecar index in PostgreSQL or a separate metadata file. Recommended for deployments that want object-store semantics or are already invested in S3-compatible storage.

**Per-tier storage configuration example:**

```bash
# Project tier: each project's own repo
GOLDPRINTS_PROJECT_BACKEND=git://.tekhton/goldprints/

# Org tier: centralized database
GOLDPRINTS_ORG_BACKEND=postgres://tekhton-enterprise-db/goldprints

# Enterprise tier: S3 for scale with postgres-backed metadata
GOLDPRINTS_ENTERPRISE_BACKEND=s3://tekhton-enterprise-goldprints/
GOLDPRINTS_ENTERPRISE_METADATA_BACKEND=postgres://tekhton-enterprise-db/goldprint_metadata
```

Different tiers can use different backends without changing the authoring or consumption experience. A project-tier Goldprint authored in Watchtower and stored in `git://project-repo/.tekhton/goldprints/` gets committed back to the project repo via PR. An enterprise Goldprint authored in Watchtower and stored in `postgres://enterprise-db/goldprints` goes through the database's transaction model. Different backends, unified UX.

**Metadata envelope:**

Every stored item carries a common metadata schema regardless of backend:

- `id`, `version`, `content_type` (goldprint, design_artifact, release, etc.)
- `created_at`, `updated_at`, `created_by`, `updated_by` (identity from RBAC)
- `scope` (enterprise, org, project expression)
- `tags` (domain tags, custom labels)
- `parent_id`, `supersedes`, `depends_on` (relationships)
- `backend_native` (backend-specific metadata preserved for round-trips without loss)

Adapters translate bidirectionally between the envelope and the backend's native metadata mechanism (git commit metadata plus sidecar YAML for git; JSONB column for postgres; object tags plus sidecar for S3).

### Config Keys

```bash
STORAGE_BACKEND=git                        # Default backend if per-content-type not set
STORAGE_URL=                                # Backend connection URL
STORAGE_GOLDPRINTS_PROJECT_BACKEND=git://.tekhton/goldprints/
STORAGE_GOLDPRINTS_ORG_BACKEND=
STORAGE_GOLDPRINTS_ENTERPRISE_BACKEND=
STORAGE_METADATA_BACKEND=                   # Sidecar metadata store for S3 adapter
STORAGE_CACHE_TTL=300                       # In-memory cache TTL (seconds)
```

### Why This Design

- **Pluggable backends** let each enterprise deployment use infrastructure it already operates; no mandate to introduce new storage systems to adopt Tekhton
- **Per-content-type backend selection** matches the reality that different content has different storage needs: git for versioned project code, postgres for queryable enterprise data, S3 for large binary artifacts
- **Metadata envelope abstraction** means adapters translate but the consumer experience stays uniform; Goldprint authoring in Watchtower works the same regardless of whether storage is git or postgres
- **V4-scoped consumer (Goldprints only)** is deliberate discipline: ship the abstraction proven against one consumer, then migrate other subsystems in V5 as usage patterns justify it

---

## System Design: Contextual Awareness Layer

### Problem

The enterprise integration phase (M21-M23) connects Tekhton to external systems (Jira, Confluence, GitHub), but connectivity alone doesn't produce contextual intelligence. Being connected to Jira isn't the same as understanding why a ticket was filed, what architectural decision preceded it, or what production anomaly triggered the work. More critically, at enterprise scale the real problem is not single-project context but organizational context: teams in large organizations compete for stakeholder visibility, work in parallel without knowing what other teams are doing, and regularly ship redundant or conflicting solutions to the same problem. Hundreds to thousands of engineers operate in tree-structured organizations all working to deliver value, and nobody has the full picture. The waste compounds in ways that are invisible until production collisions become obvious. V4 needs Tekhton to know what is being built across the organization, by whom, when, and with what intent, so that when a team submits a new task, Tekhton can recognize overlap before code gets written.

### Design

The architectural response is a temporal knowledge graph: the Context Graph Service (CGS). Nodes represent projects, milestones, teams, domains, and artifacts. Edges represent ownership, dependency, conflict, supersession, and contribution. Every node and edge carries a lifecycle (created, active, deprecated, completed, abandoned) so the graph answers both "what is happening now" and "what has happened before and why did it end."

**Node types (V4 baseline):**

- **Project**: a distinct deliverable effort with an owning team, business objective, and lifecycle status
- **Milestone**: a defined unit of work within a project with acceptance criteria, dependencies, and status
- **Team**: the group accountable for one or more projects, with scope membership linked to the RBAC model
- **Domain**: a capability area (authentication, billing, search, notifications) that projects address
- **Artifact**: a concrete output (repo, service, Goldprint, NFR policy set, design artifact) produced by a project

**Edge types (V4 baseline):** `owned_by`, `belongs_to`, `addresses`, `depends_on`, `supersedes`/`superseded_by`, `conflicts_with`, `produces`, `consumes`.

**Temporal metadata on every node and edge:** `created_at`, `updated_at`, `status_changed_at`, `status`, `last_signal_at` (freshness indicator).

**Two Modes: Vertical Feature and Horizontal Concern**

Contextual awareness is built as both a vertical feature (a named architectural subsystem with its own milestones) and a horizontal concern (integration touchpoints threaded through every other subsystem). This dual framing is the key architectural commitment: the other V4 subsystems are designed with context consultation points from the start rather than retrofitted.

**Vertical**: The Context Graph Service (M31-M33) is a dedicated subsystem with its own storage layer (Apache AGE on PostgreSQL as primary backend, Kuzu embedded for single-node deployments), its own ingestion pipelines, its own query API, its own Watchtower surface (Organizational Context tab), and its own milestones in V4.

**Horizontal**: Every Tekhton stage that could benefit from organizational context consults the CGS at defined touchpoints. V4 wires four horizontal touchpoints (intake, architect, scout, finalize); V5 extends to coder, reviewer, tester, and NFR Framework.

**Storage Backend Decision**

Apache AGE is the primary V4 backend because PostgreSQL is already operationally mature in virtually every enterprise deployment. Apache AGE adds Cypher query support as a PostgreSQL extension, inheriting PostgreSQL's access controls, replication, and HA story. Kuzu (MIT, embedded) is the secondary backend for development environments and single-node deployments where PostgreSQL operational overhead isn't warranted. Alternatives considered and rejected: Neo4j Community Edition (GPL v3), JanusGraph (overkill at V4 scale with Cassandra/HBase operational dependencies), Dgraph (adds another language runtime), SurrealDB and Memgraph (BSL licensing concerns), TerminusDB (unfamiliar operational patterns), XTDB (MPL 2.0 weak copyleft).

**Ingestion sources (V4 adapters):**

- **Jira** (or equivalent): ticket hierarchy, epic/story/task structure, assignees, timelines, domain tags, status transitions. Primary feed for project and milestone nodes.
- **Confluence** (or equivalent): architectural decision records, RFCs, design documents. Primary feed for domain metadata, rationale, constraints.
- **GitHub/GitLab**: repositories, PRs, ownership (CODEOWNERS), commit history. Feeds artifact nodes and team membership edges.
- **Tekhton-internal** (from `~/.tekhton/global_knowledge/`): failure patterns, cost benchmarks, provider profiles, Goldprint adoption. Feeds internally-generated nodes.

**Query patterns:**

- **Overlap detection**: active or recently completed projects in the same domain; triggers warning if similarity score exceeds threshold
- **Historical precedent**: prior decisions in the same domain with outcomes and rationale
- **Dependency mapping**: downstream consumers of a proposed change across the organization
- **Freshness and confidence**: every response includes metadata about source recency so agents don't treat stale data as authoritative

**The Goldprint-to-Graph Bridge**

The CGS and Goldprints integrate bidirectionally from V4 (not V5) so the substrate claim in the Architectural Thesis holds uniformly across inbound mechanisms. When a Goldprint is authored, the CGS receives an event that creates an Artifact node with the Goldprint's identifier, domain tags, authoring team, and lifecycle timestamp. When a project's milestone execution invokes a Goldprint, the CGS receives an event that creates a `consumes` edge from the Project node to the Goldprint's Artifact node. Over time, this produces an adoption signal visible to any graph query, and Goldprint resolution (M18) queries the CGS for domain filtering and adoption metadata rather than relying on local storage alone.

**Privacy, access, and organizational boundaries:**

Enterprise teams have legitimate reasons for limiting cross-team visibility: legal holds, M&A confidentiality, regulatory segregation, customer data isolation. The access model integrates with the RBAC system and extends it with context-specific scopes:

- **Default**: project-scoped visibility only
- **Anonymized visibility**: cross-team queries return "a project exists in this domain, owned by Team X, in status Y" without specific milestone details
- **Full visibility**: explicit opt-in at the project level makes full details queryable by authorized scopes
- **Compartmented projects**: projects with legal or regulatory constraints excluded from the graph entirely, or included only at the anonymized tier
- **Audit trail**: every cross-team context query logged with querying identity, target project, and data returned tier

Scope additions: `context_viewer` (query anonymized cross-team context), `context_contributor` (project published into the organizational graph), `context_admin` (query full context across participating projects).

**Build posture: in-tree with extraction discipline.**

The CGS is plausibly its own product long-term, but V4 builds it in-tree with clean boundaries rather than extracting prematurely. The `lib/context/` and `tools/context_graph/` directories treat themselves like a separate project: no direct imports of Tekhton-specific libraries beyond logging and config, REST API boundary with Tekhton callers, own database instance, containerizable as standalone process. Built this way, V5 extraction becomes a weekend of repo surgery rather than a multi-month disruption, and the optionality stays open without distorting V4 delivery.

### Config Keys

```bash
CONTEXT_GRAPH_ENABLED=true
CONTEXT_GRAPH_BACKEND=apache_age            # apache_age | kuzu
CONTEXT_GRAPH_URL=
CONTEXT_GRAPH_API_KEY=
CONTEXT_OVERLAP_THRESHOLD=0.75
CONTEXT_DEFAULT_VISIBILITY=project          # project | anonymized | full
CONTEXT_INGESTION_SCHEDULE_JIRA="0 * * * *"
CONTEXT_INGESTION_SCHEDULE_GITHUB="0 * * * *"
CONTEXT_INGESTION_SCHEDULE_CONFLUENCE="0 */6 * * *"
CONTEXT_INGESTION_SCHEDULE_INTERNAL="event"
CONTEXT_INTAKE_OVERLAP_ENABLED=true
CONTEXT_ARCHITECT_PRECEDENT_ENABLED=true
CONTEXT_SCOUT_ORG_BASELINE_ENABLED=true
CONTEXT_FINALIZE_RELATED_EFFORTS_ENABLED=true
```

### Why This Design

- **Temporal knowledge graph** matches the data shape of enterprise engineering work: things evolve, supersede each other, and have lifecycles that matter for decision-making
- **Horizontal concern** framing means V4 milestones are designed with context consultation points from the start rather than retrofitted later; retrofitting is substantially more expensive
- **Apache AGE on PostgreSQL** leverages operational maturity enterprises already have, avoiding the introduction of a new graph database dependency in most deployments
- **Three-tier visibility** is the only access model that survives enterprise IT security review; naive "every team sees everything" gets rejected immediately in regulated industries
- **Goldprint-to-graph bridge as V4 scope** rather than V5 ensures the substrate claim in the Architectural Thesis holds uniformly from V4 onward

---

## System Design: Goldprints

### Problem

Institutional engineering knowledge is the hardest thing for any organization to retain and scale. Senior engineers carry patterns in their heads: "when building a new microservice endpoint that touches PII, use this authentication pattern, this data-access layer structure, this logging configuration, and this test scaffold." These patterns encode hard-won judgment about what works in production, what regulatory concerns apply, and what common mistakes to avoid. When the senior engineer leaves, the pattern goes with them. When new teams start adjacent work, they reinvent the pattern, often incompletely. At enterprise scale this translates to inconsistent implementations across teams, repeated mistakes, and the slow erosion of institutional engineering capital. Ramp's Dojo product demonstrates the potential of encoded organizational knowledge (350+ shared skills), but Dojo's skills teach an AI how to help a human complete a task faster. Tekhton needs something categorically more powerful: institutional engineering knowledge encoded as executable configuration that produces production code in a specific, validated pattern.

### Design

**Goldprints** are reusable engineering configuration primitives. The name marries "golden paths" (the platform engineering term for the opinionated, well-paved route a team wants its engineers to take) with "blueprints" (the formalized, reproducible structure that directs construction). Goldprints are both: opinionated about the right way to solve a recurring engineering problem, and structured enough that Tekhton's agents execute them with full contextual adaptation.

**Authoring and governance**

Software architects, senior engineers, and the broader technical staff author Goldprints with modern LLM assistance (the assistance is provided through the Watchtower authoring UI with a context-aware chat panel). Engineers own the final content, review for architectural soundness, validate against production experience, and attach the judgment calls that turn a draft into a Goldprint. This is a deliberate choice: automating the encoder removes the judgment that makes Goldprints valuable in the first place.

Promotion from experimental to production tier requires technical consensus between qualified technical staff and Tekhton itself, with neither party able to unilaterally override the other. The consensus mechanism combines three signals: human technical approval (N reviewers with `architect` or `senior_engineer` scope, where N is tier-specific), Tekhton contextual signal (adoption data from the Context Graph, outcome correlation, conflict detection, NFR compliance), and NFR compliance check. A human approver cannot override a Tekhton "conflict detected" signal without explicit conflict-resolution action; Tekhton cannot promote without human approval regardless of how clean the contextual signals are.

**Scope hierarchy**

V4 ships three scope tiers as a flexible scope expression that preserves V5 optionality for team-scope or custom-scope extensions:

- **Enterprise**: global, maintained by engineering leadership in partnership with security, compliance, risk, and infrastructure leadership. Default `rule_type: hard_rule`.
- **Org**: scoped to a division, line of business, or major organizational unit. Default `rule_type: advisory`.
- **Project**: scoped to a single project. Default `rule_type: advisory`.

Resolution order is most-specific-first (project → org → enterprise) with conflict resolution rules: enterprise hard-rule Goldprints always apply, enterprise advisory Goldprints can be superseded by more-specific tiers with `supersedes` metadata, org Goldprints can be superseded by project Goldprints.

**Goldprint file format**

Goldprints are authored as markdown files with YAML frontmatter:

```markdown
---
id: GP-001
version: 2.3.0
tier: production
scope: enterprise
rule_type: hard_rule
domain: [microservices, pii, authentication]
author: enterprise-arch-team
reviewers: [arch-lead, security-lead]
created_at: 2026-01-15
promoted_at: 2026-03-22
nfr_registrations:
  - category: security
    key: NFR_SEC_PII_ENCRYPTION
    value: true
    criticality: must
    rationale: "Enterprise PII encryption standard."
  - category: coverage
    key: NFR_COVERAGE_MIN_LINE_PCT
    value: 90
    criticality: must
    rationale: "Sensitive data handling requires elevated coverage."
depends_on: [GP-005]
supersedes: [GP-045]
agent_config_hints:
  coder:
    min_model_tier: high
    temperature: 0.2
---

# Microservice Endpoint with PII

## Pattern Summary
One or two sentences. Shown in the manifest summary card.

## Implementation Details
[For the coder agent]

## Test Scaffold
[For the tester agent]

## Validation Criteria
[For the reviewer agent and the enforcer]

## Security Notes
[For the security agent]

## Adaptation Notes
[For all agents]
```

**Four-layer agent integration**

The efficient answer to how Goldprints plug into Tekhton's agent architecture is that they plug in at multiple layers, not one. A single-point integration fails on one or both of the two criteria that matter: semantic completeness (does the agent know what pattern to apply?) and enforcement guarantee (does the pattern actually get applied?). The layered design:

**Layer 1 — Context Compiler Injection (primary channel):** When a stage calls `run_agent()`, the context compiler first calls the Goldprint resolver to identify applicable Goldprints for the task domain, scope, and role. The resolver returns a ranked list with metadata. The context compiler allocates a configurable portion of the context budget (default 20%) to Goldprint content and renders the Goldprints into a structured section the agent sees alongside the milestone window, repo map, and task context. This is how the agent learns what patterns to apply.

**Layer 2 — Agent Configuration Override:** Some Goldprints carry execution hints that belong in agent invocation parameters rather than the prompt: specific model choices, turn budgets, tool access permissions, temperature settings. Before `run_agent()` invokes the provider, `lib/goldprints/config_override.sh` extracts these hints from applicable Goldprints and merges them with the stage's default configuration.

**Layer 3 — Stage-Level Enforcement:** Context injection gets the agent to apply the pattern most of the time, but agents are probabilistic and hard-rule Goldprints require correctness guarantees. The reviewer stage consults `lib/goldprints/enforcer.sh` after the coder agent returns output. The enforcer validates the output against applicable hard-rule Goldprints using both static checks (pattern matching) and agent-assisted checks. Violations block the milestone and route back to coder with specific violation details.

**Layer 4 — Progressive Disclosure (token efficiency):** The full content of every applicable Goldprint cannot always fit in the context budget. The main context includes a Goldprint manifest with summary cards (title, tier, rule type, one-sentence pattern summary, adoption count), and the agent can request full content of any specific Goldprint via an MCP tool call (`get_goldprint(id)`). Hard-rule Goldprints are always fully rendered regardless of budget; advisory Goldprints appear as summary cards unless the agent explicitly fetches them.

**Role-based rendering**

Each agent role gets only the sections relevant to its function:

- **Coder**: Pattern Summary + Implementation Details + Adaptation Notes
- **Reviewer**: Pattern Summary + Validation Criteria + Adaptation Notes
- **Tester**: Pattern Summary + Test Scaffold + Adaptation Notes
- **Architect**: Pattern Summary + Implementation Details (high-level) + dependency graph
- **Security**: Pattern Summary + Security Notes + `nfr_registrations` + Validation Criteria (security-tagged subset)
- **Jr Coder**: same as Coder with additional "common mistakes" guidance

**NFR coupling as building code**

NFRs registered by a Goldprint are the building code of the pattern. They're test criteria the produced work must meet or surpass per the MoSCoW criticality assigned to each requirement. Different NFRs have different enforcement severity (Must blocks, Should warns, Could logs, Won't is explicit waiver), but all are formally part of the pattern's contract.

Merge rules follow building-code logic (stricter wins, tightening-only). A lower-scope layer cannot downgrade criticality or loosen thresholds from higher-scope values; it can only tighten or register Won't for NFR categories higher scopes didn't address. Won't at a lower scope cannot waive a Must, Should, or Could from a higher scope.

An advisory Goldprint's NFR registrations still function as part of the pattern's contract at their registered criticality levels. The advisory nature governs whether to use the Goldprint at all; once the pattern is applied, its building code applies with it, including Must registrations that block violations just as they would from a hard_rule Goldprint.

**Watchtower UI**

With Watchtower growing into a full UI/UX suite across V4, Goldprint browsing and authoring live inside Watchtower (M18) rather than requiring a dedicated tool. V4 views: Browser (filtering by tier, domain, lifecycle status, scope, rule type), Detail (full content with metadata sidebar and adoption graph), Author/Edit (markdown editor with live preview, frontmatter form, and LLM assistance chat panel), Promotion Workflow (approval status, Tekhton signal, NFR compliance), Adoption Dashboard (portfolio-level health view for engineering leadership).

### Config Keys

```bash
GOLDPRINTS_ENABLED=true
GOLDPRINTS_ENTERPRISE_REPO=
GOLDPRINTS_ORG_REPOS=
GOLDPRINTS_LOCAL_DIR=.tekhton/goldprints/
GOLDPRINTS_CONTEXT_BUDGET_PCT=20
GOLDPRINTS_PROGRESSIVE_DISCLOSURE=true
GOLDPRINTS_ENFORCE_HARD_RULES=true
GOLDPRINTS_EXPERIMENTAL_OPT_IN=false
```

### Why This Design

- **Engineers as authors with LLM assistance** preserves the institutional judgment that makes Goldprints valuable; automating the encoder would erode the judgment
- **Four-layer agent integration** addresses both semantic completeness (context injection) and enforcement guarantee (stage-level validation), because either alone is insufficient
- **Role-based rendering** is cognitive efficiency for the agent: a tester agent doesn't need implementation details when its job is to verify behavior
- **MoSCoW criticality on NFR registrations** matches how engineering teams actually think about requirements (Must vs Should vs Could vs Won't) rather than the flat block/warn/log vocabulary
- **Storage abstraction allows per-tier backend choice** matching the actual operational patterns enterprises use: git for project-tier, postgres for org-tier, S3 for enterprise-tier scale

---

## Enterprise Deployability

### Problem

V4 is the first version of Tekhton that even attempts to be enterprise-deployable. V3 solves a fundamentally different problem from the one V4 is solving. Framing the deployability gap as "V4 filling holes in V3" misreads the situation; V4 is the inflection point where Tekhton transitions from "agentic pipeline for a developer's laptop" to "agentic delivery engine for enterprise environments," and the deployability domains are the work that transition requires. Once Tekhton operates at the V4 scope (parallelization, multi-provider, Context Graph connectivity, Goldprints, organizational awareness), enterprise deployability stops being optional.

### Design

Ten deployability domains categorized by whether they were in the original five or emerge from regulated-industry requirements. For each domain, V4 delivers a specific commitment while V5 adds the certification and enforcement layer. The V4/V5 split is calibrated to match design philosophy tenet 5: V4 delivers "auditable in practice," V5 delivers "formal certification."

**Original five domains:**

**SSO/OIDC Integration.** V3: no federation, no identity attribution, no scope model. V4 (M29, M30): OIDC stub validating tokens against configured IdP (Okta, PingID, Entra ID, Google Workspace, AWS IAM Identity Center), persona-to-scope mapping schema, SAML 2.0 fallback, identity attribution in causal event log. V5: full OAuth redirect flow, SCIM 2.0 provisioning, formal certification pathways.

**Secret Management.** V3: environment variables only. V4 (M27): secret manager abstraction in `lib/secrets/` with HashiCorp Vault and AWS Secrets Manager adapters; declarative secret resolution at invocation time with short-lived caching; env variable fallback remains for development. V5: Azure Key Vault, Google Secret Manager, CyberArk adapters; automated secret rotation integration; full secret lifecycle in audit trail.

**Network Egress Controls.** V3: no controls. V4 (M28): configurable network policy with declarative allowlist/denylist for provider endpoints, integration endpoints, and Context Graph ingestion endpoints; TLS 1.2+ enforcement; every network call logged. V5: full network policy engine with traffic shaping, quota management, service mesh integration, per-scope egress policy.

**Audit Logging.** V3: causal event log (JSONL) and run summary JSON but no identity attribution. V4 (M23, M29-M30): identity attribution on every event via OIDC stub; enterprise SIEM log shipping (M23) for DataDog, Splunk, syslog forwarding; three log classes with consistent schema (pipeline, identity, policy events). V5: cryptographic tamper-evidence (hash chains, signed segments), formal retention policy, compliance-specific log formats, forensic-grade integrity verification.

**RBAC.** V3: no access control. V4 (M30): persona-to-scope mapping schema, scope declaration on every inbound mechanism and outbound surface, scope evaluation advisory mode (events log decisions but don't enforce). V5: hard enforcement across sensitive surfaces, SCIM-driven automated scope assignment, attribute-based access control, scope-aware encryption.

**Five additional domains from regulated-industry convergence:**

**Model Governance.** V3: nothing. V4 (M26): model allowlist/denylist at enterprise, org, and project scope via new `NFR_MODEL_*` NFR category; model version attribution on every invocation; output governance hooks in reviewer stage. V5: full policy engine with training data transparency, cryptographic attestation of model integrity, regulatory-specific qualification workflows (FDA SaMD, etc.).

**Supply Chain Security.** V3: no SBOM, no scanner integration, no provenance. V4 (M20 extension): SBOM generation in SPDX and CycloneDX formats attached to deliverable packages (JS/TS and Python baseline); integration points for dependency vulnerability scanners (Snyk, GitHub Dependabot, Sonatype Nexus IQ, JFrog Xray). V5: SLSA compliance at level 3+ with in-toto provenance chains; additional language ecosystems; automatic remediation workflows.

**Code Provenance and Agentic Authorship.** V3: commits as configured git user with no agent attribution. V4 (M19 extension): structured provenance metadata on every commit and event including agent role, Goldprint id, user identity, milestone and run identifiers, model and provider version; Watchtower Milestone Map surfaces provenance chain. V5: cryptographic attestation with signed commit trailers and verifiable provenance chains; formal agent accountability frameworks for regulated work.

**Data Residency and Sovereignty.** V3: goes wherever Anthropic's API routes. V4 (M04, M32): region selection in `tekhton-bridge` provider configuration; integration adapter region awareness; Context Graph storage region configuration; declarative residency policy at enterprise scope. V5: automatic region-aware routing based on data classification; formal geofencing at infrastructure layer; multi-region failover with residency constraints.

**Encryption at Rest and in Transit.** V3: TLS inherited from claude CLI only; no at-rest encryption. V4 (M17, M28): TLS 1.2+ required across all network communication; storage abstraction backends delegate at-rest encryption to native mechanisms (PostgreSQL TDE, S3 SSE-KMS, git-crypt); `NFR_SECURITY_ENCRYPTION_AT_REST` surfaces encryption posture. V5: Tekhton-managed encryption with enterprise KMS integration (AWS KMS, Azure Key Vault, Google KMS, Vault transit); end-to-end encryption for agent payloads.

**Domains deliberately excluded (environment responsibility, not Tekhton's):**

- Data classification and handling (PII, PHI, PCI tagging) — project-level responsibility; Tekhton respects classification metadata but does not classify
- Retention and deletion policies — organizational lifecycle concerns; Tekhton's artifacts participate via storage abstraction but policies are organizational
- Change management, incident response, business continuity, third-party risk management — organizational process concerns; Tekhton contributes data but does not own the process
- Ethical AI and bias monitoring — substantial concern warranting its own architectural treatment in V5 or beyond

**V4 Critical Path (must ship for deployability to be credible):**

SSO/OIDC stub with identity attribution (M29-M30), secret management via Vault and AWS Secrets Manager (M27), network egress policy with logging (M28), audit logging with identity attribution and SIEM shipping (M23), RBAC scope declaration schema (M30), code provenance metadata on commits and events (M19 extension), TLS 1.2+ enforcement, `tekhton-bridge` region selection (M04).

**V4 Stretch Goals (deliver if parallel execution velocity permits):**

SBOM generation across more language ecosystems beyond JS/TS and Python (M20 extension), model allowlist/denylist policy layer with administrative UI (M26), dependency vulnerability scanner adapters beyond reference integration, storage abstraction at-rest encryption posture documentation.

**V5 Despite Appearing in V4 Discussion:**

Hard enforcement of RBAC scope checks, SCIM 2.0 provisioning, cryptographic tamper-evidence on audit logs, full network policy engine, SLSA attestation, cryptographic agentic authorship attestation, automatic region-aware routing, Tekhton-managed encryption with KMS, SCIM-driven scope lifecycle.

### Strategic Sequencing Framing

The language for describing V5 deferrals already exists in design philosophy tenet 5: "Enterprise is a spectrum. V4 delivers 'auditable in practice'. V5 delivers formal certification." V4 "auditable in practice" means enterprises running V4 can answer the audit questions that matter for day-to-day operational governance: who did what (identity attribution on every event), what accessed what (scope declarations and evaluations logged), what went where (network policy decisions, region metadata, provider invocations recorded), what produced the work (code provenance metadata), what the results are (comprehensive causal event log shipped to enterprise SIEM). V5 "formal certification" moves from this baseline to certifiable implementation: enforcing rather than declaring, making guarantees cryptographic, automating lifecycle, delivering regulation-specific features.

This progression is the actual design intent, not a limitation. V4 is the deployable baseline; V5 is the certifiable implementation. Both are legitimate stopping points for different enterprises at different points in their Tekhton adoption journey. Phrasing patterns for describing V5 deferrals consistently: "V4 delivers the auditable baseline for X; formal certification lands in V5" rather than "V4 is missing X"; "V4 declares and attributes; V5 enforces" rather than "V4 doesn't enforce"; "V4 ships the audit trail; V5 ships the cryptographic tamper-evidence that makes the trail forensically defensible" rather than "V4 has no tamper-evidence."

---

## Scope Boundaries

### In Scope (4.0)

**Foundational architecture:**
- V3 → V4 one-time migration tool with detect, surface, prompt, execute, validate, version-marker flow
- Provider abstraction layer (tekhton-bridge) with Anthropic, OpenAI, Ollama adapters
- MCP gateway for non-Anthropic providers
- Provider failover with pre-computed profiles
- Cost ledger and per-stage cost tracking
- Per-stage model/provider assignment
- Region selection in tekhton-bridge for data residency compliance

**Observability and testing:**
- Three-tier structured logging (default/verbose/debug)
- Structured JSONL event stream for enterprise log ingestion
- Stage banners with clean default output
- Test isolation framework (temp dirs, port allocation, process tracking)
- Test quarantine and flakiness detection

**Execution engine:**
- Parallel milestone execution via git worktrees
- Resource budgeting and conflict detection for parallel teams
- Shared build gate after parallel merge

**Watchtower as full UI/UX suite:**
- Watchtower served mode with WebSocket push and REST API
- Interactive controls (task submission, milestone manager, run control)
- Cost dashboard in Watchtower
- Organizational Context tab with overlap detection and historical precedent views
- Goldprint UI (browser, detail, author/edit with LLM assistance, promotion workflow, adoption dashboard)
- ROI and Adoption Analytics view for Champion tooling
- Compliance summary generation from audit trail
- Executive-ready report templates
- Pilot program scaffolding project templates

**Project owner experience:**
- Natural language task intake and milestone decomposition
- Design artifact intake (Figma, screenshots PNG/JPG, CSS/HTML mocks, SVG)
- Release notes and changelog generation
- Cost forecasting
- Deliverable artifact packages
- Code provenance metadata in commits and events (agent role, Goldprint id, user, milestone, model version)
- SBOM generation in SPDX and CycloneDX formats for JS/TS and Python baseline

**Enterprise integrations:**
- GitHub integration (issues, PRs, releases)
- Slack/Teams notifications
- Log shipping (DataDog, Splunk via file-based + direct API)
- Webhook support (generic)
- CI/CD integration mode (GitHub Actions)

**Enterprise deployability:**
- NFR framework (performance, cost, SLA, coverage, license, accessibility, model governance)
- NFR violation criticality (MoSCoW: must/should/could/wont)
- Pipeline anomaly detection
- Secret manager abstraction with HashiCorp Vault and AWS Secrets Manager adapters
- Network egress policy (declarative allowlist/denylist with event log attribution)
- TLS 1.2+ enforcement across all network calls
- Auth abstraction layer with local/env/OIDC-stub modes
- OIDC token validation with persona-to-scope mapping schema
- RBAC scope declaration schema (declaration and attribution in V4; hard enforcement in V5)
- Audit trail with identity enrichment

**Substrate and goldprints:**
- Context Graph subsystem on Apache AGE (PostgreSQL) primary, Kuzu embedded alternative
- Context Graph schema (five node types, eight edge types, temporal metadata)
- Context Graph ingestion adapters (Jira, GitHub, Confluence, Tekhton-internal) with Goldprint-to-graph bridge
- Horizontal Context Graph consultation touchpoints (intake, architect, scout, finalize stages)
- Three-tier visibility model (project-scoped default, anonymized cross-team, full visibility deferred to V5 full-mode governance)
- Goldprints subsystem with four-layer agent integration (context compiler injection, agent configuration override, stage-level enforcement, progressive disclosure via MCP tool)
- Goldprint file format (markdown with YAML frontmatter)
- Goldprint role-based rendering across all six agent roles
- Goldprint promotion workflow (technical consensus + Tekhton contextual signal + NFR compliance check)
- Goldprint scope hierarchy (enterprise, org, project with flexible scope expression for V5 extensibility)
- Storage abstraction layer with git, PostgreSQL, and S3/S3-compatible backends

**Learning and intelligence:**
- Learning subsystem (history, scout calibration, failure patterns)
- Cross-project local knowledge sharing
- Language profiles with domain-specific intelligence
- Frontend/backend awareness in all pipeline stages
- Language-specific pitfall injection in reviews

**Project conventions:**
- AGENT.md as primary provider-neutral project context file; optional provider-specific overlays (CLAUDE.md for Anthropic-specific quirks, etc.)
- `.tekhton/` directory for all project-scoped Tekhton data
- Persona set: Product Builder, Designer, Professional Developer, Enterprise Team (catch-all for compliance, cybersec, architect, data engineer, business analyst), Internal AI Champion (deployment dependency)

### Out of Scope (V5)

**Auth and RBAC enforcement:**
- Hard enforcement of RBAC scope checks at sensitive surfaces (V4 declares and attributes; V5 enforces)
- SCIM 2.0 provisioning for automated user lifecycle
- Full OAuth redirect/consent/exchange flow for SSO providers (V4 stubs token validation only)
- Attribute-based access control beyond scope membership
- Scope-aware encryption of sensitive data at rest

**Cryptographic guarantees:**
- Cryptographic tamper-evidence on audit logs (hash chains, signed segments)
- SLSA attestation at level 3+ with in-toto provenance chains
- Cryptographic agentic authorship attestation (signed commit trailers, verifiable provenance)
- Tekhton-managed encryption with enterprise KMS integration (AWS KMS, Azure Key Vault, Google KMS, Vault transit)
- End-to-end encryption for agent invocation payloads

**Network and residency:**
- Full network policy engine with traffic shaping, quota management, integration with service mesh or egress proxies
- Per-scope egress policy (project-level provider restrictions)
- Automatic region-aware routing based on data classification
- Formal geofencing controls at infrastructure layer
- Multi-region failover policies with residency constraints

**Context Graph expansion:**
- DataDog, Splunk, and additional observability platform adapters
- Slack, Microsoft Teams, and communication platform adapters
- Additional issue tracker, SCM, and doc platform adapters (Linear, Azure DevOps, GitLab, Bitbucket, Notion, SharePoint, Google Docs)
- Remaining horizontal context touchpoints (coder, reviewer, tester, NFR Framework integration)
- Full visibility mode with granular opt-in governance
- Advanced graph queries: semantic similarity for overlap detection (pgvector), predictive conflict detection, automated domain tagging
- Cross-organization federation
- Standalone extraction of Context Graph Service as separate open-source project

**Goldprints expansion:**
- Semantic similarity for Goldprint recommendation (pgvector embeddings)
- Predictive adoption modeling
- Failure/success rate analytics correlating Goldprint consumption with milestone outcomes
- Cross-organization Goldprint discovery
- Advanced Watchtower Goldprint UI: conflict resolution UI, semantic similarity recommendations, pattern suggestion from graph analysis
- Additional agent role renderings beyond the V4 six roles
- Per-team scope tier (scope expression reserves the slot; implementation deferred)
- Public Goldprint marketplace (deliberately out of scope due to trust and governance implications)

**Storage abstraction expansion:**
- Azure Blob Storage, Google Cloud Storage, and filesystem-plus-sync backends
- Migration of design artifacts, releases, deliverables, and Watchtower data files to the storage abstraction
- Federated storage with policy-based routing
- Storage-level encryption integration with enterprise KMS

**Deployability and compliance:**
- Additional secret manager adapters (Azure Key Vault, Google Secret Manager, CyberArk)
- Automated secret rotation integration
- Additional dependency vulnerability scanner adapters beyond the V4 reference integration
- Full SBOM coverage across all major language ecosystems (V4 ships JS/TS and Python baseline)
- Full model governance policy engine with training data transparency and regulatory-specific qualification
- Ethical AI and bias monitoring subsystem
- Compliance-specific log formats (PCI DSS event types, HIPAA audit log requirements)
- Formal compliance certification pathways (SOC 2 Type II, HIPAA, PCI DSS, FDA SaMD)

**Other V5 commitments:**
- Prompt auto-tuning from effectiveness data (V4 collects, V5 acts)
- Stage-level parallelism within a milestone (except Scout + Security pre-scan)
- Cloud-hosted Watchtower for team visibility
- Team knowledge bases (shared learning across users/machines)
- Containerized pipeline execution with permission levels
- Deployment, monitoring, and maintenance automation (the "Maximum" scope)
- Multi-tenancy with RBAC
- Mobile Watchtower interface

### Stretch (V4 if time permits)

- Stage-level parallelism for Scout + Security pre-scan
- Automatic `parallel_group` inference from file overlap analysis
- Provider cost comparison mode (same task, multiple providers, compare quality)
- Visual regression testing integration in frontend domain
- Additional Goldprint SBOM language ecosystems beyond JS/TS and Python baseline
- Administrative Watchtower UI for model governance policy configuration
- Declarative enforcement that storage backend at-rest encryption is verified before startup

---

## New Files Summary

**tools/migration/ (Python — V3 → V4 migration tool):**
- `__init__.py` — Package init
- `migrate.py` — CLI entry point (`tekhton migrate`)
- `detect.py` — V3 project detection
- `transform/__init__.py` — transformation registry
- `transform/directory.py` — `.claude/` → `.tekhton/` directory rename
- `transform/context_files.py` — `CLAUDE.md` → `AGENT.md` split with Anthropic overlay
- `transform/nfr_config.py` — NFR_POLICY_* (block/warn/log) → NFR_CRITICALITY_* (must/should/could/wont)
- `transform/pipeline_conf.py` — provider defaults, bridge enablement, storage abstraction config
- `validate.py` — post-migration self-check
- `report.py` — migration scope surfacing and consent prompt
- `tests/test_migration.py` — Python migration tool tests

**tools/bridge/ (Python — provider abstraction):**
- `__init__.py` — Package init
- `bridge.py` — CLI entry point (`tekhton-bridge call/calibrate/update-pricing`)
- `types.py` — AgentRequest, AgentResponse, ModelInfo, ProviderStatus
- `cost.py` — Cost calculation, ledger management, pricing tables
- `mcp_gateway.py` — MCP client for non-Anthropic providers
- `calibration.py` — Provider profile calibration
- `auth_oidc.py` — OIDC discovery, JWT validation, SAML 2.0 fallback
- `providers/anthropic.py` — Direct Anthropic SDK adapter
- `providers/openai.py` — OpenAI SDK adapter
- `providers/ollama.py` — Ollama REST API adapter
- `providers/openai_compat.py` — Generic OpenAI-compatible adapter
- `requirements.txt` — Bridge Python dependencies

**tools/context_graph/ (Python — Context Graph service):**
- `__init__.py` — Package init
- `api.py` — REST API server (`/api/v1/context/*`)
- `schema.py` — node types, edge types, temporal metadata
- `storage/__init__.py` — storage backend abstraction
- `storage/apache_age.py` — Apache AGE on PostgreSQL backend (primary)
- `storage/kuzu.py` — Kuzu embedded backend (secondary)
- `queries.py` — canonical query implementations (overlap, precedent, dependency, freshness)

**tools/sbom/ (Python — SBOM generation):**
- `__init__.py` — Package init
- `generate.py` — SPDX and CycloneDX format generation
- `scanners/js.py` — JavaScript/TypeScript SBOM scanner
- `scanners/python.py` — Python SBOM scanner

**tools/storage/ (Python helpers for storage backends):**
- `postgres.py` — PostgreSQL storage backend helpers (psycopg2 wrapper)
- `s3.py` — S3 and S3-compatible storage backend helpers (boto3 wrapper)

**tools/secrets/ (Python helpers for secret manager backends):**
- `vault.py` — HashiCorp Vault API client
- `aws_secrets.py` — AWS Secrets Manager API client

**tools/goldprint_cache.py** — Pre-rendered Goldprint caching by (goldprint_id, version, role) hash

**tools/mcp/goldprint_fetch.py** — MCP tool implementation for `get_goldprint(id)` on-demand fetches

**tools/watchtower_server.py** — Watchtower HTTP/WebSocket server

**tools/bridge/language_profiles/*.json** — Language profile data files

**lib/ (shell):**
- `logging.sh` — Three-tier logging, structured event emitter
- `parallel.sh` — Parallel execution coordinator
- `parallel_teams.sh` — Team lifecycle (worktree, merge, conflict)
- `parallel_budget.sh` — Resource budgeting across teams
- `nfr.sh` — NFR check engine
- `nfr_checks.sh` — Individual NFR check implementations
- `nfr_model.sh` — Model governance NFR category
- `auth.sh` — Identity abstraction layer
- `rbac.sh` — Scope declaration, scope check hooks, persona-to-scope mapping
- `learning.sh` — Historical knowledge base, calibration, failure patterns
- `language.sh` — Language profile loading, domain detection, prompt enrichment
- `provenance.sh` — Code provenance metadata generation (commit trailers, event enrichment)
- `sbom.sh` — SBOM generation orchestration, per-language toolchain dispatch
- `cost_forecast.sh` — Historical cost analysis and forecasting
- `design_intake.sh` — Design artifact resolution and normalization
- `network_policy.sh` — Network egress allowlist/denylist enforcement
- `integrations/github.sh` — GitHub integration adapter
- `integrations/slack.sh` — Slack/Teams notification adapter
- `integrations/logging_ship.sh` — Log shipping adapter
- `integrations/webhook.sh` — Generic webhook adapter
- `integrations/ci.sh` — CI/CD mode adapter
- `integrations/figma_adapter.sh` — Figma REST API client for design intake
- `integrations/design_file_adapter.sh` — CSS/HTML/SVG mock parsing, screenshot handling
- `test_harness.sh` — Test isolation framework

**lib/context/ (Context Graph client library):**
- `client.sh` — Context Graph REST API client
- `consult.sh` — `_consult_context(role, domain, query_type, params)` helper
- `ingestion.sh` — Ingestion scheduler
- `adapters/jira.sh` — Jira ingestion adapter
- `adapters/github.sh` — GitHub ingestion adapter
- `adapters/confluence.sh` — Confluence ingestion adapter
- `adapters/tekhton_internal.sh` — Tekhton-internal adapter (from global knowledge base)
- `adapters/goldprints.sh` — Goldprint-to-graph bridge adapter

**lib/goldprints/ (Goldprint subsystem):**
- `resolver.sh` — Domain/scope-filtered Goldprint resolution
- `renderer.sh` — Role-based markdown-to-prompt rendering
- `config_override.sh` — Agent configuration hint extraction and merging
- `enforcer.sh` — Hard-rule validation after agent output
- `loader.sh` — Parse markdown + frontmatter Goldprint files

**lib/storage/ (Storage abstraction):**
- `storage.sh` — Backend-agnostic interface
- `metadata.sh` — Common metadata envelope
- `adapters/git.sh` — Git repository backend
- `adapters/postgres.sh` — PostgreSQL backend
- `adapters/s3.sh` — S3 and S3-compatible backend

**lib/secrets/ (Secret manager abstraction):**
- `secrets.sh` — Backend-agnostic secret resolution interface
- `adapters/vault.sh` — HashiCorp Vault adapter
- `adapters/aws_secrets.sh` — AWS Secrets Manager adapter
- `adapters/env.sh` — Environment variable fallback adapter

**lib/champion/ (Internal AI Champion tooling):**
- `roi.sh` — ROI and adoption analytics derivation
- `compliance.sh` — Compliance summary generation from audit trail
- `executive_report.sh` — Condensed executive-ready report generation
- `case_study.sh` — Structured pilot outcome records
- `pilot_scaffolding.sh` — Project template initialization

**templates/:**
- `pilot_scaffolds/` — Pilot project template directory (microservice-pii, design-to-production, compliance-work, research-spike scenarios)

**prompts/:**
- `goldprints_section.partial.md` — Goldprint section prompt template fragment
- `design_intake.prompt.md` — Design artifact intake prompts for vision models

**tests/:**
- `test_migration.sh` — V3 → V4 migration scenarios, V3 protection
- `test_bridge.sh` — Bridge invocation tests
- `test_logging.sh` — Three-tier logging tests
- `test_parallel.sh` — Parallel execution tests
- `test_design_intake.sh` — Design artifact intake tests
- `test_storage.sh` — Storage abstraction interface tests
- `test_goldprints.sh` — Goldprint subsystem tests
- `test_provenance.sh` — Code provenance metadata tests
- `test_sbom.sh` — SBOM generation tests
- `test_nfr.sh` — NFR framework tests
- `test_nfr_checks.sh` — Individual NFR check tests
- `test_nfr_model.sh` — NFR model governance tests
- `test_secrets.sh` — Secret manager adapter tests
- `test_network_policy.sh` — Network egress policy tests
- `test_auth.sh` — Auth abstraction tests
- `test_auth_oidc.sh` — OIDC mode integration tests
- `test_rbac.sh` — RBAC scope declaration and check hooks
- `test_context_graph_client.sh` — Context Graph shell client tests
- `test_context_adapters.sh` — Context Graph ingestion adapter tests
- `test_context_consult.sh` — Stage integration with Context Graph
- `test_learning.sh` — Learning subsystem tests
- `test_language.sh` — Language profile tests
- `test_integrations.sh` — Integration adapter tests
- `test_harness.sh` — Test harness self-tests
- `test_champion_roi.sh`, `test_champion_compliance.sh`, `test_champion_reports.sh`, `test_champion_pilot.sh` — Champion tooling tests

**Python tests:**
- `tools/tests/test_migration.py` — Python migration tool tests
- `tools/tests/test_bridge.py` — Bridge unit tests
- `tools/tests/test_providers.py` — Provider adapter tests
- `tools/tests/test_mcp_gateway.py` — MCP gateway tests
- `tools/tests/test_cost.py` — Cost calculation tests
- `tools/tests/test_calibration.py` — Provider calibration tests
- `tools/tests/test_auth_oidc.py` — JWT validation, claims parsing, SAML fallback
- `tools/tests/test_figma_adapter.py` — Figma API contract tests
- `tools/tests/test_context_graph_schema.py` — Graph schema tests
- `tools/tests/test_context_graph_storage.py` — Apache AGE and Kuzu backend tests
- `tools/tests/test_storage_postgres.py` — PostgreSQL storage backend tests
- `tools/tests/test_storage_s3.py` — S3 storage backend tests
- `tools/tests/test_secrets_vault.py` — Vault adapter tests
- `tools/tests/test_secrets_aws.py` — AWS Secrets Manager adapter tests
- `tools/tests/test_goldprint_cache.py` — Cache hit/miss and version invalidation
- `tools/tests/test_goldprint_bridge.py` — End-to-end Goldprint authoring and consumption

**Project-level:**
- `.tekhton/` — Primary Tekhton data directory (replaces V3's `.claude/`)
- `.tekhton/version` — V4 version marker file that V3 Tekhton recognizes
- `.tekhton/goldprints/` — Project-tier Goldprints (when git storage backend used for project tier)
- `.tekhton/nfr.conf` — Per-project NFR configuration with MoSCoW criticality
- `.tekhton/auth.conf` — Per-project auth and scope mapping configuration
- `.tekhton/nfr_model.conf` — Model governance policy per scope
- `.tekhton/network_policy.conf` — Network egress allowlist/denylist
- `.tekhton/design_artifacts/` — Design artifact originals and normalized specs

## Modified Files Summary

- `lib/agent.sh` — Provider routing in `run_agent()`, cost recording, Goldprint config override, provenance emission, model governance check, network egress check
- `lib/common.sh` — Replace single-tier logging with three-tier system
- `lib/config.sh` — Load new config sections (bridge, nfr, auth, learning, secrets, storage, goldprints, context_graph, network_policy, champion, etc.)
- `lib/config_defaults.sh` — All new config keys + defaults + clamps
- `lib/context_compiler.sh` — Extended to call into `lib/goldprints/` for Goldprint section rendering within the context budget
- `lib/finalize.sh` — Release notes + changelog + provenance + SBOM generation hooks
- `lib/finalize_summary.sh` — Enhanced RUN_SUMMARY.json with cost + identity + provenance
- `lib/finalize_display.sh` — Project-owner-friendly completion banner with provenance summary
- `lib/orchestrate.sh` — Parallel execution integration, inbox processing
- `lib/orchestrate_helpers.sh` — Parallel team coordination
- `lib/orchestrate_recovery.sh` — Failure classification hooks for learning subsystem
- `lib/gates.sh` — NFR check integration in build gate (with MoSCoW criticality)
- `lib/milestones.sh` — Parallel team status tracking
- `lib/milestone_ops.sh` — Parallel-aware milestone completion
- `lib/intake_helpers.sh` — Natural language + design artifact decomposition
- `lib/prompts.sh` — Language profile template variable injection, Goldprint section framing
- `lib/release.sh` — Release notes + cost forecasting + SBOM integration
- `lib/detect.sh` — Language domain detection (frontend/backend)
- `lib/dashboard.sh` — Watchtower served mode lifecycle
- `lib/causality.sh` — Identity enrichment, provenance metadata, scope check event enrichment in events
- `lib/goldprints/resolver.sh` — Extended to query Context Graph for domain filtering and adoption metadata (not just storage)
- `lib/goldprints/loader.sh` — Emit `goldprint.authored` events consumed by Context Graph bridge
- `stages/intake.sh` — Design artifact detection, `_consult_context()` for overlap detection, NL + design blend
- `stages/architect.sh` — `_consult_context()` for historical precedent
- `stages/coder.sh` — Language convention injection, Goldprint context consumption, provenance commit trailers
- `stages/review.sh` — Language pitfall injection, Goldprint hard-rule enforcement
- `stages/tester.sh` — Domain-aware test strategy, Goldprint test scaffold consumption
- `stages/security.sh` — Domain-aware security focus, model governance output hooks
- `templates/watchtower/` — Interactive UI, cost dashboard, parallel view, Organizational Context tab, Goldprint UI (Browser, Detail, Author/Edit, Promotion Workflow, Adoption Dashboard), Champion tooling (ROI, Compliance Summary, Executive Reports)
- `templates/pipeline.conf.example` — New config sections for all V4 subsystems
- `prompts/*.prompt.md` — Language profile conditional blocks
- `prompts/intake.prompt.md` — NL decomposition with design artifact context
- `tekhton.sh` — Source new modules, detect V3 projects and invoke migration tool, bridge init, parallel mode, served watchtower
- `tests/run_tests.sh` — Test harness integration, quarantine support

## V3 to V4 Migration

V4 introduces breaking changes substantial enough that maintaining backward compatibility would compromise the design. The breaking changes include: directory rename (`.claude/` → `.tekhton/`), project context file split (`CLAUDE.md` → `AGENT.md` as the primary provider-neutral context file, with optional `CLAUDE.md` remaining as an Anthropic-specific overlay for provider-specific quirks), NFR vocabulary migration (`NFR_POLICY_*` with `block/warn/log` → `NFR_CRITICALITY_*` with MoSCoW `must/should/could/wont` values), multi-provider configuration defaults where provider choice is the foundational assumption rather than an opt-in, new RBAC scope declaration schema, storage abstraction layer defaults, and Context Graph project-local cache setup.

### Migration Tool

V4 ships a one-time-use migration tool (milestone in early Phase 1) that:

1. **Detects V3 projects** by scanning for `.claude/` directory, `CLAUDE.md` without corresponding `AGENT.md`, V3 `NFR_POLICY_*` config keys, or absence of a `.tekhton/version` marker
2. **Surfaces the full migration scope** to the operator running the upgrade (a developer setting up Tekhton on their machine, or an enterprise upgrade lead managing organizational rollout), showing exactly what will change
3. **Prompts for explicit consent**: migrate the project to V4 (irreversible) or exit without modification. No partial migrations, no silent transformations.
4. **Executes the migration** atomically: directory rename, context file split with provider-neutral content moving to AGENT.md and genuinely Claude-specific content remaining in CLAUDE.md as an overlay, NFR config transformation (`block → must`, `warn → should`, `log → could`, with no V3 equivalent for `wont`), provider config defaults reset to multi-provider-foundational, scope declaration schema written, storage abstraction config applied, Context Graph project-local cache initialized
5. **Validates the migration** by running a post-migration self-check before writing the `.tekhton/version` marker
6. **Writes the version marker** (`.tekhton/version`) that V3 Tekhton recognizes and refuses to run against, preventing accidental V3 reversion

Post-migration, projects are V4-only. V3 Tekhton running against a V4 project produces a clear error directing the operator to upgrade their Tekhton CLI. There is no downgrade path; the migration is one-way by design.

### Feature Configuration Defaults

V4 defaults reflect the multi-provider-foundational architecture and enterprise deployability baseline. Where features default to disabled, the rationale is the feature's nature (privacy-sensitive, per-project opt-in, or local-development-appropriate), not V3 compatibility:

| Feature | V4 Default | Rationale |
|---------|-----------|-----------|
| Provider bridge | `BRIDGE_ENABLED=true` | Multi-provider is foundational (tenet 1) |
| Three-tier logging | `TEKHTON_LOG_LEVEL=default` | Default user experience; verbose/debug opt-in |
| Test harness | Active | Infrastructure is mandatory (tenet 6) |
| Parallel execution | `PARALLEL_ENABLED=true` | Parallel by default (tenet 4); degenerate case is serial |
| Watchtower served | `WATCHTOWER_SERVE_ENABLED=true` | Primary interface (Watchtower is a full UI/UX suite in V4) |
| Release notes | `RELEASE_NOTES_ENABLED=true` | Project owner deliverable (tenet 2) |
| NFR framework | Per-check opt-in via `NFR_*_ENABLED` | Projects enable the NFR categories relevant to their domain |
| Auth | `AUTH_ENABLED` per deployment | Enterprise deployments enable; local dev may not |
| Learning (local) | `LEARNING_ENABLED=true` | Cross-run intelligence improves over time |
| Learning (global) | `LEARNING_GLOBAL_ENABLED=false` | Privacy-sensitive; opt-in per project |
| Language profiles | `LANGUAGE_PROFILES_ENABLED=true` | Language-aware stages are enterprise-grade default |
| Integrations | Per-integration opt-in via `INTEGRATION_*_ENABLED` | Each integration requires separate credentials and access approval |
| Goldprints | `GOLDPRINTS_ENABLED=true` | Institutional engineering knowledge substrate |
| Context Graph | `CONTEXT_GRAPH_ENABLED=true` | Substrate beneath the convergence inbound mechanisms |
| Storage abstraction | Backend configured per deployment | Deployment-specific (git / postgres / s3) |

Features that default to disabled in V4 do so for architectural, privacy, or operational reasons, not to preserve V3 behavior.

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

38 milestones across 4 phases. Each milestone is scoped for a single
`tekhton --milestone` run. Dogfood checkpoints mark validation points for
the one-way V4 migration; V4 migration is irreversible per tenet 7, so each
checkpoint is a go/no-go validation boundary rather than a rollback option.

```
Phase 1: Foundations (M01-M08)     — Test, logging, migration tool, provider abstraction
Phase 2: Core (M09-M20)            — Parallel execution, Watchtower, owner UX, design intake, storage abstraction, Goldprints
Phase 3: Enterprise (M21-M33)      — Integrations, deployability, NFRs, auth, Context Graph
Phase 4: Intelligence (M34-M38)    — Learning, language awareness, Champion tooling
```

### Dependency Graph (Simplified)

```
M01 ─────────────────────────────────────────────────────────────────────
M02 ──┬──── M03 (migration tool) ──┬── (shift numbers +1 for bridge work) ──
      │                            │
      ├──── M04 ──┬── M05 ──┬── M07 ──┬── M11 ── M14
      │           └── M06 ──┘    │     └── M18 (Goldprints)
      │                └── M08   │     └── M24 ── M25
      ├──── M09 ── M10 ─────────┘          └── M34 ── M35
      ├──── M12 ── M13 ─────────────── M14
      ├──── M15
      ├──── M16 (design intake) ──┬── M18 (Goldprints; requires storage abstraction M17)
      │                           └── M17 (storage abstraction)
      ├──── M19 (release notes + provenance)
      ├──── M20 (cost forecasting + SBOM)
      ├──── M21-M23 (integrations) ──┬── M32 (Context Graph ingestion)
      ├──── M24-M26 (NFR) ───────────┤
      ├──── M27 (secret manager) ────┤
      ├──── M28 (network egress) ────┤
      ├──── M29-M30 (auth + RBAC schema) ── M31 (Context Graph core) ── M32 (ingestion + bridge) ── M33 (horizontal + tab)
      └──── M37 (language stages) ── M38 (Champion tooling)
```

---

### Phase 1: Foundations (M01-M08)

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
- Quarantine file (`.tekhton/test_quarantine.json`) excludes quarantined tests
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
- Flakiness data feeds into the Learning subsystem (M34)
- Quarantine status is displayed in Watchtower Reports tab (M14)

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
- Debug log always written to `.tekhton/logs/run_<RUN_ID>.log` regardless of level
- Structured events always written to `.tekhton/logs/run_<RUN_ID>.events.jsonl`
- Symlink `.tekhton/logs/latest.log` points to most recent run
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
- Watchtower server (M12) reads the events.jsonl stream
- Log shipping (M23) forwards the events.jsonl to DataDog/Splunk
- NFR checks (M24) emit `nfr.check` / `nfr.violation` events

---

### DOGFOOD CHECKPOINT 1: Foundation Complete (After M02)

**Action:** Replace the working Tekhton copy with the latest V4 build.

**What's new:**
- Test harness ensures self-tests are more robust (no more zombie processes)
- Three-tier logging means building M04+ (bridge and subsequent phases) produces cleaner default output
- Debug log always captured to disk for post-mortem analysis

**What to verify after upgrade:**
- `bash tests/run_tests.sh` passes with new harness
- Default CLI output shows stage banners (not debug tags)
- `.tekhton/logs/` directory populates with run logs

**Dogfood validation:** Run the Tekhton self-tests against this build to confirm the new test harness and logging infrastructure are operating correctly before proceeding to M03. If validation fails, abort the checkpoint and investigate before proceeding; V4 migration is one-way per tenet 7, so pre-checkpoint validation is the safety boundary rather than post-hoc rollback.

**Risk:** Low — infrastructure additions to test harness and logging. Primarily affects internal observability rather than pipeline behavior.

---

#### Milestone 3: V3 → V4 Migration Tool

**Parallel group:** foundation | **Depends on:** M01, M02

Files to create/modify:
- Create `tools/migration/__init__.py`
- Create `tools/migration/migrate.py` — CLI entry point (`tekhton migrate`)
- Create `tools/migration/detect.py` — V3 project detection (`.claude/` directory, `CLAUDE.md` without `AGENT.md`, absence of `.tekhton/version`, legacy `NFR_POLICY_*` config keys)
- Create `tools/migration/transform/__init__.py` — transformation registry
- Create `tools/migration/transform/directory.py` — `.claude/` → `.tekhton/` directory rename
- Create `tools/migration/transform/context_files.py` — `CLAUDE.md` → `AGENT.md` split (provider-neutral content to AGENT.md, Anthropic-specific content remaining in CLAUDE.md as overlay)
- Create `tools/migration/transform/nfr_config.py` — `NFR_POLICY_*` with `block/warn/log` → `NFR_CRITICALITY_*` with `must/should/could`
- Create `tools/migration/transform/pipeline_conf.py` — provider defaults, bridge enablement, storage abstraction config
- Create `tools/migration/validate.py` — post-migration self-check
- Create `tools/migration/report.py` — migration scope surfacing and consent prompt
- Modify `tekhton.sh` — detect V3 project on startup, invoke migration tool with consent prompt
- Modify `lib/config_defaults.sh` — add `TEKHTON_VERSION` marker config
- Create `tests/test_migration.sh` — V3 → V4 migration scenarios, V3 protection check
- Create `tools/tests/test_migration.py` — Python migration tool tests

Acceptance criteria:
- Migration tool detects V3 projects via filesystem probe and config inspection
- `tekhton migrate --dry-run` surfaces the full migration scope without modification
- `tekhton migrate` prompts the operator with the migration scope and requires explicit "yes" to proceed; any other input exits without modification
- All transformations execute atomically; partial migration on error is rolled back
- Post-migration validation runs automatically before the version marker is written
- `.tekhton/version` marker file is written with V4 version identifier and migration timestamp
- V3 Tekhton running against a migrated project detects the version marker and produces a clear error directing the operator to upgrade their Tekhton CLI
- Migration is idempotent: running the tool on an already-migrated project is a no-op
- The subsequent milestones M04+ add their own transform modules to `tools/migration/transform/` as new V4 schemas land, registered via the transformation registry
- All existing tests pass
- `shellcheck tools/migration/migrate.sh` and `python -m mypy tools/migration/` pass

Watch For:
- The migration tool must run without Tekhton bridge or provider adapters being initialized (bridge comes in M04+); it operates purely on filesystem and config transformation
- The `.claude/mcp_servers.json` file is Claude CLI's config and must be preserved under `.claude/` even after the directory migration (this is the one deliberate exception per the Design Philosophy notes)
- Transformations that write new files must use atomic rename patterns so a crash mid-migration leaves the project in a recoverable state (either fully V3 or fully V4, never mixed)
- The consent prompt must be explicit and non-defaultable; operators running in automation contexts should set `TEKHTON_MIGRATE_CONFIRM=yes` environment variable rather than rely on piped input

Seeds Forward:
- Each subsequent V4 milestone that introduces a new schema adds a corresponding transform module to `tools/migration/transform/`
- The migration tool's event log records what transformed, in what order, and at what time, providing an audit trail for enterprise compliance
- Post-V4, the migration tool pattern is reusable for V4 → V5 migration when V5 introduces further breaking changes

---

#### Milestone 4: Bridge Core Architecture & Shell Routing

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
- When `BRIDGE_ENABLED=true` (V4 default, per tenet 1) and provider is `anthropic`, still uses `claude` CLI as the optimized fast path
- When `BRIDGE_ENABLED=true` and provider is non-anthropic, calls `tekhton-bridge`
- When `BRIDGE_ENABLED=false` (explicit opt-out for specific local-development reasons), all calls go through `claude` CLI; this is an operator override, not the default
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
- M05 and M06 implement concrete adapters against this base
- M07 adds failover logic to the bridge core
- M08 adds MCP gateway capability
- M15 (NL task decomposition) uses bridge for non-Anthropic PM agents

---

#### Milestone 5: Anthropic Direct API Adapter

**Parallel group:** bridge | **Depends on:** M04

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
- M07 uses this adapter as the failover target when claude CLI is throttled
- The adapter validates the bridge architecture before adding more providers
- Direct API access enables future features (batching, prompt caching control)

---

#### Milestone 6: OpenAI & Ollama Adapters

**Parallel group:** bridge | **Depends on:** M04

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
- M07 uses these adapters for failover targets
- M08 adds MCP gateway capability to these adapters
- Users can immediately start using OpenAI or local models for any stage

---

#### Milestone 7: Provider Failover, Calibration & Cost Ledger

**Parallel group:** bridge | **Depends on:** M05, M06

Files to create/modify:
- Create `tools/bridge/failover.py` — failover logic, provider health monitoring,
  automatic switching
- Create `tools/bridge/calibration.py` — provider profile generation, prompt
  adjustment recording, validation
- Create `tools/bridge/cost.py` — cost calculation, pricing tables, ledger
  management, `update-pricing` command
- Create `.tekhton/bridge/` directory structure (profiles/, cost_ledger.jsonl)
- Modify `tools/bridge/bridge.py` — integrate failover, calibration, cost tracking
- Modify `lib/config_defaults.sh` — add `BRIDGE_FAILOVER_ENABLED`,
  `BRIDGE_FAILOVER_PROVIDER`, `BRIDGE_COST_TRACKING`
- Create `tools/tests/test_failover.py` — failover scenarios
- Create `tools/tests/test_calibration.py` — profile generation
- Create `tools/tests/test_cost.py` — cost calculation, ledger format
- Create `tests/test_bridge_cost.sh` — shell-side cost ledger verification

Acceptance criteria:
- `tekhton-bridge calibrate --provider openai` runs representative prompts,
  stores profile in `.tekhton/bridge/profiles/openai.json`
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
- M11 (parallel budgeting) distributes quota using cost ledger data
- M14 (Watchtower cost dashboard) reads the cost ledger
- M20 (cost forecasting) uses historical cost data for predictions
- M24 (NFR cost checks) validates against cost ceilings from the ledger

---

#### Milestone 8: MCP Gateway for Non-Anthropic Providers

**Parallel group:** bridge | **Depends on:** M06

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
  claude CLI (`.claude/mcp_servers.json` or equivalent — this file is Claude CLI's own config, so it stays under `.claude/`)
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

### DOGFOOD CHECKPOINT 2: Bridge Complete (After M08)

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
- `.tekhton/bridge/cost_ledger.jsonl` populates after a run

**Dogfood validation:** Run Tekhton against the test suite with both Anthropic and at least one non-Anthropic provider configured. The Anthropic path through the claude CLI is preserved as the optimized fast path (B2 architecture); non-Anthropic providers exercise the bridge end-to-end. If validation fails, abort the checkpoint before proceeding; the Phase 1 checkpoint is the safety boundary per tenet 7.

**Risk:** Medium — bridge is substantial new code. Anthropic fast path is unchanged; non-Anthropic paths are first-time execution against the bridge.

---

### Phase 2: Core Capabilities (M09-M20)

#### Milestone 9: Parallel Coordinator & Worktree Lifecycle

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
  `.tekhton/worktrees/team-1/` on branch `tekhton/parallel/m05`
- Team status files (`TEAM_STATUS.json`) written with: team_id, milestone_id,
  stage, started_at, status
- Coordinator reads DAG frontier, groups by parallel_group, spawns teams up to
  `PARALLEL_MAX_TEAMS`
- Each team runs a full pipeline (coder → reviewer → tester) in its worktree
- `_remove_team_worktree()` cleans up worktree and branch
- `PARALLEL_ENABLED=false` is an explicit operator override for serial execution; the V4 default is `true` (parallel by default per tenet 4)
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

#### Milestone 10: Parallel Conflict Detection & Merge

**Parallel group:** parallel | **Depends on:** M09

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
  a post-merge build gate (M11) as the safety net.

Seeds Forward:
- M10 adds shared build gate after merge to catch subtle merge issues
- V5's stage-level parallelism will reuse conflict detection infrastructure

---

#### Milestone 11: Parallel Resource Budgeting & Shared Build Gate

**Parallel group:** parallel | **Depends on:** M07, M10

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
- Budget tracking integrates with cost ledger (M07) for actual cost data
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

#### Milestone 12: Watchtower Server Mode & WebSocket

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
- File watcher monitors `.tekhton/watchtower/*.json` and `.tekhton/logs/events.jsonl`
- Dashboard auto-detects server vs static mode (WebSocket vs polling)
- `tekhton --watchtower-stop` cleanly shuts down server
- Server PID tracked in `.tekhton/watchtower.pid`
- All existing tests pass

Watch For:
- Port already in use — detect and report clearly, suggest alternative port.
- Server must not block the pipeline. It runs as a background process.
- WebSocket connections from stale browser tabs — implement heartbeat/ping.
- Static mode must continue to work when server is not running. The dashboard
  detects which mode is available and adapts.

Seeds Forward:
- M12 adds interactive controls through the REST API
- M14 adds cost dashboard and parallel team views
- M19 CI/CD mode may disable served Watchtower (headless environment)

---

#### Milestone 13: Watchtower Interactive Controls

**Parallel group:** watchtower | **Depends on:** M12

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
  `.tekhton/inbox/task_<timestamp>.json`
- Note submission form creates `.tekhton/inbox/note_<timestamp>.json`
- Run control (pause/resume/abort) creates `.tekhton/inbox/control_<timestamp>.json`
- `_process_inbox()` reads and processes inbox files at pipeline checkpoints
- Processed files moved to `.tekhton/inbox/processed/`
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
- M14 adds cost and parallel views to the interactive UI
- M14 (NL task decomposition) can be triggered from Watchtower's task form
- M17 (GitHub integration) can sync issues to Watchtower's task queue

---

#### Milestone 14: Watchtower Cost Dashboard & Parallel Team View

**Parallel group:** watchtower | **Depends on:** M07, M11, M13

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
- Cost data sourced from `.tekhton/bridge/cost_ledger.jsonl`
- Team data sourced from `.tekhton/worktrees/team-N/TEAM_STATUS.json`
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
- M20 (cost forecasting) adds prediction data to the cost dashboard
- V5's cloud-hosted Watchtower reuses these API endpoints and UI components

---

### DOGFOOD CHECKPOINT 3: Parallel Ready (After M11)

**Action:** Optionally enable parallel execution for remaining milestones.

**What's new:**
- Parallel milestone execution via git worktrees
- Conflict detection and merge strategies
- Resource budgeting across teams

**What to verify after upgrade:**
- `PARALLEL_ENABLED=true` and `PARALLEL_MAX_TEAMS=2` in pipeline.conf
- Run two independent milestones — verify both complete and merge cleanly
- Check `.tekhton/worktrees/` cleanup after run

**Dogfood validation:** Run Tekhton on a multi-milestone project with `PARALLEL_MAX_TEAMS=2` to validate parallel execution behavior before moving to the full parallel ceiling. The operator override `PARALLEL_ENABLED=false` remains available for specific local-development scenarios where serial execution is preferred, but the V4 default is parallel.

**Risk:** Higher — parallel execution is complex. Start with `PARALLEL_MAX_TEAMS=2` to limit blast radius during validation.

---

#### Milestone 15: Natural Language Task Decomposition

**Parallel group:** owner | **Depends on:** M04

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
- Decomposition uses project context (AGENT.md, DESIGN.md, optional provider overlays, detected stack) to
  ground milestones in the project's architecture
- Generated milestones are written to `.tekhton/milestones/` and MANIFEST.cfg
  in proper DAG format
- `PM_AUTO_DECOMPOSE=true` automatically generates milestones from NL input
- `PM_AUTO_DECOMPOSE=false` presents proposed milestones for user approval
- Precise engineering task descriptions flow through the same intake path as natural language input, producing the same milestone decomposition schema
- All existing tests pass

Watch For:
- NL decomposition quality varies by model. The PM prompt must include 2-3
  concrete examples of input→output transformations.
- Over-decomposition risk: "add a button" shouldn't become 5 milestones.
  Include guidance on appropriate granularity.
- The PM agent must respect the project's existing milestone numbering. New
  milestones get IDs after the highest existing one.

Seeds Forward:
- Watchtower's task form (M13) triggers NL decomposition when user submits
  natural language
- V5's "Maximum" scope builds on this for full product requirement → deployment

---

#### Milestone 16: Design Artifact Intake

**Parallel group:** owner | **Depends on:** M08, M13, M15

Files to create/modify:
- Create `lib/design_intake.sh` — design artifact resolution, normalization, attachment to milestone context
- Create `lib/integrations/figma_adapter.sh` — Figma REST API client (personal access token or OAuth)
- Create `lib/integrations/design_file_adapter.sh` — CSS/HTML/SVG mock parsing, screenshot handling
- Modify `stages/intake.sh` — detect attached design artifacts, route through `lib/design_intake.sh`, blend with NL input
- Create `prompts/design_intake.prompt.md` — vision-model prompts for screenshot analysis
- Modify `lib/config_defaults.sh` — add `DESIGN_INTAKE_ENABLED`, `FIGMA_API_TOKEN`, `FIGMA_OAUTH_CLIENT_ID`, `DESIGN_INTAKE_VISION_MODEL`, `DESIGN_ARTIFACT_DIR`, `DESIGN_INTAKE_FORMATS`
- Modify `tools/watchtower_server.py` — add `POST /api/v1/design_artifacts` endpoint, integrate file upload with task form
- Modify `templates/watchtower/` — task submission panel accepts design artifact attachments (Figma URLs, file uploads)
- Create `tests/test_design_intake.sh` — format detection, Figma extraction, screenshot analysis, CSS/HTML parsing, normalized spec generation
- Create `tools/tests/test_figma_adapter.py` — Figma API contract tests with recorded fixtures

Acceptance criteria:
- Figma intake: given a Figma file URL and valid token, `lib/integrations/figma_adapter.sh` extracts component tree, layout metadata, design tokens (color, spacing, typography), text content, and prototype interaction links
- Screenshot intake: given a PNG or JPG, the vision-capable model (configured via `DESIGN_INTAKE_VISION_MODEL`) extracts layout description, identifies UI elements, captures color and text content, and infers interaction intent
- CSS/HTML mock intake: given HTML and linked stylesheets, parser extracts component structure and style tokens
- SVG intake: given an SVG file, parser extracts elements, text content, and basic visual structure
- All format paths produce a normalized design spec following a common schema
- The design spec attaches to the milestone context and drives acceptance criteria that include visual match requirements
- Milestones generated from design artifacts reference the originating artifact by path in `.tekhton/design_artifacts/<artifact-id>/`
- Originals are preserved alongside normalized specs for traceability
- `DESIGN_INTAKE_ENABLED=false` bypasses the path entirely with no impact on NL-only intake
- Watchtower task form surfaces design artifact attachment UI and handles upload to `POST /api/v1/design_artifacts`
- All existing tests pass
- `shellcheck lib/design_intake.sh lib/integrations/figma_adapter.sh lib/integrations/design_file_adapter.sh` passes
- `python -m mypy tools/bridge/` passes for any vision-model integration code

Watch For:
- Figma API rate limits: batch requests where possible, cache the extracted spec with Figma's version id, re-pull only when the file changes
- Vision-model screenshot analysis accuracy varies by model capability; the `DESIGN_INTAKE_VISION_MODEL` config should default to a capable model (Claude 3+ or GPT-4V equivalent) but allow override for cost-sensitive deployments
- Large design files (Figma documents with thousands of nodes) can produce oversized specs; the adapter must support selective extraction (specific frames, specific pages) via URL fragment or config
- CSS/HTML mocks sometimes reference external assets the adapter can't fetch; the parser must degrade gracefully and note missing references in the spec rather than failing
- Design artifact uploads through Watchtower require size limits and content-type validation; follow the existing `POST /api/v1/tasks` pattern but with file upload support

Seeds Forward:
- M18 Goldprints can register pattern-matching for design artifacts (e.g., "this Figma component matches the standard card pattern; apply card Goldprint")
- M33 Context Graph horizontal integration consults the design artifact references when surfacing related project work in the Organizational Context tab
- V5 adds Sketch, Adobe XD, and Framer adapters against the same interface; the adapter registry in `lib/integrations/design_file_adapter.sh` is designed for extension

---

#### Milestone 17: Storage Abstraction Layer

**Parallel group:** owner | **Depends on:** M02

Files to create/modify:
- Create `lib/storage/storage.sh` — backend-agnostic interface (`list`, `get`, `put`, `delete`, `watch`, `query`)
- Create `lib/storage/adapters/git.sh` — git repository backend, supporting local clone and remote repository references
- Create `lib/storage/adapters/postgres.sh` — PostgreSQL backend with JSONB metadata columns and content column or blob
- Create `lib/storage/adapters/s3.sh` — S3 and S3-compatible object storage backend (MinIO, Cloudflare R2, Backblaze B2)
- Create `lib/storage/metadata.sh` — common metadata envelope (id, version, content_type, created_at/by, updated_at/by, scope, tags, parent_id, supersedes, depends_on, backend_native)
- Create `tools/storage/` Python helpers for postgres and s3 backends that need client libraries (psycopg2, boto3)
- Modify `lib/config_defaults.sh` — add `STORAGE_BACKEND`, `STORAGE_URL`, per-content-type backend selection
- Create `tests/test_storage.sh` — interface contract tests, round-trip tests across backends
- Create `tools/tests/test_storage_postgres.py` — PostgreSQL backend tests with ephemeral DB
- Create `tools/tests/test_storage_s3.py` — S3 backend tests with MinIO fixture

Acceptance criteria:
- The storage abstraction defines and enforces the interface contract across all three V4 backends
- `git://` backend supports PR-based review flow, full version history, and CODEOWNERS integration; content is stored as files in the configured git repository, metadata in sidecar YAML
- `postgres://` backend stores content and metadata in relational tables; supports structured queries via `query(criteria)` returning matching items; version history via temporal columns
- `s3://` backend stores content as objects; metadata as object tags plus a sidecar index in PostgreSQL (if configured) or a separate metadata file in the same bucket
- Round-trip tests demonstrate `put` → `get` returns identical content and metadata across all three backends
- `watch(path)` emits change notifications for cache invalidation and Watchtower live updates; filesystem backends use inotify/FSEvents, database backends use LISTEN/NOTIFY, S3 backends use bucket event notifications
- Configuration supports per-content-type backend selection (project-tier Goldprints in git, enterprise-tier in postgres, design artifacts in s3, etc.)
- Metadata envelope is consistent across backends; backend-native fields preserved for round-trips without loss
- All existing tests pass
- `shellcheck lib/storage/*.sh` passes
- `python -m mypy tools/storage/` passes

Watch For:
- Git backend performance on large repositories: use sparse checkout for enterprise-scale deployments, avoid full-history operations on hot paths
- PostgreSQL backend transaction semantics: `put` operations must be atomic; `watch` must use LISTEN/NOTIFY rather than polling
- S3 backend eventual consistency: some S3-compatible services have eventual consistency on reads after writes; the adapter must detect and handle this (read-after-write retry with backoff, or document the limitation per service)
- Metadata envelope versioning: future V5 additions to the envelope must not break V4 backends; the `backend_native` field is the escape hatch for backend-specific metadata that V5 generalizes later
- Storage backend URL format must support authentication: `postgres://user:password@host:port/db` with credentials pulled from the M27 secret manager, not plaintext in config

Seeds Forward:
- M18 Goldprints are the V4 consumer of the storage abstraction; per-tier configuration drives where Goldprints physically live
- V5 migrates design artifacts, releases, deliverables, and Watchtower data files to the storage abstraction
- V5 adds Azure Blob Storage, Google Cloud Storage, and filesystem-plus-sync backends against the same interface

---

#### Milestone 18: Goldprints Subsystem + Watchtower UI

**Parallel group:** owner | **Depends on:** M17, M15

Files to create/modify:
- Create `lib/goldprints/resolver.sh` — domain-and-scope-filtered Goldprint resolution
- Create `lib/goldprints/renderer.sh` — role-based markdown-to-prompt rendering for all six agent roles
- Create `lib/goldprints/config_override.sh` — extraction and merging of `agent_config_hints` from applicable Goldprints
- Create `lib/goldprints/enforcer.sh` — hard-rule validation after agent output; coordinates with reviewer stage
- Create `lib/goldprints/loader.sh` — parses markdown + frontmatter Goldprint files from tier-specific storage
- Modify `lib/context_compiler.sh` — call Goldprint resolver and renderer, allocate Goldprint section budget, render into context
- Create `prompts/goldprints_section.partial.md` — prompt template fragment for the Goldprint section
- Create `tools/goldprint_cache.py` — pre-rendered Goldprint caching by (goldprint_id, version, role) hash
- Create `tools/mcp/goldprint_fetch.py` — MCP tool implementation for `get_goldprint(id)` on-demand fetches
- Modify `tools/watchtower_server.py` — add Goldprint endpoints (`GET /api/v1/goldprints`, `GET /api/v1/goldprints/:id`, `POST /api/v1/goldprints`, `PUT /api/v1/goldprints/:id`, `POST /api/v1/goldprints/:id/promote`)
- Modify `templates/watchtower/` — Goldprint Browser, Detail, Author/Edit (with LLM assistance chat panel), Promotion Workflow, Adoption Dashboard views
- Modify `lib/config_defaults.sh` — add `GOLDPRINTS_ENABLED`, `GOLDPRINTS_ENTERPRISE_REPO`, `GOLDPRINTS_ORG_REPOS`, `GOLDPRINTS_LOCAL_DIR`, `GOLDPRINTS_CONTEXT_BUDGET_PCT`, `GOLDPRINTS_PROGRESSIVE_DISCLOSURE`, `GOLDPRINTS_ENFORCE_HARD_RULES`, `GOLDPRINTS_EXPERIMENTAL_OPT_IN`
- Create `tests/test_goldprints.sh` — resolver, renderer, enforcer, config override, promotion workflow
- Create `tools/tests/test_goldprint_cache.py` — cache hit/miss semantics, version invalidation

Acceptance criteria:
- Resolver queries the storage abstraction (M17) for applicable Goldprints filtered by domain tags and scope hierarchy (project → org → enterprise), returning a ranked list with metadata
- Renderer produces role-specific prompt fragments for coder, reviewer, tester, architect, security, and jr coder based on the Goldprint file's section structure
- Context compiler integration: default 20% of the context budget is allocated to Goldprints; hard-rule Goldprints always fully rendered; advisory Goldprints appear as summary cards when budget-constrained
- Config override: `agent_config_hints` from applicable Goldprints are extracted and merged with the stage's default agent config before `run_agent()` fires; hard-rule hints override advisory hints
- Enforcer: after the coder agent returns, the reviewer stage consults `lib/goldprints/enforcer.sh` with the set of applicable hard-rule Goldprints; violations produce `goldprint.violated` events and route back to coder with specific violation metadata
- Progressive disclosure: the Goldprint manifest in the main context includes summary cards for advisory Goldprints; the agent can fetch full content via the `get_goldprint(id)` MCP tool call
- Watchtower Goldprint Browser supports filtering by tier, domain, lifecycle status, scope, and rule type; adoption count is displayed per Goldprint
- Watchtower Goldprint Detail view shows full content with metadata sidebar (author, reviewers, versions, timestamps, supersession chain, NFR registrations, dependencies)
- Watchtower Goldprint Author/Edit view provides markdown editor with live preview, frontmatter form, and LLM assistance chat panel with context-aware actions (draft new, refine section, generate test scaffold, check frontmatter)
- Watchtower Promotion Workflow view surfaces approval status, Tekhton contextual signal, and NFR compliance check; promote action writes audit log entry
- Cache invalidation triggered on version bump; cache hit rates target ≥90% for repeated milestone runs on the same project
- All existing tests pass
- `shellcheck lib/goldprints/*.sh` and `python -m mypy tools/` pass

Watch For:
- Resolver performance: the domain-tag filter must happen in the storage backend (SQL query or git-grep) before the Goldprints are loaded into memory; naive "load all then filter" does not scale past a few hundred Goldprints
- Context budget allocation: the 20% default is a starting point; deployments with small context windows (e.g., Ollama local models) may need a smaller Goldprint budget, configurable via `GOLDPRINTS_CONTEXT_BUDGET_PCT`
- Progressive disclosure round-trip cost: the `get_goldprint(id)` MCP tool call adds latency on each fetch; the agent should batch fetches where possible
- Enforcer validation severity: static pattern matching (regex over source files) catches most violations cheaply; agent-assisted validation (asking the reviewer agent to confirm Goldprint compliance) should be used sparingly to avoid token cost
- Goldprint Author/Edit LLM chat panel must not accidentally leak the project's secrets or sensitive code into the assistant context; the chat panel's context is the Goldprint being edited plus sibling Goldprints, not the full project

Seeds Forward:
- M32 Goldprint-to-graph bridge adapter (`lib/context/adapters/goldprints.sh`) records authoring and consumption events into the Context Graph
- V5 adds semantic similarity for Goldprint recommendation via pgvector, predictive adoption modeling, failure/success correlation
- V5 adds advanced Watchtower Goldprint UI: conflict resolution, semantic similarity recommendations, pattern suggestion from graph analysis

---

#### Milestone 19: Release Notes & Changelog Automation + Code Provenance

**Parallel group:** owner | **Depends on:** M02

Files to create/modify:
- Create `lib/release.sh` — `_generate_release_notes()`,
  `_update_changelog()`, `_generate_deliverable_summary()`
- Create `lib/provenance.sh` — code provenance metadata generation; commit trailer formatting; structured event enrichment with provenance fields
- Modify `lib/finalize.sh` — call release note generation and provenance attachment after milestone completion
- Modify `lib/finalize_display.sh` — project-owner-friendly completion banner
  (what was built, what to review, files changed, tests status, provenance summary)
- Modify `lib/agent.sh` — emit `agent.invoked` events with agent role, Goldprint ids, user identity, milestone id, model/provider version
- Modify `lib/causality.sh` — enrich all events with the provenance metadata envelope
- Modify git commit generation in `stages/coder.sh`, `stages/tester.sh`, `stages/security.sh` — add commit trailer lines with provenance metadata (agent role, Goldprint ids consumed, user identity, milestone id, run id, model/provider version)
- Modify `templates/watchtower/` — Milestone Map tab surfaces the provenance chain per milestone
- Modify `lib/config_defaults.sh` — add `RELEASE_NOTES_ENABLED`,
  `CHANGELOG_ENABLED`, `CHANGELOG_FILE`, `DELIVERABLES_DIR`, `PROVENANCE_ENABLED`, `PROVENANCE_COMMIT_TRAILERS`
- Create `tests/test_release.sh` — release note format, changelog format,
  deliverable package contents
- Create `tests/test_provenance.sh` — commit trailer formatting, event enrichment, Milestone Map surfacing

Acceptance criteria:
- After milestone completion, release notes generated at
  `.tekhton/deliverables/release_<milestone_id>.md`
- Release notes contain: what's new (non-technical), setup required, technical
  details (files changed, tests added), provenance section (which agents produced which changes, which Goldprints guided the work, which user initiated the run)
- Changelog entry appended to CHANGELOG.md in Keep a Changelog format
- Completion banner shows plain-language summary: task, status, duration, cost
  (if available), what was built, what to review, provenance summary (agent role counts, Goldprints consumed)
- Deliverable package (`.tekhton/deliverables/`) contains: summary.md,
  release_notes.md, changelog_entry.md, test_report.md, diff_summary.md, provenance.json
- Every commit produced by Tekhton includes provenance trailer lines in the format: `Tekhton-Agent-Role: coder`, `Tekhton-Goldprint: GP-001@2.3.0`, `Tekhton-User: user@example.com`, `Tekhton-Milestone: M18`, `Tekhton-Run-Id: <run-id>`, `Tekhton-Model: anthropic/claude-4.6-sonnet`
- Causal event log events all carry a `provenance` sub-object with these fields
- Watchtower's Milestone Map tab surfaces the provenance chain per milestone, grouping changes by agent role and Goldprint
- `RELEASE_NOTES_ENABLED=false` is an explicit operator override for deployments that don't want release notes generated (e.g., ephemeral CI runs); the V4 default is `true` since release notes are a project owner deliverable per tenet 2
- `PROVENANCE_ENABLED=false` disables commit trailer and event enrichment; the V4 default is `true` since provenance is part of the enterprise deployability baseline (see the Enterprise Deployability section for the architectural rationale)
- All existing tests pass

Watch For:
- Release notes are generated from git diffs and stage reports, NOT from an
  additional agent call. Keep it cheap. An optional agent polish pass can be
  added later.
- CHANGELOG.md must be appended to, not overwritten. Check for existing content.
- The completion banner must fit in a standard terminal width (80 chars).
- Commit trailer format must be compatible with git's trailer parsing conventions (`-c trailer.separators=:`); avoid characters that git treats as separators within trailer values
- Provenance metadata must not include sensitive data (no API keys, no user PII beyond identity attribution); the event log will be shipped to SIEM systems, so provenance payloads are treated as auditable but not confidential
- Multi-author commits (when multiple agent roles contribute to a single change) list all contributing roles in the trailer, preserving the provenance chain

Seeds Forward:
- M20 adds cost data to release notes and deliverables
- M21 (GitHub integration) uses release notes for GitHub Releases and uses provenance trailers for Co-Authored-By lines (with the Tekhton agent role attribution)
- Watchtower Reports tab displays deliverable summaries; Milestone Map tab surfaces provenance chain
- V5 adds cryptographic signing of commit trailers and verifiable provenance chains on top of the V4 structured metadata baseline

---

#### Milestone 20: Cost Forecasting & Deliverable Packages + SBOM Generation

**Parallel group:** owner | **Depends on:** M07, M19

Files to create/modify:
- Modify `lib/release.sh` — add `_forecast_cost()`, integrate cost data into
  release notes and deliverables
- Modify `tools/watchtower_server.py` — add `GET /api/v1/costs/forecast`
- Modify `lib/finalize_display.sh` — add cost summary to completion banner
- Create `lib/cost_forecast.sh` — historical analysis, per-milestone averaging,
  complexity-weighted prediction
- Create `lib/sbom.sh` — SBOM generation orchestration, per-language toolchain dispatch
- Create `tools/sbom/` — Python helpers for SBOM format generation and dependency extraction
- Create `tools/sbom/generate.py` — SPDX and CycloneDX format generation
- Create `tools/sbom/scanners/js.py` — JavaScript/TypeScript SBOM via `npm` package-lock or `yarn.lock`
- Create `tools/sbom/scanners/python.py` — Python SBOM via `pip-licenses` or equivalent
- Modify `lib/finalize.sh` — invoke SBOM generation as part of the deliverable packaging step
- Modify `lib/config_defaults.sh` — add `COST_FORECAST_ENABLED`, `SBOM_ENABLED`, `SBOM_FORMATS`, `SBOM_LANGUAGES`, `SBOM_VULNERABILITY_SCANNER`
- Create `tests/test_cost_forecast.sh` — forecast accuracy, edge cases
- Create `tests/test_sbom.sh` — SBOM generation for JS/TS and Python fixtures, format validation

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
- SBOM generation: after each milestone completion, SPDX and CycloneDX format SBOMs are generated and attached to the deliverable artifact package
- SBOM covers JavaScript/TypeScript (via package-lock.json or yarn.lock) and Python (via requirements.txt, pyproject.toml, or installed packages) as the V4 language baseline
- SBOM includes package name, version, license, and dependency relationships in both SPDX 2.3 and CycloneDX 1.5 formats
- SBOM validation: generated files pass `spdx-tools` (or equivalent) validation for schema correctness
- Optional dependency vulnerability scanning integration point: if `SBOM_VULNERABILITY_SCANNER` is configured (candidates: Snyk, GitHub Dependabot, Sonatype Nexus IQ, JFrog Xray), scan results are attached to the deliverable package alongside the SBOM
- `COST_FORECAST_ENABLED=false` disables forecasting; `SBOM_ENABLED=false` disables SBOM generation (both as explicit operator overrides)
- All existing tests pass

Watch For:
- First-run forecasts are necessarily inaccurate. Display with appropriate
  confidence indicators ("estimated" vs "based on N prior runs").
- Cost data may not be available if `BRIDGE_COST_TRACKING=false`. Forecast
  must degrade gracefully (show "cost tracking disabled" not an error).
- SBOM generation must not fail the milestone on scanner errors; log the error, include a note in the deliverable package, and continue
- SBOM format validation is strict; malformed SBOMs fail enterprise supply-chain review, so the generator must produce schema-valid output with all required fields
- Dependency vulnerability scanner output formats vary; the adapter interface normalizes to a common format before attaching to the deliverable package

Seeds Forward:
- M14 (Watchtower cost dashboard) displays forecast alongside actuals
- M24 (NFR cost checks) uses forecast data for budget ceiling warnings
- V5 extends SBOM language coverage to additional ecosystems (Go, Rust, Java, C#, Ruby, PHP)
- V5 adds SLSA attestation at level 3+ with in-toto provenance chains on top of the V4 SBOM baseline

---

### DOGFOOD CHECKPOINT 4: Core Complete (After M20)

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
- Release notes generated in `.tekhton/deliverables/`

**Dogfood validation:** Submit a test task via Watchtower's task form, verify NL decomposition runs, and confirm release notes and cost tracking populate as expected. Individual features retain per-feature `_ENABLED` toggles for operator-level configuration of what's active in a given deployment, but the V4 defaults have all Phase 2 features enabled as the enterprise-grade baseline.

**Risk:** Low — Watchtower improvements don't affect pipeline execution. Release notes and cost tracking are additive outputs.

---

### Phase 3: Enterprise & Integration (M21-M33)

#### Milestone 21: GitHub Integration

**Parallel group:** integration | **Depends on:** M02, M19

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
- On `release.ready`: creates GitHub Release with release notes (from M19)
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

#### Milestone 22: Slack/Teams & Webhook Notifications

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

#### Milestone 23: Log Shipping & CI/CD Mode

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
  `.tekhton/logs/events.jsonl` for external agent pickup (DataDog/Splunk agents)
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

#### Milestone 24: NFR Engine & Cost/SLA Checks

**Parallel group:** nfr | **Depends on:** M02, M07

Files to create/modify:
- Create `lib/nfr.sh` — `run_nfr_checks()`, check engine, violation policy
  enforcement, anomaly detection
- Modify `lib/gates.sh` — integrate NFR checks into build gate and acceptance gate
- Modify `lib/orchestrate.sh` — cost ceiling checks after each agent invocation,
  SLA timeout checks continuously
- Modify `lib/config_defaults.sh` — add all `NFR_*` config keys (cost, SLA,
  policy defaults)
- Create `.tekhton/nfr.conf.example` — example NFR configuration
- Create `tests/test_nfr.sh` — check engine, MoSCoW criticality, cost/SLA checks

Acceptance criteria:
- `run_nfr_checks("post-build")` runs all enabled checks for that timing point
- Cost ceiling check: blocks pipeline when actual cost exceeds
  `NFR_COST_MAX_PER_MILESTONE` (if criticality=must)
- Cost alert: warns when cost exceeds `NFR_COST_ALERT_PCT` of ceiling
- SLA check: warns when milestone duration exceeds `NFR_SLA_MILESTONE_TIMEOUT_S`
- Stage timeout: warns when stage exceeds `NFR_SLA_STAGE_TIMEOUT_S`
- MoSCoW criticality: `must` stops pipeline, `should` logs prominent warning, `could` logs at standard severity, `wont` records explicit waiver with rationale
- `_check_pipeline_anomalies()` detects: stage 3x longer than historical average,
  cost per turn 2x higher than normal, max turns hit 3 consecutive times
- NFR events emitted: `nfr.check`, `nfr.violation`, `nfr.anomaly`
- NFR checks are per-category opt-in via `NFR_*_ENABLED`; projects enable the categories relevant to their domain (e.g., PII-handling projects enable security and coverage; performance-sensitive projects enable perf and SLA)
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
- M34 (learning) feeds anomaly patterns into the knowledge base

---

#### Milestone 25: NFR Performance, Accessibility, Coverage & License Checks

**Parallel group:** nfr | **Depends on:** M24

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

#### Milestone 26: NFR Model Governance Category

**Parallel group:** nfr | **Depends on:** M04, M24

Files to create/modify:
- Modify `lib/nfr.sh` — register `NFR_MODEL_*` category checks at post-invocation timing point
- Create `lib/nfr_model.sh` — model allowlist/denylist enforcement, model version attribution validation, output governance hooks
- Modify `lib/agent.sh` — call model governance checks before invoking the bridge for non-allowlisted model requests
- Modify `lib/config_defaults.sh` — add `NFR_MODEL_ENABLED`, `NFR_MODEL_ALLOWLIST`, `NFR_MODEL_DENYLIST`, `NFR_MODEL_CRITICALITY`, `NFR_MODEL_OUTPUT_GOVERNANCE_HOOK`
- Create `.tekhton/nfr_model.conf.example` — example model governance configuration with per-scope allowlist/denylist patterns
- Create `tests/test_nfr_model.sh` — allowlist enforcement, denylist enforcement, MoSCoW criticality on violations, output governance hook invocation

Acceptance criteria:
- `NFR_MODEL_ALLOWLIST` config declares which provider/model combinations are permitted at the given scope tier (enterprise, org, project); e.g., `anthropic/claude-4.6-sonnet,openai/gpt-4.1,ollama/llama-3-70b`
- `NFR_MODEL_DENYLIST` config declares which provider/model combinations are explicitly blocked; denylist takes precedence over allowlist
- Model governance check runs before each `run_agent()` invocation; if the configured model is not allowlisted or is denylisted, the check fires at the configured MoSCoW criticality
- Model version attribution is verified: every successful invocation records the actual provider/model version to the causal event log, allowing downstream audit to confirm policy compliance
- Output governance hook: if `NFR_MODEL_OUTPUT_GOVERNANCE_HOOK` is configured, invoke the hook with the agent output before deliverable packaging; hooks that return non-zero block the milestone with an audit trail entry
- MoSCoW criticality on violations: `must` blocks the invocation pre-flight, `should` warns prominently and records the invocation with a warning event, `could` logs, `wont` records explicit waiver
- Scope hierarchy respected: org allowlist must be a subset of enterprise allowlist unless the project has explicit opt-out; project allowlist must be a subset of org allowlist
- NFR events emitted: `nfr.model.check`, `nfr.model.violation`, `nfr.model.output_governance`
- All existing tests pass
- `shellcheck lib/nfr_model.sh` passes

Watch For:
- The allowlist check happens pre-invocation, which adds latency to every agent call; the implementation must be cheap (config lookup, string match)
- Output governance hooks may be expensive (running a review agent); they should only fire at milestone boundaries, not per-invocation
- Denylist takes precedence over allowlist: a model in both lists is denied; this matches enterprise intuition where denials are stronger than permissions
- The model version recorded in the event log comes from the bridge's response, which is the authoritative source; don't trust the config value since the provider may substitute a different version

Seeds Forward:
- V5 adds full model governance policy engine with training data transparency, cryptographic model integrity attestation, and regulatory-specific qualification workflows (FDA SaMD, etc.)
- V5 adds the Watchtower administrative UI for model policy configuration; V4 stays with config-file-driven administration

---

#### Milestone 27: Secret Manager Abstraction

**Parallel group:** deployability | **Depends on:** M02

Files to create/modify:
- Create `lib/secrets/secrets.sh` — backend-agnostic secret resolution interface (`_secret_get`, `_secret_list`, `_secret_rotate_stub`)
- Create `lib/secrets/adapters/vault.sh` — HashiCorp Vault adapter; KV v2 engine support; token authentication and AppRole authentication
- Create `lib/secrets/adapters/aws_secrets.sh` — AWS Secrets Manager adapter; IAM-role-based authentication preferred over access keys
- Create `lib/secrets/adapters/env.sh` — environment variable fallback adapter for development and air-gapped deployments
- Modify `lib/config.sh` — resolve secret references at invocation time (syntax `{{secret:path/to/key}}` in config values)
- Modify `lib/causality.sh` — emit `secret.accessed` events with identity attribution and the secret path (never the value)
- Modify `lib/config_defaults.sh` — add `SECRETS_BACKEND`, `SECRETS_BACKEND_URL`, `SECRETS_CACHE_TTL`, `SECRETS_AUTH_METHOD`
- Create `tools/secrets/` Python helpers for Vault and AWS Secrets Manager API clients
- Create `tests/test_secrets.sh` — adapter interface tests, secret resolution tests, event emission tests
- Create `tools/tests/test_secrets_vault.py` — Vault adapter tests with dev-mode Vault fixture
- Create `tools/tests/test_secrets_aws.py` — AWS Secrets Manager adapter tests with moto fixture

Acceptance criteria:
- `_secret_get("path/to/key")` resolves the secret via the configured backend with short-lived caching (`SECRETS_CACHE_TTL` default 300 seconds)
- Vault adapter supports token authentication (for local dev) and AppRole authentication (for production); token and role_id/secret_id are pulled from environment variables or the OS keychain, not plaintext config
- AWS Secrets Manager adapter uses the AWS SDK's credential chain (environment, shared config, IAM instance role) and does not accept plaintext keys
- Environment variable fallback: `SECRETS_BACKEND=env` resolves `_secret_get("path/to/key")` by looking up `TEKHTON_SECRET_PATH_TO_KEY` (slashes converted to underscores, uppercased)
- Config references: any config value matching the `{{secret:path/to/key}}` pattern is replaced with the resolved secret at invocation time, never written to disk in resolved form
- Cache invalidation: secrets cached for `SECRETS_CACHE_TTL` seconds; the cache is process-local and cleared on process exit
- Every `secret.accessed` event includes the resolving identity (from M30 when available, otherwise anonymous), the secret path, the backend used, and the resolution outcome (success/denied/error); secret values are never logged
- All existing tests pass
- `shellcheck lib/secrets/*.sh` passes
- `python -m mypy tools/secrets/` passes

Watch For:
- Secret values must never appear in event logs, deliverable packages, or commit metadata; the secret path and backend are logged, the value never is
- Vault token expiration requires renewal; the adapter must handle 401/403 responses by re-authenticating via the configured method, not by prompting for new credentials
- AWS Secrets Manager has per-secret cost; the cache TTL default of 300 seconds balances cost against freshness
- The environment variable fallback is for development and air-gapped deployments only; production deployments should use Vault or AWS Secrets Manager; document this explicitly in the config example

Seeds Forward:
- V5 adds Azure Key Vault, Google Secret Manager, CyberArk, and additional enterprise vault adapters against the same interface
- V5 adds automated secret rotation integration with lifecycle tracking in the audit trail
- V5 adds scope-aware secret policies: which scopes can read which secret paths, enforced at resolution time

---

#### Milestone 28: Network Egress Policy

**Parallel group:** deployability | **Depends on:** M04

Files to create/modify:
- Create `lib/network_policy.sh` — declarative allowlist/denylist enforcement; policy decision function called before every outbound network call
- Modify `lib/agent.sh` — invoke network policy check before bridge calls
- Modify all `lib/integrations/*.sh` — invoke network policy check before integration endpoint calls
- Modify `lib/context/adapters/*.sh` (inserted in M32) — invoke network policy check before Context Graph ingestion calls
- Modify `lib/config_defaults.sh` — add `NETWORK_EGRESS_POLICY`, `NETWORK_EGRESS_ALLOWLIST`, `NETWORK_EGRESS_DENYLIST`, `NETWORK_EGRESS_CRITICALITY`, `NETWORK_EGRESS_TLS_MIN_VERSION`
- Modify `lib/causality.sh` — emit `network.policy.check` events with source, destination, and policy decision
- Create `.tekhton/network_policy.conf.example` — example policy configuration
- Create `tests/test_network_policy.sh` — allowlist enforcement, denylist enforcement, TLS minimum version enforcement, event emission

Acceptance criteria:
- `NETWORK_EGRESS_ALLOWLIST` and `NETWORK_EGRESS_DENYLIST` declare permitted and blocked destinations; patterns support exact host match and wildcard subdomain match (`*.anthropic.com`)
- Denylist takes precedence over allowlist; if a destination matches both, it is denied
- TLS 1.2+ enforcement: all outbound HTTPS calls reject TLS versions below `NETWORK_EGRESS_TLS_MIN_VERSION` (default 1.2); the check is applied at the socket layer, not relying on server capability
- Every network call logs a `network.policy.check` event with source component (bridge, integration adapter, Context Graph adapter), destination hostname, method (GET/POST/etc.), policy decision (allow/deny/warn), and timing
- Blocked calls raise a `NetworkEgressBlocked` error with the policy decision in the message; calling code handles this gracefully rather than crashing the pipeline
- MoSCoW criticality on violations: `must` blocks and fails the milestone, `should` blocks and warns without failing, `could` allows with warning, `wont` allows without logging
- Per-scope policy: enterprise, org, and project scopes each contribute to the effective policy; more-specific scope can tighten but not loosen the allowlist (see deployability section)
- All existing tests pass
- `shellcheck lib/network_policy.sh` passes

Watch For:
- The allowlist check must be cheap; use a simple hash-set lookup for exact matches and a pre-compiled regex for wildcards, not a full regex engine per call
- TLS version enforcement at the socket layer requires careful client configuration across curl (used by shell adapters) and Python (used by bridge and Context Graph); ensure both paths honor the config
- The network policy log stream will be high-volume; ensure events are append-only and don't block the calling code on I/O
- Some enterprise deployments operate behind egress proxies that handle their own allowlist; the policy must support pass-through mode (`NETWORK_EGRESS_POLICY=proxy_delegated`) that logs but doesn't enforce, deferring to the enterprise proxy

Seeds Forward:
- V5 adds a full network policy engine with traffic shaping, quota management, and integration with service mesh or dedicated egress proxies (Squid, cloud-native equivalents)
- V5 adds per-scope egress quotas (e.g., project X is limited to $100/month of provider traffic)
- V5 integrates with zero-trust networking patterns for workload identity and mutual TLS

---

### DOGFOOD CHECKPOINT 5: Enterprise Deployability Active (After M28)

**Action:** Enable NFR checks for remaining milestone development.

**What's new:**
- NFR framework catches cost overruns and SLA violations during builds
- Pipeline monitors itself for anomalous behavior

**What to verify after upgrade:**
- `NFR_COST_ENABLED=true` and `NFR_SLA_ENABLED=true` in pipeline.conf
- Set reasonable thresholds (e.g., `NFR_COST_MAX_PER_MILESTONE=25.00`,
  `NFR_SLA_MILESTONE_TIMEOUT_S=7200`)
- Run a milestone — verify NFR events in structured log

**Dogfood validation:** With `NFR_COST_ENABLED=true` and `NFR_SLA_ENABLED=true`, run a milestone and verify NFR events emit with proper MoSCoW criticality in the structured log. Projects retain per-NFR `_ENABLED` toggles for selecting which categories apply to their domain; this is scope-appropriate per-project configuration rather than V3 compatibility.

**Risk:** Low — NFR categories default to `should` criticality rather than `must`, so non-critical violations warn prominently but don't block. Projects elevate specific categories to `must` when they want blocking enforcement.

---

#### Milestone 29: Auth Abstraction & Local/Env Modes

**Parallel group:** auth | **Depends on:** M02

Files to create/modify:
- Create `lib/auth.sh` — `_auth_init()`, `_auth_get_identity()`,
  `_auth_enrich_event()`, provider abstraction, local/env mode implementations
- Modify `lib/logging.sh` — call `_auth_enrich_event()` in `emit_event()`
  to include identity in structured events
- Modify `lib/config_defaults.sh` — add `AUTH_ENABLED`, `AUTH_PROVIDER`,
  `AUTH_USER_ID`, `AUTH_ENV_USER_VAR`, `AUTH_AUDIT_IDENTITY`
- Create `.tekhton/auth.conf.example` — example auth configuration
- Create `tests/test_auth.sh` — identity resolution, event enrichment

Acceptance criteria:
- `AUTH_PROVIDER=local`: identity from `AUTH_USER_ID` config or `$USER` env var
- `AUTH_PROVIDER=env`: identity from configurable env vars (`AUTH_ENV_USER_VAR`,
  `AUTH_ENV_ROLE_VAR`)
- `_auth_get_identity()` returns JSON: `{"id":"...","provider":"...","role":"..."}`
- When `AUTH_AUDIT_IDENTITY=true`, all structured events include `user` field
- When `AUTH_ENABLED=false` (local development or unauthenticated CI runs), no identity enrichment flows into events; enterprise deployments set `AUTH_ENABLED=true` per the deployability baseline
- Identity is recorded in RUN_SUMMARY.json
- Auth init validates configuration and reports missing/invalid settings clearly
- All existing tests pass
- `shellcheck lib/auth.sh` passes

Watch For:
- `$USER` may not be set in all environments (some containers, CI). Fall back
  to `$(whoami)` or `unknown`.
- Auth config should be in a separate file (`.tekhton/auth.conf`) not
  `pipeline.conf` — auth settings are sensitive and may have different
  access controls.

Seeds Forward:
- M23 adds OIDC token validation
- V5 adds full OAuth flow and RBAC enforcement
- All audit trail queries can filter by user identity

---

#### Milestone 30: OIDC Token Validation Stub + RBAC Scope Declaration Schema

**Parallel group:** auth | **Depends on:** M29

Files to create/modify:
- Modify `lib/auth.sh` — add OIDC provider mode, JWT validation, issuer
  discovery, token file reading, group-to-scope mapping
- Create `lib/rbac.sh` — scope declaration, scope check hooks, persona-to-scope mapping evaluation
- Modify `lib/config_defaults.sh` — add `AUTH_OIDC_ISSUER`,
  `AUTH_OIDC_CLIENT_ID`, `AUTH_OIDC_TOKEN_FILE`, `AUTH_OIDC_GROUP_CLAIM`, `RBAC_ENFORCEMENT_MODE` (default `advisory` in V4, `strict` in V5)
- Create `tools/bridge/auth_oidc.py` — OIDC discovery, JWT signature
  validation, claims extraction (Python for crypto), SAML 2.0 fallback parser
- Create `.tekhton/auth.conf.example` — example auth + scope mapping configuration with IdP group examples (`tekhton_compliance`, `tekhton_architects`, `tekhton_designers`, `tekhton_operators`, `tekhton_senior_engineers`, `tekhton_project_leads`, `tekhton_cybersec`, `tekhton_context_admins`, `tekhton_context_viewers`, `tekhton_context_contributors`)
- Modify `lib/causality.sh` — enrich events with the full scope set (not just identity) for the requesting user
- Modify mechanisms at each sensitive inbound/outbound surface — call `_scope_check()` helper with required scope; in advisory mode, log the decision; in strict mode (V5), enforce
- Create `tools/tests/test_auth_oidc.py` — JWT validation, claims parsing, SAML fallback
- Create `tests/test_auth_oidc.sh` — OIDC mode integration
- Create `tests/test_rbac.sh` — scope declaration and check hooks across all sensitive surfaces

Acceptance criteria:
- `AUTH_PROVIDER=oidc` reads JWT from `AUTH_OIDC_TOKEN_FILE`
- Token validation: checks signature against issuer's JWKS, validates expiry,
  validates audience (`AUTH_OIDC_CLIENT_ID`)
- Claims extracted: `sub` (user ID), `email`, `groups` or `roles` (configurable via `AUTH_OIDC_GROUP_CLAIM`)
- OIDC discovery fetches `.well-known/openid-configuration` from issuer URL
- SAML 2.0 fallback for older enterprise IdPs that haven't adopted OIDC: parse SAML assertion, extract user and group attributes
- Works with: Okta, PingID/PingOne, Microsoft Entra ID, Google Workspace, AWS IAM Identity Center
- Expired tokens produce clear error message with re-auth instructions
- Invalid tokens produce clear error (not a stack trace)
- Group-to-scope mapping: IdP groups declared in `.tekhton/auth.conf` map to Tekhton scopes (`compliance`, `cybersec`, `architect`, `senior_engineer`, `operator`, `project_lead`, `designer`, `context_viewer`, `context_contributor`, `context_admin`); mapping supports both direct group membership and claim-based derivation
- RBAC schema is complete: every sensitive inbound surface (NFR modification, pipeline control, milestone DAG modification, Goldprint authoring, design artifact intake) declares its required scope; every outbound surface declares its filter rules
- Advisory mode (V4 default): scope checks log the decision (allowed/denied) to the causal event log but do not block; the audit trail records who attempted what, even for denied requests
- V4 does NOT implement OAuth redirect flow or hard scope enforcement — user provides pre-obtained token; enforcement is V5
- `python3 -m pytest tools/tests/test_auth_oidc.py` passes
- All existing tests pass

Watch For:
- JWKS (JSON Web Key Set) must be cached — don't fetch on every validation.
  Cache with TTL (default: 1 hour).
- Token file must be read-protected (0600 permissions). Warn if permissions
  are too open.
- Different OIDC providers put roles in different claims (`groups`, `roles`,
  `custom:roles`). Make the role claim name configurable via `AUTH_OIDC_GROUP_CLAIM`.
- The scope declaration schema must be exhaustive — every write surface and every read filter gets a scope declaration before V5 can enforce. Missing declarations become silent security holes when enforcement lands.
- Advisory mode still emits events; downstream SIEM integration will see attempts to perform unauthorized actions. This is the auditable-in-practice baseline that tenet 5 describes.

Seeds Forward:
- V5 implements full OAuth redirect flow (consent, token exchange, refresh)
- V5 enforces RBAC based on scopes derived from OIDC claims
- V5 adds SCIM 2.0 provisioning for automated user lifecycle management

---

#### Milestone 31: Context Graph Core — Storage & Schema

**Parallel group:** context_graph | **Depends on:** M02, M17

Files to create/modify:
- Create `tools/context_graph/__init__.py`
- Create `tools/context_graph/api.py` — REST API server exposing `/api/v1/context/*` endpoints (ingest, query, stats)
- Create `tools/context_graph/schema.py` — node types (Project, Milestone, Team, Domain, Artifact), edge types (owned_by, belongs_to, addresses, depends_on, supersedes, superseded_by, conflicts_with, produces, consumes), temporal metadata fields
- Create `tools/context_graph/storage/__init__.py` — storage backend abstraction
- Create `tools/context_graph/storage/apache_age.py` — Apache AGE on PostgreSQL backend (primary); Cypher query translation; JSONB node/edge properties
- Create `tools/context_graph/storage/kuzu.py` — Kuzu embedded backend (secondary for development and single-node deployments)
- Create `tools/context_graph/queries.py` — canonical query implementations (overlap detection, historical precedent, dependency mapping, freshness)
- Create `lib/context/client.sh` — shell client library that calls the Context Graph REST API
- Modify `lib/config_defaults.sh` — add `CONTEXT_GRAPH_ENABLED`, `CONTEXT_GRAPH_BACKEND` (values: `apache_age`, `kuzu`), `CONTEXT_GRAPH_URL`, `CONTEXT_GRAPH_API_KEY`, `CONTEXT_OVERLAP_THRESHOLD`, `CONTEXT_DEFAULT_VISIBILITY` (values: `project`, `anonymized`, `full`)
- Create `tools/tests/test_context_graph_schema.py` — node and edge type validation, temporal metadata, schema migrations
- Create `tools/tests/test_context_graph_storage.py` — Apache AGE and Kuzu backend contract tests
- Create `tests/test_context_graph_client.sh` — shell client contract tests

Acceptance criteria:
- Schema defines five node types (Project, Milestone, Team, Domain, Artifact) with temporal metadata (`created_at`, `updated_at`, `status_changed_at`, `status`, `last_signal_at`)
- Schema defines nine edge types (`owned_by`, `belongs_to`, `addresses`, `depends_on`, `supersedes`, `superseded_by`, `conflicts_with`, `produces`, `consumes`)
- Apache AGE backend uses PostgreSQL's Apache AGE extension; graph data stored as AGE graph structures with JSONB property bags
- Kuzu backend uses the embedded database for single-node deployments; schema stored as Kuzu's native graph tables
- REST API endpoints: `POST /api/v1/context/nodes`, `POST /api/v1/context/edges`, `GET /api/v1/context/query?cypher=<...>`, `GET /api/v1/context/stats`
- Query API supports Cypher syntax for Apache AGE; Kuzu backend translates from a subset of Cypher to its native query language for the V4 query patterns (overlap detection, historical precedent, dependency mapping)
- Three-tier visibility model: project-scoped (default), anonymized cross-team, full visibility — enforced at the query API layer via scope check (advisory in V4 per M30 RBAC schema)
- Audit trail: every query logged with querying identity, target project, data returned tier (`context.query.executed` events)
- Documentation names the storage abstraction's role: the Context Graph uses its own PostgreSQL or Kuzu instance, not the storage abstraction from M17 (which is for content like Goldprints and project artifacts)
- All existing tests pass
- `python -m mypy tools/context_graph/` passes
- `shellcheck lib/context/client.sh` passes

Watch For:
- Apache AGE is a PostgreSQL extension; enterprise deployments may need to install and enable it explicitly; document the setup prerequisite
- Kuzu's embedded nature means it's a single-process database; not suitable for multi-process Tekhton deployments, which the config default (`apache_age`) steers away from
- Query translation for Kuzu covers the V4 query patterns; novel Cypher queries may not translate cleanly, so the client documents which backends support which query classes
- Temporal metadata must be consistent across nodes and edges; any node or edge created without the temporal fields fails schema validation

Seeds Forward:
- M32 populates the graph via ingestion adapters and the Goldprint bridge
- M33 integrates the graph's query API with Tekhton stages at the horizontal touchpoints
- V5 adds semantic similarity for overlap detection via pgvector alongside Apache AGE
- V5 extends the schema with additional node/edge types (Deployment, Incident, Release) for operational context
- V5 considers extracting the Context Graph as a standalone open-source service

---

#### Milestone 32: Context Graph Ingestion Adapters + Goldprint Bridge

**Parallel group:** context_graph | **Depends on:** M31, M18, M21, M22, M23

Files to create/modify:
- Create `lib/context/adapters/jira.sh` — Jira ingestion; pulls epics/stories/tasks, assignees, timelines, domain tags, status transitions; maps to Project and Milestone nodes
- Create `lib/context/adapters/github.sh` — GitHub ingestion; pulls repositories, CODEOWNERS, PR activity, commit history; maps to Team and Artifact nodes
- Create `lib/context/adapters/confluence.sh` — Confluence ingestion; pulls architectural decision records, RFCs, design documents; enriches Domain metadata and Project rationale
- Create `lib/context/adapters/tekhton_internal.sh` — Tekhton-internal adapter; ingests from the global knowledge base at `~/.tekhton/global_knowledge/` (failure patterns, cost benchmarks, provider profiles); maps to internal Artifact nodes
- Create `lib/context/adapters/goldprints.sh` — Goldprint-to-graph bridge; on Goldprint authoring events, create Artifact node; on consumption events, create `consumes` edge; on deprecation, mark node as deprecated with temporal update
- Create `lib/context/ingestion.sh` — ingestion scheduler; invokes adapters on configured schedule (hourly default for most, continuous for Tekhton-internal)
- Modify `lib/config_defaults.sh` — add `CONTEXT_INGESTION_SCHEDULE_JIRA`, `CONTEXT_INGESTION_SCHEDULE_GITHUB`, `CONTEXT_INGESTION_SCHEDULE_CONFLUENCE`, `CONTEXT_INGESTION_SCHEDULE_INTERNAL`, plus adapter-specific credentials (via secret manager references)
- Modify `lib/goldprints/loader.sh` — emit `goldprint.authored` events that the bridge adapter consumes
- Modify `lib/goldprints/resolver.sh` — query the Context Graph for domain-filtered Goldprint discovery and adoption metadata (not just storage abstraction)
- Create `tests/test_context_adapters.sh` — ingestion contract tests; mock API fixtures
- Create `tools/tests/test_goldprint_bridge.py` — end-to-end Goldprint authoring and consumption flow through the bridge

Acceptance criteria:
- Jira adapter: given valid API credentials and project keys, pulls all tickets from the configured projects and creates/updates Project and Milestone nodes with domain tags from Jira labels
- GitHub adapter: given valid credentials and org/repo list, pulls CODEOWNERS, PR metadata, commit history; creates/updates Team and Artifact nodes with `owned_by` and `produces` edges
- Confluence adapter: given valid credentials and space keys, pulls architectural decision records; enriches existing Domain nodes with rationale metadata
- Tekhton-internal adapter: on every V4 milestone completion, ingests from `~/.tekhton/global_knowledge/`; creates internal Artifact nodes representing past Tekhton-built artifacts across projects
- Goldprint bridge: every `goldprint.authored` event triggers creation of an Artifact node with the Goldprint's id, domain tags, authoring team, lifecycle status; every `goldprint.consumed` event triggers a `consumes` edge from Project to Artifact
- Goldprint resolution queries the Context Graph (not just local storage) for domain filtering and adoption count; adoption count is visible in resolver responses and Watchtower Goldprint UI
- Ingestion cadence: Jira hourly, GitHub hourly, Confluence every 6 hours, Tekhton-internal on milestone completion (event-driven); all configurable
- All adapter credentials resolved through the M27 secret manager — no plaintext API tokens in config
- Every adapter call flows through the M28 network egress policy check
- All existing tests pass
- `shellcheck lib/context/adapters/*.sh` passes

Watch For:
- API rate limits vary by platform; adapters must implement exponential backoff with respect for `Retry-After` headers
- Ingestion deduplication: re-ingesting the same source data (e.g., re-running Jira hourly) must update existing nodes, not create duplicates; use source-derived stable ids (`jira:<issue-key>`, `github:<org>/<repo>/pull/<number>`)
- Goldprint bridge event handling is eventually consistent; a Goldprint consumption event may fire before the Goldprint's Artifact node exists (authoring event lost or delayed); adapter handles this by creating a placeholder node and updating on authoring event arrival
- Confluence and Jira schemas vary across Cloud and Data Center deployments; adapters must detect the variant and adjust

Seeds Forward:
- M33 integrates the populated graph with Tekhton stages at the horizontal touchpoints
- V5 adds DataDog, Splunk, Slack, Microsoft Teams, Linear, Azure DevOps, GitLab, Bitbucket, Notion, SharePoint, Google Docs adapters
- V5 adds advanced Goldprint analytics (semantic similarity, predictive adoption, failure/success correlation) on top of the V4 structural integration

---

#### Milestone 33: Context Graph Horizontal Integration + Organizational Context Tab

**Parallel group:** context_graph | **Depends on:** M32, M14, M15, M25

Files to create/modify:
- Modify `stages/intake.sh` — add `_consult_context()` call at task-entry timing point; query for overlap detection; surface warnings if overlap threshold exceeded
- Modify `stages/architect.sh` — add `_consult_context()` call for historical precedent; query Goldprint adoption in this domain, past architectural decisions from Confluence
- Modify `lib/cost_forecast.sh` — add `_consult_context()` call for organizational cost baselines across similar projects
- Modify `lib/finalize.sh` — add `_consult_context()` call for related efforts citation in deliverable packages
- Create `lib/context/consult.sh` — `_consult_context(role, domain, query_type, params)` helper; wraps Context Graph API calls with error handling and result formatting
- Modify `templates/watchtower/` — add Organizational Context tab with two V4 views: Overlap Detection (active and recent projects in the same domain) and Historical Precedent (prior decisions and outcomes)
- Modify `tools/watchtower_server.py` — add `GET /api/v1/context/overlap?task_description=...&domain=...` and `GET /api/v1/context/precedent?domain=...&decision_type=...` endpoints as thin proxies to the Context Graph API
- Modify `lib/config_defaults.sh` — add `CONTEXT_INTAKE_OVERLAP_ENABLED`, `CONTEXT_ARCHITECT_PRECEDENT_ENABLED`, `CONTEXT_SCOUT_ORG_BASELINE_ENABLED`, `CONTEXT_FINALIZE_RELATED_EFFORTS_ENABLED`
- Create `tests/test_context_consult.sh` — stage integration tests; mock Context Graph responses; verify stage behavior with empty graph, populated graph, and error conditions
- Create `templates/watchtower/views/organizational_context.html` — the tab content
- Create `templates/watchtower/static/js/organizational_context.js` — client-side rendering and live updates

Acceptance criteria:
- Intake stage: when a new NL task is submitted, `_consult_context()` queries the graph for active or recently completed projects in the same domain; if similarity score exceeds `CONTEXT_OVERLAP_THRESHOLD`, a warning is surfaced in Watchtower and an `nfr.overlap_warning` event is emitted
- Architect stage: queries the graph for past architectural decisions in the target domain; surfaces supersession chains and decision rationale to the architect agent's context
- Cost forecasting: in addition to per-project history, queries organizational cost baselines across similar projects; blended forecast weights by similarity confidence
- Finalize stage: queries the graph for related efforts across the organization; includes "See also" section in the deliverable package and release notes
- Watchtower Organizational Context tab: Overlap Detection view lists active projects per domain with status indicators; Historical Precedent view shows decision timelines with outcomes
- Query performance: each `_consult_context()` call completes within 2 seconds against a graph with 10k nodes; if it exceeds this threshold, the stage proceeds without the context but emits a `context.consult.timeout` event
- Graceful degradation: if the Context Graph is unavailable (service down, credentials invalid), stages continue without context consultation and emit `context.consult.unavailable` events
- All four horizontal touchpoints are configurable via per-touchpoint `_ENABLED` flags; deployments can enable only the touchpoints that match their integration state
- Scope filtering: three-tier visibility enforced at query time; anonymized queries return project count per domain without exposing specific milestone details; full queries require `context_admin` scope (advisory in V4)
- All existing tests pass
- `shellcheck lib/context/consult.sh` passes

Watch For:
- The intake stage runs frequently; overlap detection queries must be cheap and cached where possible (task description hash → cached result with TTL)
- Organizational context can surface politically sensitive information (another team is building something similar); the anonymized tier should be the default for cross-team queries unless the project has explicitly opted into full visibility
- Stage timeouts on context queries must not create a dependency on Context Graph availability; stages degrade gracefully but emit visibility events so operators can diagnose repeated degradation
- The Watchtower tab relies on live updates from the Context Graph; WebSocket connection management should follow the pattern established in M12 for consistent UX

Seeds Forward:
- V5 adds remaining horizontal touchpoints (coder, reviewer, tester, NFR Framework integration for cross-team policy coherence)
- V5 adds advanced graph queries (semantic similarity, predictive conflict detection, automated domain tagging) accessible through the same `_consult_context()` interface
- V5 adds cross-organization federation for enterprises with subsidiary structures
- V5 adds the Watchtower administrative UI for Context Graph visibility policy configuration

---

### Phase 4: Intelligence (M34-M38)

#### Milestone 34: Knowledge Base & Failure Pattern Recognition

**Parallel group:** learning | **Depends on:** M02, M07

Files to create/modify:
- Create `lib/learning.sh` — `_learning_init()`, `_record_run()`,
  `_calibrate_scout_estimate()`, `_classify_failure()`,
  `_record_new_failure()`, knowledge base file management
- Create `.tekhton/knowledge/` directory structure (run_history.jsonl,
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
- `LEARNING_ENABLED=false` is an explicit operator override for deployments that don't want learning (e.g., air-gapped environments); the V4 default is `true` since cross-run intelligence is part of the enterprise-grade baseline
- Cost data from bridge cost ledger (M07) included in run history
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
- M35 adds prompt effectiveness tracking and cross-project sharing
- V5's prompt auto-tuning consumes the calibration data
- Watchtower Trends tab can display learning metrics (calibration accuracy)

---

#### Milestone 35: Prompt Tracking & Cross-Project Knowledge

**Parallel group:** learning | **Depends on:** M34

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

#### Milestone 36: Language Profiles & Domain Detection

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
  `.tekhton/language_profiles/` take precedence over shipped profiles).

Seeds Forward:
- M37 integrates language profiles into all pipeline stages
- V5 adds semantic similarity for profile matching (not just keyword indicators)
- Community contributions: new language profiles are a single JSON file

---

#### Milestone 37: Language-Aware Pipeline Stages

**Parallel group:** language | **Depends on:** M36

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
  need different phrasing for different providers (via bridge profiles from M07).

Seeds Forward:
- V5 uses language profiles for automated code review scoring
- V5 adds language-specific refactoring patterns
- Community can contribute domain-specific review checklists

---

#### Milestone 38: Champion Tooling (ROI Analytics, Compliance Summary, Executive Reports, Pilot Scaffolding)

**Parallel group:** champion | **Depends on:** M14, M19, M33

Files to create/modify:
- Modify `templates/watchtower/` — add ROI and Adoption Analytics view (dedicated top-level tab or section); Compliance Summary generation UI; Executive Reports dashboard with export
- Modify `tools/watchtower_server.py` — add `GET /api/v1/champion/roi`, `GET /api/v1/champion/compliance_summary`, `POST /api/v1/champion/executive_report`, `GET /api/v1/champion/case_studies` endpoints
- Create `lib/champion/roi.sh` — ROI and adoption analytics derivation from Context Graph cross-project data and cost ledger; per-project, per-team, per-domain aggregations
- Create `lib/champion/compliance.sh` — compliance summary generation from the causal event log (identity attribution, scope decisions, network policy logs, code provenance metadata, NFR violation history, Goldprint adoption); produces structured evidence suitable for IT security review
- Create `lib/champion/executive_report.sh` — condensed weekly/monthly aggregates from Watchtower data; exports as HTML, PDF, and Markdown for executive briefings
- Create `lib/champion/case_study.sh` — structured pilot outcome records from deliverable artifact packages and Context Graph historical data; formats for non-engineering audiences
- Create `lib/champion/pilot_scaffolding.sh` — project template initialization for common pilot scenarios (new microservice, design-to-production flow, NFR-enforced compliance work, regulated-industry prototype); templates include pre-configured success criteria, NFR thresholds, and integration hooks
- Create `templates/pilot_scaffolds/` — pilot project template directory with scenario-specific skeletons
- Modify `lib/release.sh` — integrate with `lib/champion/executive_report.sh` for automatic monthly roll-up generation when operator-configured
- Modify `lib/config_defaults.sh` — add `CHAMPION_ROI_ENABLED`, `CHAMPION_COMPLIANCE_SUMMARY_ENABLED`, `CHAMPION_EXECUTIVE_REPORT_SCHEDULE`, `CHAMPION_CASE_STUDY_ENABLED`, `CHAMPION_PILOT_TEMPLATES_DIR`
- Create `tests/test_champion_roi.sh`, `tests/test_champion_compliance.sh`, `tests/test_champion_reports.sh`, `tests/test_champion_pilot.sh`

Acceptance criteria:
- ROI view in Watchtower displays: Tekhton usage across projects (count, frequency, growth); cost per milestone and per project; duration per milestone; business-metric outcomes trended over time; adoption over time per team
- Compliance Summary generation: operator clicks "Generate Summary" in the Watchtower UI and receives a structured document with identity attribution, scope audit, network policy audit, code provenance chain, NFR violation history, Goldprint adoption evidence, and time-range filter; the summary format is reviewer-ready (suitable for IT security review handoff)
- Executive Reports: condensed weekly and monthly aggregates showing milestone completion counts, cost trajectory, quality metrics (test coverage trend, NFR violation trend), and business outcomes (features shipped, time-to-ship); exportable in HTML, PDF (via a headless browser render), and Markdown
- Case Study Generation: given a completed pilot project, produces a structured case study with problem statement, approach, Tekhton milestones used, Goldprints consumed, outcomes achieved, cost incurred, timeline, and lessons learned; format suitable for internal evangelism
- Pilot Scaffolding: `tekhton pilot init --scenario=microservice-pii --project=my-pilot` creates a project skeleton pre-configured with scenario-appropriate NFR thresholds, applicable Goldprints (linked from enterprise tier), and acceptance criteria templates; scenarios cover microservice-pii, design-to-production, compliance-work, research-spike
- Cross-project adoption graph visualization: Watchtower view sourced from Context Graph cross-project data; displays which projects consume which Goldprints, which teams adopt Tekhton for which domains, and adoption velocity trends
- All Champion-facing features gracefully degrade when upstream substrate is unavailable (Context Graph down → ROI view shows per-project data with a "partial data" notice; cost ledger empty → "no data yet")
- Persona attribution: Champion-facing surfaces declare their required scope (`operator` or equivalent elevated scope) per the M30 RBAC schema
- All existing tests pass
- `shellcheck lib/champion/*.sh` passes

Watch For:
- Executive report generation can be expensive if run on every milestone completion; schedule-based generation (weekly/monthly) with on-demand trigger is the right model, not auto-fire
- Compliance summary generation reads the causal event log across potentially long time windows; use indexed queries on the event log (by timestamp range, by event type) to keep generation time bounded
- Pilot scaffolding templates reference enterprise-tier Goldprints by id; if the referenced Goldprints don't exist in the target deployment, the pilot init should fail cleanly with a message pointing to which Goldprints are missing
- Case study generation is narrative-heavy; V4 uses deterministic template-based rendering, not an agent call, to keep generation cheap; V5 can add an optional agent polish pass

Seeds Forward:
- V5 adds Watchtower administrative UI for pilot template authoring and curation
- V5 adds automated Champion dashboards for executive audiences with per-executive customization
- V5 adds compliance summary export directly to enterprise GRC platforms (Archer, ServiceNow GRC, OneTrust)
- V5 adds ROI attribution models that quantify business-metric outcomes against Tekhton usage

---

### Manifest Summary

```
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group

# Phase 1: Foundations
m01|Test Harness & Isolation Framework|pending||m01-test-harness.md|foundation
m02|Three-Tier Logging & Structured Events|pending||m02-structured-logging.md|foundation
# --- DOGFOOD CHECKPOINT 1 ---
m03|V3 to V4 Migration Tool|pending|m01,m02|m03-migration-tool.md|foundation
m04|Bridge Core Architecture & Shell Routing|pending|m02|m04-bridge-core.md|bridge
m05|Anthropic Direct API Adapter|pending|m04|m05-anthropic-adapter.md|bridge
m06|OpenAI & Ollama Adapters|pending|m04|m06-openai-ollama-adapters.md|bridge
m07|Provider Failover Calibration & Cost Ledger|pending|m05,m06|m07-failover-cost.md|bridge
m08|MCP Gateway for Non-Anthropic Providers|pending|m06|m08-mcp-gateway.md|bridge
# --- DOGFOOD CHECKPOINT 2 ---

# Phase 2: Core Capabilities
m09|Parallel Coordinator & Worktree Lifecycle|pending|m02|m09-parallel-coordinator.md|parallel
m10|Parallel Conflict Detection & Merge|pending|m09|m10-parallel-merge.md|parallel
m11|Parallel Resource Budgeting & Shared Gate|pending|m07,m10|m11-parallel-budget.md|parallel
# --- DOGFOOD CHECKPOINT 3 ---
m12|Watchtower Server Mode & WebSocket|pending|m02|m12-watchtower-server.md|watchtower
m13|Watchtower Interactive Controls|pending|m12|m13-watchtower-interactive.md|watchtower
m14|Watchtower Cost Dashboard & Parallel View|pending|m07,m11,m13|m14-watchtower-cost-parallel.md|watchtower
m15|Natural Language Task Decomposition|pending|m04|m15-nl-decomposition.md|owner
m16|Design Artifact Intake|pending|m08,m13,m15|m16-design-intake.md|owner
m17|Storage Abstraction Layer|pending|m02|m17-storage-abstraction.md|owner
m18|Goldprints Subsystem + Watchtower UI|pending|m17,m15|m18-goldprints.md|owner
m19|Release Notes & Changelog Automation + Code Provenance|pending|m02|m19-release-notes-provenance.md|owner
m20|Cost Forecasting & Deliverable Packages + SBOM Generation|pending|m07,m19|m20-cost-forecast-sbom.md|owner
# --- DOGFOOD CHECKPOINT 4 ---

# Phase 3: Enterprise & Integration
m21|GitHub Integration|pending|m02,m19|m21-github-integration.md|integration
m22|Slack Teams & Webhook Notifications|pending|m02|m22-slack-webhook.md|integration
m23|Log Shipping & CI/CD Mode|pending|m02|m23-log-shipping-ci.md|integration
m24|NFR Engine & Cost SLA Checks|pending|m02,m07|m24-nfr-engine.md|nfr
m25|NFR Performance A11y Coverage & License|pending|m24|m25-nfr-checks.md|nfr
m26|NFR Model Governance Category|pending|m04,m24|m26-nfr-model.md|nfr
m27|Secret Manager Abstraction|pending|m02|m27-secret-manager.md|deployability
m28|Network Egress Policy|pending|m04|m28-network-egress.md|deployability
# --- DOGFOOD CHECKPOINT 5 ---
m29|Auth Abstraction & Local Env Modes|pending|m02|m29-auth-local.md|auth
m30|OIDC Token Validation Stub + RBAC Scope Declaration Schema|pending|m29|m30-auth-oidc-rbac.md|auth
m31|Context Graph Core - Storage & Schema|pending|m02,m17|m31-context-graph-core.md|context_graph
m32|Context Graph Ingestion Adapters + Goldprint Bridge|pending|m31,m18,m21,m22,m23|m32-context-graph-ingestion.md|context_graph
m33|Context Graph Horizontal Integration + Org Context Tab|pending|m32,m14,m15,m25|m33-context-graph-horizontal.md|context_graph

# Phase 4: Intelligence
m34|Knowledge Base & Failure Pattern Recognition|pending|m02,m07|m34-knowledge-base.md|learning
m35|Prompt Tracking & Cross-Project Knowledge|pending|m34|m35-prompt-tracking.md|learning
m36|Language Profiles & Domain Detection|pending|m02|m36-language-profiles.md|language
m37|Language-Aware Pipeline Stages|pending|m36|m37-language-stages.md|language
m38|Champion Tooling (ROI, Compliance, Reports, Pilots)|pending|m14,m19,m33|m38-champion-tooling.md|champion
```

### Parallel Execution Opportunities

When V4's own parallel engine is active (after M11), these milestones can
run concurrently within their parallel groups:

| Wave | Milestones (concurrent) | Prerequisite |
|------|------------------------|-------------|
| 1 | M01 + M02 | None |
| 2 | M03 + M04 + M09 + M12 + M17 + M19 + M22 + M23 + M27 + M29 + M36 | M01, M02 |
| 3 | M05 + M06 + M10 + M13 + M15 + M28 | M04, M09, M12 |
| 4 | M07 + M08 + M14 + M20 + M21 + M30 + M34 + M37 | M05, M06, M19, M29, M36 |
| 5 | M11 + M16 + M18 + M24 + M31 + M35 | M07, M10, M13, M15, M17 |
| 6 | M25 + M26 + M32 + M38 | M24, M18, M31, M14 |
| 7 | M33 | M32, M25 |

In practice, API quota and team count limits will constrain concurrency.
The DAG permits up to 11 milestones in a single wave (Wave 2), but deployment
throughput is realistically bounded by the parallel team count configured in
`PARALLEL_MAX_TEAMS` and the rate limits of the configured providers.
