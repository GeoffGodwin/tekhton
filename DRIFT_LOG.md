# Drift Log

## Metadata
- Last audit: 2026-03-20
- Runs since audit: 5

## Unresolved Observations

## Resolved
- [RESOLVED 2026-03-21] `tekhton.sh` early-exit block sourcing divergence — Acknowledged as tracked. No code change; structural consolidation deferred to future refactor.
- [RESOLVED 2026-03-21] `&>/dev/null 2>&1` redundancy — Fixed in lib/rescan.sh (lines 51, 68), lib/rescan_helpers.sh (line 161), and lib/crawler.sh (lines 188, 233). Standardized to `&>/dev/null` only.
- [RESOLVED 2026-03-21] `_replace_section` awk backslash interpretation — Fixed in lib/rescan_helpers.sh. Changed from `-v body=` to `ENVIRON["REPLACE_BODY"]` which preserves literal backslashes.
- [RESOLVED 2026-03-21] `crawler_deps.sh` implicit dependency on `_extract_json_keys` — No code change warranted. Dependency is documented in file header and load-order-controlled by tekhton.sh, consistent with codebase convention.
