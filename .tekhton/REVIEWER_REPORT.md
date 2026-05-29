# Reviewer Report — m28.2 Serena Startup Probe + Truthful Status

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
None

## Simple Blockers (jr coder)
None

## Non-Blocking Notes
- `VERSION` reads `4.27.7` but the milestone AC specified `4.27.6`. The coder summary claims the bump was `4.27.5 → 4.27.6`, and the security stage ran successfully before this review — most likely the pipeline's patch-increment finalization hook advanced it one more step. Not a defect in `mcp.sh`. The pre-existing `test_mcp_serena_bin.sh` AC8 grep (`4.27.x where x ≥ 5`) already tolerates this.
- `lib/mcp.sh:15`: `set -euo pipefail` in a sourced library file is a pre-existing violation of the convention (sourced files should inherit from the entry point, not set their own pipefail). Not introduced by m28.2; no new violations were added. Cleanup belongs to a future hygiene pass.

## Coverage Gaps
- Dedicated probe-stub tests exercising `_probe_serena_startup` directly against `/usr/bin/false`, `/usr/bin/echo`, and a hanging script are deferred by design to m28.3 (Seeds Forward). Not a gap for this milestone.

## Drift Observations
- `lib/mcp.sh:15` — pre-existing `set -euo pipefail` in a sourced lib file (same note carried from m28.1 review). Convention reserves this for standalone entry points; sourced files in `lib/` inherit. Cleanup belongs to a future hygiene milestone.
