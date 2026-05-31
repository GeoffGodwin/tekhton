# Reviewer Report — m30.2 Rescan (Cycle 2)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `rescan.go:404-407` (`readSamplesManifestFromIndexDir`): `synthIndex` is still computed and immediately discarded with `_ = synthIndex`. The code then calls `decodeSamplesManifest(manifest)` directly, bypassing `synthIndex` entirely. Remove the variable and its comment — carried from cycle 1, not addressed in rework.
- `rescan.go:468`: `var _ = errors.New` still present. Nothing in the file creates a sentinel error — `ErrMissingProjectDir` is in `crawler.go`, and all errors returned by `Rescan` are propagated from `ctx.Err()`, `DetectChangedFiles`, or `Crawl`. The `"errors"` import is unused except for this blank assignment. Remove both — carried from cycle 1, not addressed in rework.

## Coverage Gaps
- `rescan_test.go` (`TestRescanBranchTrivialIncremental`): the test touches `README.md` which is seeded in `samples/manifest.json`, so `samples/manifest.json` will be regenerated — but the test does not assert this. Add a positive write assertion for `samples/manifest.json` to make the write-set table bidirectional. Carried from cycle 1.
- `rescan_test.go` (`TestRescanBranchMajorTriggersFullCrawl`): asserts `r.Mode` and `r.Significance` but does not check `r.FallbackReason`. Add a `strings.Contains` check for "major structural changes". Carried from cycle 1.

## ACP Verdicts
- ACP: `ExtractScanMetadata preserves bash dirname-quirk; Rescan bypasses it internally` — **ACCEPT** (unchanged from cycle 1). The internal/external split is the correct minimal resolution. No new concerns.
- ACP: `scripts/wedge-audit.sh PATTERNS extracted to data-only sibling file` — **ACCEPT**. The rework extracted `PATTERNS` to `scripts/wedge-audit-patterns.sh` (229 lines, single array assignment, no function bodies, no conditional logic — qualifies for the CLAUDE.md Rule 8 data-only exemption). `wedge-audit.sh` drops from 340 to 130 lines. Shellcheck-clean on both files. Regression guards are intact.

## Drift Observations
- `rescan.go:398-415` (`readSamplesManifestFromIndexDir`): the function has a three-way structure (fileExists-branch using `decodeSamplesManifest` directly, dead `synthIndex` variable, then legacy `ExtractSampledFiles` fallback) that will confuse the next reader. Once the dead variable is removed (Non-Blocking Note above), a single explanatory comment on the why of the direct-read vs. the legacy fallback path would be worth adding.

---

## Prior Blocker Verification

**Blocker 1 — `rescanFallToFull` silently drops errors: FIXED.**

`rescanFallToFull` now returns `(*RescanResult, error)`. The guard `if cr == nil && err != nil { return nil, err }` at line 202-204 correctly propagates context cancellation and `ErrMissingProjectDir`. Every call site in `Rescan` is a direct `return rescanFallToFull(...)` so the error reaches the caller unchanged. The one exception is the Major branch (lines 176-182), which uses `res, err := rescanFallToFull(...); if err != nil { return nil, err }` — also correct. The misleading "preserve the error in the underlying Result.Errors" comment was replaced with an accurate description of the `cr == nil` vs `cr != nil` error semantics.

**Blocker 2 — `scripts/wedge-audit.sh` at 340 lines: FIXED.**

`wedge-audit.sh` is now 130 lines. The `PATTERNS` array was extracted verbatim to `scripts/wedge-audit-patterns.sh` (229 lines, data-only). The eight m30.2 regression guards (`rescan_project`, `_update_index_sections`, `_get_changed_files_since_scan`, `_detect_significant_changes`, `_is_manifest_file`, `_is_config_file`, `_extract_sampled_files`, `_record_scan_metadata`) are present in `wedge-audit-patterns.sh` at lines 221-228. The `rescan.sh` + `rescan_helpers` source-block pattern is at line 203. Both files pass shellcheck.
