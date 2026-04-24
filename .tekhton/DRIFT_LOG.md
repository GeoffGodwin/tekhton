# Drift Log

## Metadata
- Last audit: 2026-04-23
- Runs since audit: 2

## Unresolved Observations
- [2026-04-23 | "M125"] `lib/config_defaults.sh` is 621 lines, more than double the 300-line ceiling stated in the reviewer checklist. The file contains no logic (only `:=` default assignments and `_clamp_config_value` calls), so it is arguably a data file rather than a code file. However, there is no explicit carve-out for it in CLAUDE.md. As the file continues to grow each milestone, this gap should be acknowledged — either document `config_defaults.sh` as exempt from the ceiling, or plan a split (e.g., quota-related defaults into their own file).
- [2026-04-23 | "Implement Milestone 124: TUI Quota-Pause Awareness & Spinner Coordination"] `lib/quota.sh:149` — `source "${TEKHTON_HOME}/lib/quota_sleep.sh"` appears after the `enter_quota_pause` function body that calls `_quota_sleep_chunked` at line 128. Functionally correct (the `source` executes at file-load time, before any function call), and the comment at lines 146–148 explains the placement. The inverted ordering (call site appears before definition site) could mislead a reader doing a top-to-bottom skim. No change required; noting for the audit backlog.
- [2026-04-23 | "architect audit"] **Drift Obs 3 — Prior audit deferrals (pipeline_order subshell overhead, `_INIT_FILES_WRITTEN` scatter risk, further `common.sh` reduction).** All three sub-items were reviewed and explicitly deferred by a prior architect audit with written justification: no demonstrated performance problem for the subshell, no scatter has materialized for the global, and further `common.sh` splitting risks circular sourcing. The observation itself documents those decisions. No new evidence contradicts the prior rationale. These remain standing deferrals; no action this cycle.

## Resolved
