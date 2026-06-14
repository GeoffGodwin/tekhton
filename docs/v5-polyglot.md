# Polyglot Provider Guide

This guide covers configuring Tekhton's multi-provider dispatch — choosing
between Claude, Codex, and future providers on a per-stage basis, setting up
auth, troubleshooting tier confusion, and migrating from the pre-m15 implicit
Claude default.

Related: [v5-provider-seam.md](v5-provider-seam.md) — the Go interface and
type system behind provider dispatch. See also
[cutover-runbook.md](cutover-runbook.md) for the June 15 promotion gate
and rollback procedure used when moving off `claude --print`.

---

## Overview

Tekhton V5 introduced a cost-ranked provider chain. Rather than hard-wiring
the Claude CLI, the pipeline reads a `PROVIDER` spec from `pipeline.conf` (or
CLI flags) and dispatches each stage to the cheapest available provider first,
falling back to the next on upstream errors. The default spec is `codex,claude`
— Codex subscription (free within quota) is tried first; the Claude API is the
fallback.

---

## pipeline.conf Syntax

```bash
# Global provider spec: single name or comma-separated chain.
# Cheapest-first ordering is recommended.
PROVIDER=codex,claude

# Per-stage overrides (uncomment to enable):
# PROVIDER_intake=
# PROVIDER_coder=
# PROVIDER_security=
# PROVIDER_review=
# PROVIDER_tester=
# PROVIDER_architect=
# PROVIDER_docs=
# PROVIDER_cleanup=
```

**Single name** — routes all stages to that provider:

```bash
PROVIDER=claude
```

**Comma-separated chain** — tries each in order, falling through to the next
on `OutcomeUpstreamError` (quota exceeded, network failure, 5xx):

```bash
PROVIDER=codex,claude
```

Stage names are lowercased. The env key is `PROVIDER_<STAGE>` where `<STAGE>`
is the uppercase stage name, e.g. `PROVIDER_CODER`.

---

## Per-Stage Overrides and Fallback Chains

Per-stage overrides let you pin expensive stages to a specific provider while
leaving cheaper stages on the cost-ranked default:

```bash
# Use the cost-ranked default for most stages.
PROVIDER=codex,claude

# Pin the coder stage to Claude for reliability-sensitive work.
PROVIDER_coder=claude

# Use Codex alone for the lightweight intake stage.
PROVIDER_intake=codex
```

Fallback chains work at the per-stage level too:

```bash
PROVIDER_coder=codex,claude   # coder tries Codex first, falls back to Claude
PROVIDER_intake=codex         # intake is Codex-only (no fallback)
```

---

## Setting Up Codex Auth

Three auth paths are supported, in resolution order:

**1. OAuth (subscription tier — free within quota):**

```bash
codex login
# Stores credentials at ~/.codex/auth.json
```

This is the recommended path. No API key required. Usage is metered against
your OpenAI subscription quota.

**2. API key (api tier — paid per-token):**

```bash
export CODEX_API_KEY=sk-...
```

Set in your shell profile or in `pipeline.conf` (keep it out of version control).

**3. Per-run override via ProviderSpecific:**

Pass `codex.api_key` in the provider request's `ProviderSpecific` map. Used
for automated pipelines where the key comes from a secrets manager.

---

## Setting Up Claude Post-June-15

As of June 15 2026, `claude --print` runs against the Anthropic API (metered,
api tier). Subscription-tier Claude access via the CLI requires an active
Claude Pro/Max subscription and the Claude desktop app; the headless CLI path
is API-only.

For API-tier Claude, set your API key:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

**Escape hatch — pre-June-15 behavior:**

If you have a legacy subscription arrangement, set:

```bash
TEKHTON_CLAUDE_PRE_JUNE_15=true
```

This forces the Claude provider to report `subscription` tier instead of `api`.
It does NOT change the actual billing path — it only affects how Tekhton orders
the chain and enforces `--require-tier` limits.

See [v5-tier-model.md](v5-tier-model.md) for the full tier model.

---

## Local Provider (qwen-local)

`qwen-local` routes to a local OpenAI-compatible server (Ollama by default)
at zero API cost. The provider delegates to the same codex machinery as the
`codex` provider, pointed at a local endpoint.

**Setup — Ollama + Qwen2.5-Coder-32B:**

```bash
# 1. Install Ollama, pull a coding-capable model (32B is the floor for
#    reliable agentic tool-calling; Q4_K_M fits a 24GB GPU).
ollama pull qwen2.5-coder:32b
# 2. Ollama serves an OpenAI-compatible endpoint at :11434/v1 automatically.
# 3. Point Tekhton at it (defaults already match Ollama):
#    QWEN_LOCAL_BASE_URL=http://localhost:11434/v1
#    QWEN_LOCAL_MODEL=qwen2.5-coder:32b
#    wire_api=chat   # always use the Chat Completions path, not Responses API
# 4. Run local-first with paid fallback:
PROVIDER=qwen-local,codex,claude tekhton run --milestone mNN
# 5. Or fully offline / zero-billing:
PROVIDER=qwen-local tekhton run --milestone mNN
```

In `pipeline.conf`, always set `wire_api=chat` alongside the local provider:

```bash
PROVIDER=qwen-local,codex,claude
QWEN_LOCAL_BASE_URL=http://localhost:11434/v1
QWEN_LOCAL_MODEL=qwen2.5-coder:32b
QWEN_LOCAL_WIRE_API=chat
```

`qwen-local` has cost rank 0 — it sorts before `subscription` and `api`
providers in a chain. Use `--require-tier local` to guarantee no paid
provider can run:

```bash
tekhton run --milestone mNN --require-tier local
```

### Calibrating qwen-local (m22 capability profile)

Every turn budget, context window, and prompt in the pipeline was calibrated
against Claude. A 32B-class local model at Q4 has a smaller usable context,
weaker long-horizon planning, and less reliable structured output, so Tekhton
applies a per-provider **capability profile** to requests routed to
`qwen-local` (turn scaling, prompt clamp, format reinforcement, and a
pre-render context-budget shrink). The built-in defaults are **hypotheses, not
measurements** — record what actually works on your hardware in the override
file.

**Hardware reference point (the values were chosen for):** RTX 4090 (24 GB),
Qwen2.5-Coder-32B `Q4_K_M`, ~30k tokens usable context at acceptable
throughput.

**The knobs (built-in qwen-local defaults):**

| Knob | Default | Effect |
|------|---------|--------|
| `MAX_TURNS_FACTOR` | `1.5` | Scales a stage's MaxTurns (local models need more iterations per task). |
| `CONTEXT_BUDGET_PCT` | `25` | Exported as `TEKHTON_PROVIDER_CONTEXT_PCT`; shrinks prompt assembly *before* render (vs. truncating after). |
| `MAX_PROMPT_CHARS` | `24000 × CHARS_PER_TOKEN` | Hard request-level clamp; a clamp is logged with original→clamped sizes. |
| `FORMAT_REINFORCEMENT` | "respond only with valid tool calls / JSON" block | Prepended to the request prompt; empty for models that don't need it. |

**Writing an override file** — `.claude/provider_profiles/qwen-local.conf`
(gitignored project state; flat `KEY=value`, unknown keys warn-and-skip):

```bash
MAX_TURNS_FACTOR=2.0
CONTEXT_BUDGET_PCT=20
MAX_PROMPT_CHARS=80000
FORMAT_REINFORCEMENT=Respond with a single tool call. No prose.
```

**Symptom → knob:**

| Symptom | Adjust |
|---------|--------|
| Malformed tool calls / JSON wrapped in prose | strengthen `FORMAT_REINFORCEMENT` |
| Mid-task amnesia, forgets earlier steps | lower `CONTEXT_BUDGET_PCT` |
| Chronic MaxTurns exhaustion before completing | raise `MAX_TURNS_FACTOR` |
| Prompt-clamp log lines on large stages | raise `MAX_PROMPT_CHARS` only if the model still coheres |

**Scope note:** the profile applies per *attempted* provider. In a
`codex,qwen-local` chain the context budget is exported from the *first*
provider (codex → no shrink), so a fallthrough to qwen-local runs against a
codex-sized prompt that only the request-level `MAX_PROMPT_CHARS` clamp
protects. Accepted in m22 — Tekhton does not re-render mid-chain.

---

## Troubleshooting

**Auth failure signals:**

- Codex: `codex provider: binary not found on PATH` — install the Codex CLI.
- Codex: `upstream error` with `401` — run `codex login` or set `CODEX_API_KEY`.
- Claude: `upstream error` with `401` — set `ANTHROPIC_API_KEY`.

**`qwen-local` run reports success but no files changed:**

The model is producing text but not emitting tool calls. Check in order:

1. Verify `wire_api=chat` (i.e. `QWEN_LOCAL_WIRE_API=chat`). The Responses API
   path (`wire_api=responses`) is the known local breakage source — local
   models rarely support it correctly.
2. Use a model of at least 32B parameters at at least 4-bit quantization
   (`Q4_K_M` or better). Smaller models and aggressive quantization
   (Q2/Q3) frequently fail to emit structured tool calls reliably.
3. Confirm the smoke test passes end-to-end: `bash tests/test_qwen_local_smoke.sh`.
   The smoke test drives a file-edit + shell-command fixture and asserts both
   side effects completed. Until the smoke test passes, do not use `qwen-local`
   in a real run.

**Tier confusion:**

RUN_SUMMARY reports `tier_used` per stage. If a stage shows a more expensive
tier than expected, check whether the cheaper provider's auth is configured:

```bash
grep tier_used .tekhton/RUN_SUMMARY.json
```

**`--require-tier` not behaving as expected:**

`--require-tier subscription` causes the chain to reject any provider whose
tier exceeds `subscription` (i.e., api and local providers are blocked). If
Claude is your only configured provider and it reports `api` tier, the run
will fail with `TIER_LIMIT_EXCEEDED`. Either:

- Fix auth so Codex is available at subscription tier, or
- Set `PROVIDER=claude` and drop the `--require-tier` constraint.

**Multiple providers, wrong one runs:**

`ResolveProvider` respects PROVIDER_<STAGE>= before PROVIDER. Verify no
stale per-stage override is set by running:

```bash
env | grep -i provider
```

---

## Cost Considerations

Use the subscription tier where possible — Codex via `codex login` is free
within quota. The default chain `codex,claude` reflects this: Codex runs
unless it's unavailable, then Claude's API is the fallback.

For cost-critical pipelines, set `PROVIDER=codex` to prevent any API fallback.
The run will fail with `OutcomeUpstreamError` if Codex is unreachable rather
than silently billing the Claude API.

For reliability-critical pipelines (where a failed Codex run is worse than
the Claude API cost), set `PROVIDER=claude` to pin to the API provider.

---

## Migration Path

**Important:** Upgrading to m15 changes the implicit default.

**Before m15:** The runner unconditionally used the Claude API. No `PROVIDER`
key was needed.

**After m15:** When `PROVIDER` is unset in `pipeline.conf`, the runner defaults
to `codex,claude` — Codex is tried first. If Codex is not installed or not
authenticated, the run fails rather than silently falling through to Claude.

**To restore Claude-only behavior**, add this line to your `pipeline.conf`:

```bash
PROVIDER=claude
```

**Migrating a single stage to Codex** while keeping the rest on Claude:

```bash
PROVIDER=claude           # all stages use Claude by default
PROVIDER_coder=codex,claude  # coder tries Codex first, falls back to Claude
```

This lets you test Codex on the most compute-intensive stage without changing
the pipeline's overall behavior.
