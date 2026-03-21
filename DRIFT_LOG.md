# Drift Log

## Metadata
- Last audit: 2026-03-20
- Runs since audit: 4

## Unresolved Observations
- [2026-03-21 | "Resolve all observations in NON_BLOCKING_LOG.md. For each unresolved item, apply the fix, then mark it resolved. Continue until no unresolved observations remain."] `tekhton.sh` has three early-exit blocks (`--plan`, `--replan`, `--rescan`) each with bespoke sourcing lists that diverge from each other and from the main pipeline. This is a recurring source of "function available in main pipeline but not in early-exit path" bugs (the Cycle 1 blocker being a fresh example). No fix required now — already tracked from previous cycle.
- [2026-03-21 | "Implement Milestone 20: Incremental Rescan & Index Maintenance"] lib/rescan.sh:51, lib/rescan.sh:68, lib/rescan_helpers.sh:161 — `&>/dev/null 2>&1` is used (redirecting stdout+stderr with `&>`, then redundantly adding `2>&1`). This same pattern exists in crawler.sh:188 and crawler.sh:233, so it is pre-existing in the codebase. No action needed but worth standardizing on `&>/dev/null` alone when these files are next touched.
- [2026-03-21 | "Implement Milestone 20: Incremental Rescan & Index Maintenance"] lib/rescan_helpers.sh:_replace_section — The awk `-v body="$new_body"` assignment interprets backslash escape sequences. If a section contains literal backslashes (e.g., Windows paths in sampled files), the replacement body may be corrupted. The existing crawler.sh does not use this replacement pattern, so it is new surface area. Low probability in practice given the codebase context.
- [2026-03-20 | "architect audit"] **`crawler_deps.sh` implicit runtime dependency on `_extract_json_keys`**
- [2026-03-20 | "architect audit"] **Observation:** `crawler_deps.sh` depends on `_extract_json_keys` (defined in `detect.sh`) without a source-time validation guard.
- [2026-03-20 | "architect audit"] **Justification for deferral:** The drift log itself notes this is "consistent with how other companion files handle cross-library deps in this codebase." The dependency is documented in the file header (`# Depends on: detect.sh (_extract_json_keys)`), which is the established convention. No other companion file in `lib/` performs source-time dependency validation; adding it here would introduce an inconsistent pattern. The dependency is load-order-controlled by `tekhton.sh`, which sources `detect.sh` before `crawler_deps.sh`. No remediation action is warranted.

## Resolved
