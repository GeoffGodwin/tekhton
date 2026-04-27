# Docs Agent Report — M130 Causal-Context-Aware Recovery Routing

## Summary
Updated CLAUDE.md to document two new configuration variables introduced by M130.
The coder already created `docs/troubleshooting/recovery-routing.md` with comprehensive recovery action and retry-guard documentation.

## Files Updated
- **CLAUDE.md** (Template Variables section, lines 474-475)
  - Added `BUILD_FIX_CLASSIFICATION_REQUIRED` (M130) — controls whether build-gate failures use classification-based routing vs. always-retry behavior
  - Added `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` (M130) — allows users to opt out of env-gate recovery retries via pipeline.conf

## Public-Surface Coverage

| Change | Documented In | Notes |
|--------|---------------|----|
| `retry_ui_gate_env` recovery action | docs/troubleshooting/recovery-routing.md | Created by coder; covers when/why this action is chosen |
| `BUILD_FIX_CLASSIFICATION_REQUIRED` config | CLAUDE.md + docs/troubleshooting/recovery-routing.md | Template variables + troubleshooting guide |
| `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` config | CLAUDE.md + docs/troubleshooting/recovery-routing.md | Template variables + opt-out reference |
| Retry guards (one-shot semantics) | docs/troubleshooting/recovery-routing.md | Comprehensive table of guards and lifecycle |
| Decision tree (Amendments A–D) | docs/troubleshooting/recovery-routing.md | Full routing logic and routing table |

## No Update Needed
- **README.md**: High-level content unchanged; users referred to docs/USAGE.md and docs/configuration.md
- **docs/configuration.md**: Summary table of categories; new variables are configuration details covered in recovery-routing.md
- **docs/cli-reference.md**: No new CLI flags introduced
- **ARCHITECTURE.md**: No new exported functions or public APIs (recovery routing is in lib/ only)

## Implementation Notes
- M130 recovery routing is fully implemented in `lib/orchestrate_recovery*.sh` (internal modules)
- The new recovery-routing.md file serves as the authoritative troubleshooting guide
- Both new config variables have sensible defaults that preserve backward compatibility
- No breaking changes to the public API
