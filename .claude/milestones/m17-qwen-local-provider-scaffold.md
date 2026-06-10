<!-- milestone-meta
id: "17"
status: "todo"
-->

# m17 — qwen-local Provider: Codex-Sibling Scaffold + Local Endpoint Routing

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Tekhton can already run Codex-first today (`PROVIDER=codex`) to avoid the ~15x `claude --print` API-rate billing that lands June 15 2026 — but it has no *free local* fallback. When the Codex subscription quota is exhausted, the only fallback in the default chain is the paid Claude API. The tier model already reserves `TierLocal` (`internal/provider/provider.go:103`, cost-rank 0 = cheapest) and the seam doc names the provider `qwen-local` (`docs/v5-provider-seam.md`), but no local provider exists: `internal/provider/` contains only `claude/` and `codex/`. m17 adds the `qwen-local` provider so a chain like `PROVIDER=qwen-local,codex,claude` tries a free local model first and only falls through to paid tiers when the local endpoint is unreachable. |
| **Gap** | `constructProvider` (`internal/runner/provider_select.go:54`) has only `claude` and `codex` arms — `PROVIDER=qwen-local` fails with `unknown provider "qwen-local"`. There are no config keys describing a local OpenAI-compatible endpoint. No package routes an agent CLI at a local server. `TierLocal` (rank 0) is defined but unreachable because nothing returns it. |
| **m17 fills** | A new `internal/provider/local` package whose `Provider` **delegates to the proven codex provider machinery** (exec / streaming / JSONL decode / outcome / retry — all of `internal/provider/codex/`) rather than reimplementing it. It constructs a codex invocation pointed at a local OpenAI-compatible endpoint by injecting `model_provider` config through codex's existing `-c` passthrough (`ProviderSpecific["codex.config.<KEY>"]` → `-c <KEY>=<value>`, per `internal/provider/codex/flags.go`) plus `--model`. `Name()` returns `"qwen-local"`; `Tier()` returns the constant `provider.TierLocal` (no auth/quota probe — a local endpoint has no tier to detect). Adds config keys `QWEN_LOCAL_BASE_URL`, `QWEN_LOCAL_MODEL`, `QWEN_LOCAL_PROVIDER_ID`, `QWEN_LOCAL_WIRE_API` to the Go defaults and the bash↔Go env contract, and registers a `case "qwen-local"` arm in `constructProvider`. No changes to the `codex`/`claude` packages or the `provider.Provider` interface. |
| **Depends on** | m12, m15 |
| **Files changed** | `internal/provider/local/local.go` (CREATE), `internal/provider/local/local_test.go` (CREATE), `internal/runner/provider_select.go` (modify — register arm), `internal/config/defaults.go` (modify — config keys), `internal/runner/env.go` (modify — env contract), `docs/v5-polyglot.md` (modify — local-provider section), `VERSION` |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m12 | Per-stage provider selection + fallback chain (`ResolveProvider`, `NewChain`) |
| m15 | Wired the chain to the runner + CLI flags + operator docs |
| **m17** | **Adds the first `TierLocal` provider so the chain can route to a free local model** |

---

## Design

### Sequencing note

m17 lands after m16. It is purely additive: a new package plus one
registration arm and config keys. It **reuses** the codex machinery by
delegation — it does NOT fork or refactor `internal/provider/codex/`.
Behavior of the codex and claude providers is unchanged (tenet 10).

### HARD SCOPE BOUNDARY (m17 ONLY)

The coder MUST create/modify exactly the files in the **Files changed** row
and nothing under `internal/provider/codex/` or `internal/provider/claude/`
or `internal/provider/provider.go`. Touching those FAILS m17 — the whole
point of the delegation design is to leave the proven machinery untouched.

CREATE: `internal/provider/local/local.go`, `internal/provider/local/local_test.go`.
MODIFY: `internal/runner/provider_select.go` (register arm only),
`internal/config/defaults.go` (config keys), `internal/runner/env.go`
(env contract), `docs/v5-polyglot.md`. PLUS `VERSION`.

### Goal 1 — Delegation provider

**File:** `internal/provider/local/local.go`.

`Provider` holds an inner `*codex.Provider` (from `codex.New()`) and the
resolved local-endpoint settings. `RunAgent` clones the request, sets the
local model and injects the `model_provider` config keys codex understands,
then delegates:

```go
type Provider struct {
    inner   provider.Provider // codex.New(); the agent harness + JSONL machinery
    baseURL string            // QWEN_LOCAL_BASE_URL
    model   string            // QWEN_LOCAL_MODEL
    id      string            // QWEN_LOCAL_PROVIDER_ID (inline codex provider id)
    wireAPI string            // QWEN_LOCAL_WIRE_API (MUST be "chat", not "responses")
}

func (p *Provider) Name() string { return "qwen-local" }
func (p *Provider) Tier() string { return provider.TierLocal }

func (p *Provider) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
    r := *req // shallow clone; copy the map so we don't mutate the caller's request
    r.Model = p.model
    r.ProviderSpecific = cloneAndInject(req.ProviderSpecific, map[string]string{
        "codex.config.model_provider":                          p.id,
        "codex.config.model_providers." + p.id + ".name":       "qwen-local",
        "codex.config.model_providers." + p.id + ".base_url":   p.baseURL,
        "codex.config.model_providers." + p.id + ".wire_api":   p.wireAPI, // "chat"
    })
    return p.inner.RunAgent(ctx, &r)
}
```

`-c` keys are dotted TOML paths codex applies over its config (e.g.
`-c model_providers.qwenlocal.base_url=http://localhost:11434/v1`). The
inner codex provider does the rest unchanged: builds argv (`codex exec
--json …`), pipes the prompt on stdin, decodes JSONL, derives Outcome,
retries on `OutcomeUpstreamError`. `RawProviderData`, event emission, and
the six-outcome mapping all come for free.

### Goal 2 — Config keys + env contract

Add to `internal/config/defaults.go` and the bash↔Go env contract
(`internal/runner/env.go::AsKV`):

| Key | Default | Meaning |
|-----|---------|---------|
| `QWEN_LOCAL_BASE_URL` | `http://localhost:11434/v1` | Local OpenAI-compatible endpoint (Ollama default; works for llama.cpp/vLLM/LM Studio) |
| `QWEN_LOCAL_MODEL` | `qwen2.5-coder:32b` | Model id served by the endpoint |
| `QWEN_LOCAL_PROVIDER_ID` | `qwenlocal` | Inline codex `model_provider` id |
| `QWEN_LOCAL_WIRE_API` | `chat` | Chat Completions; NOT `responses` (the Responses path is the documented local tool-calling breakage source) |

Per the V4 env contract (`docs/v4-env-contract.md`), any bash read of these
keys MUST use the `${VAR:-default}` form.

### Goal 3 — Registration + cost rank

Add to `constructProvider` (`internal/runner/provider_select.go:54`):

```go
case "qwen-local":
    return local.New() // reads QWEN_LOCAL_* config; wraps codex.New()
```

`Tier()` returning `provider.TierLocal` means `TierCostRank` ranks it 0, so
`SortByCostRank` and `NewChain` place `qwen-local` ahead of `codex`
(subscription/1) and `claude` (api/2).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/provider/local/local.go` | Create | Delegation `Provider`: `New`, `Name`→`qwen-local`, `Tier`→`TierLocal`, `RunAgent` injecting local `model_provider` config and delegating to a codex provider. |
| `internal/provider/local/local_test.go` | Create | Tier assertion, config-injection assertion (base_url + model reach the delegated request), cost-rank ordering, default-config resolution; codex inner stubbed via an interface seam. |
| `internal/runner/provider_select.go` | Modify | Add `case "qwen-local"` arm to `constructProvider`. |
| `internal/config/defaults.go` | Modify | Add the four `QWEN_LOCAL_*` defaults. |
| `internal/runner/env.go` | Modify | Emit the four `QWEN_LOCAL_*` keys in `AsKV` (env contract). |
| `docs/v5-polyglot.md` | Modify | Add a "Local provider (qwen-local)" section: config keys, what it delegates to, opt-in chain examples. |
| `VERSION` | Modify | Bump on milestone completion. |

---

## Acceptance Criteria

- [ ] `internal/provider/local` defines a type satisfying `provider.Provider` whose `Name()` returns `"qwen-local"` and `Tier()` returns `provider.TierLocal`.
- [ ] `constructProvider("qwen-local")` returns the local provider with a nil error (asserted in `provider_select` tests).
- [ ] `RunAgent` injects the local endpoint into the delegated request: a stubbed inner provider receives `req.Model == QWEN_LOCAL_MODEL` and `req.ProviderSpecific` containing a `codex.config.model_providers.<id>.base_url` entry equal to `QWEN_LOCAL_BASE_URL` (asserted in `local_test.go`).
- [ ] `RunAgent`, given a stubbed inner provider that produces an `OutcomeSuccess` `Result`, produces a `Result` with `Outcome == OutcomeSuccess` — the delegation path emits the inner provider's outcome unchanged (asserted in `local_test.go`).
- [ ] `RunAgent` copies the request's `ProviderSpecific` map rather than mutating the caller's map (asserted: caller's map is unchanged after the call).
- [ ] `TierCostRank(provider.TierLocal) == 0`, and a `NewChain("qwen-local","codex","claude")` orders `qwen-local` first after `SortByCostRank` (asserted in `local_test.go`).
- [ ] Config defaults resolve to `QWEN_LOCAL_BASE_URL=http://localhost:11434/v1` and `QWEN_LOCAL_MODEL=qwen2.5-coder:32b` when unset (asserted against `internal/config`).
- [ ] `QWEN_LOCAL_WIRE_API` defaults to `chat` (asserted).
- [ ] All new tests pass: `internal/provider/local/local_test.go` and the new `provider_select` arm test.
- [ ] No regression: `go test ./internal/provider/... ./internal/runner/...` passes; `go vet ./...` and `golangci-lint run` are clean.
- [ ] `scripts/audit-bash-env.sh` passes (any bash read of `QWEN_LOCAL_*` uses `${VAR:-default}`).
- [ ] `docs/v5-polyglot.md` contains a section documenting `PROVIDER=qwen-local,codex,claude` and the four `QWEN_LOCAL_*` keys.

## Watch For

- **Delegate, do not fork.** Reuse codex's exec/decode/outcome by delegating to a `codex.Provider`. Do NOT copy the codex package — duplication invites parity drift (tenet 10). If `codex.New()`/`RunAgent` can't be delegated cleanly from another package, define a one-method interface seam in `local` over the codex provider rather than reaching into codex internals.
- **`Tier()` is a constant.** Do NOT replicate codex's `~/.codex/auth.json` tier probe; a local endpoint has no subscription/api tier. Return `TierLocal` unconditionally.
- **`codex` must be on PATH** even for `qwen-local`, since it's the agent harness driving the tool loop. Document this. (A future native `qwen-code` provider would remove this dependency — out of scope here.)
- **`wire_api=chat`, never `responses`.** The Responses API path is the documented source of local tool-calling breakage (codex issues #19871, #1734). Default and document `chat`.
- **Do not change the default `PROVIDER`.** It stays `codex,claude`. Local is opt-in until m18's smoke test proves the tool loop actually fires against a local model.
- This milestone does NOT prove qwen-local works end-to-end — it only wires it. The honesty gate is m18. Do not add a live-server test here.

## Seeds Forward

- **m18:** the end-to-end tool-loop smoke test, chain tier recording, `--require-tier local` enforcement, and operator runtime docs all build on this provider and config surface.
- **Native qwen-code provider (deferred):** if codex-against-local tool-calling proves flaky in m18, a dedicated `qwen-code` provider can replace the delegation behind the same `Name()`/`Tier()`/`constructProvider` seam without touching callers.
- **`--require-tier local`:** fully-offline / zero-billing enforcement leans on a provider actually returning `TierLocal`, which lands here.
