# Drift Log

## Metadata
- Last audit: 2026-04-05
- Runs since audit: 5

## Unresolved Observations
- [2026-04-05 | "[BUG] Refresh Button in Watchtower not functioning as expected."] `templates/watchtower/app.js:1101` — The `dataFiles` array in `refreshData()` lists files in a different order than the `<script>` tags in `index.html` (security/reports are swapped). No functional impact since `Promise.all` parallelizes all fetches, but maintaining consistent ordering between the two files would reduce the risk of future divergence.
- [2026-04-05 | "M59"] `UI_FINDINGS_BLOCK` is populated by reading `SPECIALIST_UI_FINDINGS.md` directly in `run_specialist_reviews()` (lines 110–113), while `SECURITY_FINDINGS_BLOCK` is assembled in `stages/security.sh` from parsed finding arrays. The two patterns are inconsistent. Not a blocker — both work — but future specialists may follow the wrong model. Worth noting in the architecture log.
- [2026-04-05 | "M58"] `stages/tester.sh` is 503 lines — the M58 change (lines 69–95, ~26 lines) didn't create this; the file was already well over the 300-line ceiling before this milestone. Worth tracking for a future extract (e.g., `_run_tester_ui_guidance.sh`) in the next audit cycle.

## Resolved
