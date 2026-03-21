# Drift Log

## Metadata
- Last audit: 2026-03-20
- Runs since audit: 2

## Unresolved Observations
- [2026-03-20 | "architect audit"] **`crawler_deps.sh` implicit runtime dependency on `_extract_json_keys`**
- [2026-03-20 | "architect audit"] **Observation:** `crawler_deps.sh` depends on `_extract_json_keys` (defined in `detect.sh`) without a source-time validation guard.
- [2026-03-20 | "architect audit"] **Justification for deferral:** The drift log itself notes this is "consistent with how other companion files handle cross-library deps in this codebase." The dependency is documented in the file header (`# Depends on: detect.sh (_extract_json_keys)`), which is the established convention. No other companion file in `lib/` performs source-time dependency validation; adding it here would introduce an inconsistent pattern. The dependency is load-order-controlled by `tekhton.sh`, which sources `detect.sh` before `crawler_deps.sh`. No remediation action is warranted.

## Resolved
