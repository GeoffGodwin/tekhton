## Changes Made

### Fix: Remove `RETRY_EXHAUSTED` from `fallthroughSubcategories` in m12 scaffold

**File:** `.claude/milestones/m12-codex-provider-selection-dogfood.md`

Removed `"RETRY_EXHAUSTED": true` from the `fallthroughSubcategories` map in the
`provider_chain.go` design code block.

The map previously included `RETRY_EXHAUSTED` as a fallthrough subcategory, which
directly contradicted the "Watch For" section in the same document:

> m12 doesn't fall through `RETRY_EXHAUSTED` because if Provider A exhausted
> retries, Provider B might just exhaust them too — fall through only for
> fast-failure categories.

Leaving `RETRY_EXHAUSTED` in the map would cause a coder implementing m12 to
produce a chain that falls through to Provider B after Provider A exhausts
retries — the exact behavior the design intent prohibits. The fix removes the
entry and adds an inline comment documenting the exclusion rationale so the
intent is self-evident to the implementing coder.

## Items Not Addressed

The following items from the reviewer report are outside the scope of simple
blockers and were not modified:

- **Non-blocking:** Missing `"strings"` import in `Chain.Name()` scaffold (compile-
  time catch; not a design correctness issue).
- **Non-blocking:** `?` placeholders in `cost_aggregator.go` scaffold (m14) for
  `EstimateCents` and `PerProvider` — requires design decision on `ProviderName`
  field placement.
- **Non-blocking:** `resolveAuth` Codex CLI precedence assumption undocumented in
  m11 Watch For.
- **Non-blocking:** `~/.codex/auth.json` world-readable silent acceptance in m11.
- **Coverage gaps:** `extractTokensFromResult` unspecified in m14; m12 dogfood
  evidence not covered by automated grep assertion.
- **Drift observations:** `FallthroughCount` / fallthrough logging not in acceptance
  criteria; dual `fileExists` stat in m11+m13; no unknown-field test for
  `costrates.json`.
