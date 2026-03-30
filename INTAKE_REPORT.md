## Verdict
TWEAKED

## Confidence
62

## Reasoning
- Scope is clear: auto-refresh must be scoped to Reports and Live Run pages only
- Fix direction is unambiguous — restrict the refresh trigger to those two pages
- No acceptance criteria listed; a developer cannot verify the fix is correct without them
- No specification of which pages currently exist in Watchtower, so "elsewhere" is underspecified
- UI testability gap: no verifiable browser-level criteria despite this being a navigation/reload behavior

## Tweaked Content

### [BUG] Watchtower: Auto-refresh applies to all pages instead of only Reports and Live Run

**Problem:** The auto-refresh mechanism triggers on all Watchtower pages instead of being restricted to the pages where live data is relevant: Reports and Live Run.

**Expected behavior:** Auto-refresh should only be active on:
- The Reports page
- The Live Run page

Auto-refresh must be inactive (no polling, no reloads) on all other pages (e.g., Trends, Settings, History, or any other non-live pages).

**Acceptance criteria:**
- Navigating to the Reports page starts the auto-refresh cycle as before
- Navigating to the Live Run page starts the auto-refresh cycle as before
- Navigating to any other page (e.g., Trends) does NOT trigger auto-refresh
- Switching away from Reports or Live Run to another page stops any active refresh timer
- Switching back to Reports or Live Run from another page resumes auto-refresh
- [PM: added] No console errors on any page transition related to refresh teardown
- [PM: added] Rapid page switching (Reports → Trends → Reports) does not result in duplicate refresh intervals

**Watch For:**
- [PM: added] Timer/interval leak: if the refresh interval is not cleared on page leave, multiple overlapping timers can accumulate and cause rapid-fire reloads
- [PM: added] Component lifecycle: if the refresh is initialized in a shared layout component rather than per-page, it must be moved or made conditional on the current route
