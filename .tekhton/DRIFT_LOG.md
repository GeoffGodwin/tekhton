# Drift Log

## Metadata
- Last audit: 2026-04-13
- Runs since audit: 1

## Unresolved Observations

## Resolved
- [RESOLVED 2026-04-13] `validate_config.sh:235-238`: `_vc_check_models()` emits a pass for "Model names recognized" even when all model vars are unset (all iterations `continue`). The pass message implies models were checked, but if none are configured the check is a no-op — cosmetically misleading. Carried from cycle 1.
- [RESOLVED 2026-04-13] `lib/init_config_sections.sh` scope: M83 milestone spec listed only `tekhton.sh`, `lib/init_config_emitters.sh`, `lib/express_persist.sh` — the addition of `init_config_sections.sh` is correct and required but the spec comment is stale. Carried from cycle 1.
- [RESOLVED 2026-04-13] `lib/common.sh` has no `set -euo pipefail` (long-standing omission), while `finalize_display.sh`, `diagnose_output.sh`, `milestone_progress.sh`, and `milestone_progress_helpers.sh` all do. The codebase has split conventions for sourced lib files. A cleanup pass to align all lib files would resolve the inconsistency.
- [RESOLVED 2026-04-13] `lib/prompts.sh:86` — The self-referential `${VAR:-${VAR}}` pattern is a common M72 migration mistake. A broader scan of other files changed in this milestone is worth doing to ensure this isn't replicated elsewhere — it was only found in prompts.sh.
- [RESOLVED 2026-04-13] `tekhton.sh:106` — `ARCHITECT_PLAN.md` is still hardcoded (correct per spec — it is a single-run artifact not subject to migration), but the comment on that line says "archive it if it exists" without noting the `.tekhton/` context. No action needed; observation only.
