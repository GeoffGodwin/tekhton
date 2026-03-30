## Verdict
TWEAKED

## Confidence
72

## Reasoning
- Scope is clear: disable auto-refresh on the Actions screen only
- Root cause and expected behavior are unambiguous — the screen has no live data, so refresh serves no purpose
- Human notes corroborate this as part of a broader pattern (auto-refresh should be limited to Reports and Live Run pages)
- Missing explicit acceptance criteria — the task is a bug description, not a milestone spec; testable criteria need to be stated
- No UI-verifiable criteria present despite this being a UI bug fix (rubric flags this)

## Tweaked Content
[BUG] Watchtower Actions screen: Auto-refresh wipes all form fields every few seconds, making the screen unusable during a pipeline run. Actions screen has no live run data and should not refresh at all.

**Root Cause Context:**
Auto-refresh is currently applied globally. It should only apply to pages that display live run data (Reports and Live Run). The Actions screen has no live data and must be excluded.

**Acceptance Criteria:**
- [PM: Added] Auto-refresh does NOT trigger on the Actions screen — navigating to Actions and waiting 2× the refresh interval results in no page reload
- [PM: Added] Form fields on the Actions screen (inputs, selects, text areas) retain their values after the refresh interval has elapsed
- [PM: Added] Pages that legitimately need auto-refresh (Reports, Live Run) are unaffected by this change — they continue to refresh at their configured interval
- [PM: Added] No console errors appear on the Actions screen related to refresh logic
- [PM: Added] The fix is implemented by conditional exclusion in the auto-refresh mechanism (e.g., page type/route guard), not by increasing the refresh interval

**Watch For:**
- [PM: Added] If auto-refresh is driven by a single global timer/interval, verify that removing it from one page does not accidentally remove it from all pages
- [PM: Added] Check whether the refresh mechanism checks current route/page identity — if not, a route-aware guard must be added
