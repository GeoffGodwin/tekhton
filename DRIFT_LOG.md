# Drift Log

## Metadata
- Last audit: 2026-04-05
- Runs since audit: 1

## Unresolved Observations
- [2026-04-05 | "Milestone 66"] `lib/dashboard_parsers_runs.sh:250-254`: The bash fallback injects `"cycles":N` and `"rework_cycles":N` into the JSON string using `sed` pattern replacement after the `stages_json` loop. If any future field is added before `"reviewer":{` or `"security":{` that also starts with `"reviewer":` or `"security":`, the injection point could shift. Consider a builder approach instead of post-hoc string surgery.
- [2026-04-05 | "Milestone 66"] `stages/tester.sh:355-393`: The test_audit sub-step tracking block appears twice — once in the continuation path (line 355-361) and once in the clean-completion path (line 387-393). The code is identical. Consider extracting to a shared helper `_record_test_audit_substep` to avoid future divergence.
(none)

## Resolved
- [RESOLVED 2026-04-05] Refresh Button in Watchtower not functioning as expected."] `templates/watchtower/app.js:1101` — The `dataFiles` array in `refreshData()` lists files in a different order than the `<script>` tags in `index.html` (security/reports are swapped). No functional impact since `Promise.all` parallelizes all fetches, but maintaining consistent ordering between the two files would reduce the risk of future divergence.
- [RESOLVED 2026-04-05] `UI_FINDINGS_BLOCK` is populated by reading `SPECIALIST_UI_FINDINGS.md` directly in `run_specialist_reviews()` (lines 110–113), while `SECURITY_FINDINGS_BLOCK` is assembled in `stages/security.sh` from parsed finding arrays. The two patterns are inconsistent. Not a blocker — both work — but future specialists may follow the wrong model. Worth noting in the architecture log.
- [RESOLVED 2026-04-05] `stages/tester.sh` is 503 lines — the M58 change (lines 69–95, ~26 lines) didn't create this; the file was already well over the 300-line ceiling before this milestone. Worth tracking for a future extract (e.g., `_run_tester_ui_guidance.sh`) in the next audit cycle.
