# Drift Log

## Metadata
- Last audit: 2026-03-30
- Runs since audit: 1

## Unresolved Observations
(none)

## Resolved
- [RESOLVED 2026-03-30] Watchtower Trends page: Recent Runs section does not show the latest two --human runs, it only shows the last --milestone run.**"] `templates/watchtower/app.js:484,575` — Two remaining `(s.run_type || 'milestone')` fallbacks exist for the live-run / active pipeline state display (different from the historical runs list fixed here). If a live run has no `run_type`, it displays as "milestone" in the live status card. Worth a follow-up pass to confirm whether `'adhoc'` (or an explicit sentinel) is the correct default there too.
- [RESOLVED 2026-03-30] Watchtower Reports page: Test Audit section never displays any information"] `templates/watchtower/app.js` — The emitter→renderer contract (data shape) is implicit; a comment on `renderTestAuditBody()` documenting the expected fields (`verdict`, `high_findings`, `medium_findings`) would prevent re-introducing the same mismatch
