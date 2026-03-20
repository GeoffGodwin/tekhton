# Drift Log

## Metadata
- Last audit: 2026-03-20
- Runs since audit: 1

## Unresolved Observations
- [2026-03-20 | "architect audit"] **`crawler_deps.sh` implicit runtime dependency on `_extract_json_keys`**
- [2026-03-20 | "architect audit"] **Observation:** `crawler_deps.sh` depends on `_extract_json_keys` (defined in `detect.sh`) without a source-time validation guard.
- [2026-03-20 | "architect audit"] **Justification for deferral:** The drift log itself notes this is "consistent with how other companion files handle cross-library deps in this codebase." The dependency is documented in the file header (`# Depends on: detect.sh (_extract_json_keys)`), which is the established convention. No other companion file in `lib/` performs source-time dependency validation; adding it here would introduce an inconsistent pattern. The dependency is load-order-controlled by `tekhton.sh`, which sources `detect.sh` before `crawler_deps.sh`. No remediation action is warranted.

## Resolved
- [RESOLVED 2026-03-20] `crawler_inventory.sh:173` uses `grep -oE '^[^/]/'` to find top-level test directories, then `grep -c "^${d}"` to count files in them. The `grep -c` pattern is duplicated from similar patterns in `_crawl_test_structure` and the inventory function — a shared `_count_files_in_dir(file_list, prefix)` helper would reduce duplication across future milestone work. (Carry-over from prior review.)
- [RESOLVED 2026-03-20] `crawler_deps.sh` has an implicit runtime dependency on `_extract_json_keys` (defined in `detect.sh`). This is documented in the file header but not validated at source time. Consistent with how other companion files handle cross-library deps in this codebase. (Carry-over from prior review.)
- [RESOLVED 2026-03-20] `lib/metrics_dashboard.sh:162` and `lib/metrics_dashboard.sh:186` — `val`/`est`/`actual` variables are set via `grep ... || true`, which can produce empty strings; `$(( sum + val ))` with an empty `val` is a bash arithmetic syntax error. This latent bug was pre-existing in `metrics.sh` before extraction — not a regression introduced here.
- [RESOLVED 2026-03-20] `lib/metrics.sh`, `lib/metrics_calibration.sh`, `lib/metrics_dashboard.sh` — all three metrics library files are missing `set -euo pipefail`. All other sourced lib files include it. Worth a single cleanup commit to standardize the family.
