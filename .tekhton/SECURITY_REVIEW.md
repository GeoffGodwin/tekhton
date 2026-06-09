## Summary
This review covers the V5 Phase 2 provider abstraction layer across milestones m07–m13: `internal/provider` (interface, ToolSchema, Tier constants), `internal/provider/claude` (Claude reference provider), `internal/provider/codex` (Codex subprocess provider: auth, exec, streaming, retry, tool translation), and `internal/runner/provider_chain.go`. The implementation is well-structured — subprocess invocation uses `exec.CommandContext` with direct argv (no shell expansion), temp files are cleaned up via deferred callbacks, API keys are not logged, and context cancellation propagates correctly. Three findings are noted below; none are blocking.

## Findings
- [MEDIUM] [category:A01] [internal/provider/codex/tools.go:58-62] fixable:yes — Unknown Tekhton tool names silently escalate to the `shell` catch-all permission in the translated Codex argv. A typo in a tool name (e.g. "bash" vs "Bash") or an unrecognised future tool silently grants broader file/shell access than intended instead of failing closed. Should return an error for unrecognised tool names rather than emitting a permissive `shell` grant.
- [LOW] [category:A07] [internal/provider/codex/codex.go:61-73] fixable:yes — `Tier()` performs a non-atomic lazy-init on `p.cachedTier` (read-check then write) with no mutex. If a `*Provider` is shared across goroutines (e.g. `Chain.SortByCostRank()` called concurrently), this is a Go data race on a string field — undefined behaviour. Fix with `sync.Once` or `sync/atomic`.
- [LOW] [category:A02] [internal/provider/codex/auth.go:33] fixable:unknown — Per-request API keys from `req.ProviderSpecific["codex.api_key"]` are injected into the subprocess environment as `CODEX_API_KEY=<key>`. On Linux, the key is readable via `/proc/<pid>/environ` for the subprocess lifetime by any same-UID process. Standard env-var auth trade-off; acceptable here, but operators should be aware.

## Verdict
FINDINGS_PRESENT
