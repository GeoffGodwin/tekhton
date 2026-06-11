# Provider Tier Model

This document describes Tekhton's four-tier provider model, the June 15 2026
billing change, and how `--require-tier` and the escape hatch work.

---

## The Four Tier Values

| Tier | Constant | Meaning |
|------|----------|---------|
| `subscription` | `TierSubscription` | Free within quota (Codex via `codex login`, pre-June-15 Claude subscription) |
| `api` | `TierAPI` | Paid per-token (Anthropic API, OpenAI API key) |
| `local` | `TierLocal` | Free, no quota (local Ollama / llama.cpp / vLLM (shipped in m17)) |
| `unknown` | `TierUnknown` | Provider cannot determine its tier at startup |

Cost rank for chain ordering: `local (0) < subscription (1) < api (2) < unknown (3)`.
`SortByCostRank` uses this ordering; lower rank = cheaper = runs first.

---

## June 15 2026 Framing

Before June 15 2026, the Claude CLI (`claude --print`) ran against an
Anthropic subscription session — usage was included in a Claude Pro/Max
plan with no per-token billing.

After June 15 2026, `claude --print` in headless mode bills against the
Anthropic API at per-token rates. The session-based subscription path
is no longer available to the CLI without the Claude desktop app acting
as an intermediary.

**Tekhton's response:** The `claude` provider now reports `TierAPI` by
default. This affects chain ordering (`api` ranks behind `subscription`)
and `--require-tier` enforcement. See the escape hatch section if you have
a legacy arrangement.

---

## How `--require-tier subscription` Works

The `--require-tier` flag (or `TEKHTON_REQUIRE_TIER` env) sets a ceiling on
which providers the chain may use. Any provider whose tier cost rank exceeds
the required tier's rank is rejected before it runs.

```bash
# Only subscription-tier providers may run. API-tier providers are blocked.
tekhton run --milestone m23 --require-tier subscription
```

If no provider in the chain meets the requirement, the run fails with:

```
provider "<name>" (tier "api") exceeds required tier "subscription"
ErrorSubcategory: TIER_LIMIT_EXCEEDED
```

This is intentional fail-fast behavior: better to surface the auth gap
explicitly than to silently bill a more expensive tier.

**Practical uses:**

- CI pipelines where any API billing triggers an alert.
- Developer machines where Claude API access is not provisioned.
- Cost-ceiling enforcement when the Codex quota is the intended budget.

---

## How to Read RUN_SUMMARY's Tier Column

`RUN_SUMMARY.json` includes `tier_used` per stage result. This is set by
`Chain.RunAgent` when a provider succeeds — it records the tier of the
winning provider, not the first provider in the chain.

Example: with `PROVIDER=codex,claude`, if Codex returns `OutcomeUpstreamError`
and Claude succeeds, `tier_used` will be `api` (Claude's tier post-June-15).

A `tier_used` value of `""` (empty) means a single (non-chain) provider ran —
tier recording is chain-specific.

---

## The `TEKHTON_CLAUDE_PRE_JUNE_15` Escape Hatch

If you have a legacy arrangement where `claude --print` still runs against a
subscription session, set this env var to opt the Claude provider into
`TierSubscription` reporting:

```bash
TEKHTON_CLAUDE_PRE_JUNE_15=true
```

**What this changes:**
- `claude.Tier()` returns `subscription` instead of `api`
- Chain ordering puts Claude before API-tier providers
- `--require-tier subscription` no longer blocks Claude

**What this does NOT change:**
- Actual billing — the operator is responsible for verifying their session
  type maps to a subscription arrangement
- The provider's behavior or prompt submission

Use this only if you have verified that your Claude CLI session is billed
under a subscription (not per-token) arrangement.
