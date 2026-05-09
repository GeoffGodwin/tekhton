# Drift Log

## Metadata
- Last audit: 2026-05-08
- Runs since audit: 1

## Unresolved Observations
- [2026-05-08 | "Implement Milestone 19: tekhton run Top-Level Command"] All `orchestrate_*.sh` sourced library files still carry `set -euo pipefail`. Per CLAUDE.md sourced lib files should not repeat this declaration (they inherit). The pattern predates m19; the new `orchestrate_complete.sh` and `orchestrate_save.sh` replicate it correctly. Worth a family-wide hygiene pass in a dedicated non-blocking milestone.
- [2026-05-08 | "Implement Milestone 19: tekhton run Top-Level Command"] `scripts/run-parity-check.sh` header describes a 10-scenario comparison (lines 5–18) but the script body implements 4 structural checks. The gap is acknowledged inline but the headline may mislead future developers; either update the comment or stub the remaining 6 scenarios.

## Resolved
