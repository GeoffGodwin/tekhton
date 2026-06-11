## What Was Fixed

- **docs/v5-polyglot.md — added `## Local Provider (qwen-local)` section** (AC item 6): five-step Ollama + `qwen2.5-coder:32b` setup recipe verbatim from m18 Design §Goal 3; `wire_api=chat` called out in both the inline comment and the `pipeline.conf` snippet; troubleshooting entry for "run reports success but no files changed" directing operators to verify `wire_api=chat`, use a ≥32B model at ≥4-bit, and confirm the smoke test passes.
- **docs/v5-tier-model.md:14 — updated `local` tier row** (AC item 7): changed "local llama.cpp / vLLM — V5 Phase 2" to "local Ollama / llama.cpp / vLLM (shipped in m17)".
- **internal/runner/provider_chain_test.go — added `TestChain_RunAgent_LocalTierWins`**: drives `RunAgent` on a `qwen-local,codex,claude` chain where the local-tier stub returns `OutcomeSuccess`; asserts `res.TierUsed == provider.TierLocal`.
- **internal/runner/provider_chain_test.go — added `TestChain_RunAgent_RequiredTier_Local_RejectsAll`**: sets `c.RequiredTier = provider.TierLocal` with a subscription-tier (codex) and api-tier (claude) provider; asserts both are rejected with `errors.Is(err, runner.ErrTierLimitExceeded)` and `res.ErrorSubcategory == "TIER_LIMIT_EXCEEDED"`.

## Files Modified

- `docs/v5-polyglot.md`
- `docs/v5-tier-model.md`
- `internal/runner/provider_chain_test.go`
