## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `templates/watchtower/app.js:699` — The filter click handler reconstructs `run_type` by reading the `.run-type-tag` span's `textContent` and applying `replace(/\s+/g, '_')`. This is fragile: if display formatting ever changes (capitalisation, locale, special chars), the reconstructed type will silently mismatch `matchFilter`. Storing `data-run-type="{{rt}}"` on each `<li>` would make the round-trip lossless.

## Coverage Gaps
- No automated test exercises the filter button click handler's `shown` counter update. A regression here would be invisible until manual QA.

## ACP Verdicts
- None

## Drift Observations
- `templates/watchtower/app.js:484,575` — Two remaining `(s.run_type || 'milestone')` fallbacks exist for the live-run / active pipeline state display (different from the historical runs list fixed here). If a live run has no `run_type`, it displays as "milestone" in the live status card. Worth a follow-up pass to confirm whether `'adhoc'` (or an explicit sentinel) is the correct default there too.
