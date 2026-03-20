# Drift Log

## Metadata
- Last audit: 2026-03-20
- Runs since audit: 2

## Unresolved Observations
- [2026-03-20 | "Implement Milestone 18: Project Crawler & Index Generator"] `crawler_inventory.sh:173` uses `grep -oE '^[^/]/'` to find top-level test directories, then `grep -c "^${d}"` to count files in them. The `grep -c` pattern is duplicated from similar patterns in `_crawl_test_structure` and the inventory function — a shared `_count_files_in_dir(file_list, prefix)` helper would reduce duplication across future milestone work. (Carry-over from prior review.)
- [2026-03-20 | "Implement Milestone 18: Project Crawler & Index Generator"] `crawler_deps.sh` has an implicit runtime dependency on `_extract_json_keys` (defined in `detect.sh`). This is documented in the file header but not validated at source time. Consistent with how other companion files handle cross-library deps in this codebase. (Carry-over from prior review.)
- [2026-03-20 | "Fix Milestone 17 TESTER_REPORT bugs — see TESTER_REPORT.md ## Bugs Found"] `lib/metrics_dashboard.sh:162` and `lib/metrics_dashboard.sh:186` — `val`/`est`/`actual` variables are set via `grep ... || true`, which can produce empty strings; `$(( sum + val ))` with an empty `val` is a bash arithmetic syntax error. This latent bug was pre-existing in `metrics.sh` before extraction — not a regression introduced here.
- [2026-03-20 | "Fix Milestone 17 TESTER_REPORT bugs — see TESTER_REPORT.md ## Bugs Found"] `lib/metrics.sh`, `lib/metrics_calibration.sh`, `lib/metrics_dashboard.sh` — all three metrics library files are missing `set -euo pipefail`. All other sourced lib files include it. Worth a single cleanup commit to standardize the family.

## Resolved
