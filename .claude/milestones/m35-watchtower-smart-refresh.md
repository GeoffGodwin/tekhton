# Milestone 35: Watchtower Smart Refresh & Context-Aware Layout
<!-- milestone-meta
id: "35"
status: "done"
-->


## Overview

Watchtower's full-page `location.reload()` causes a visible blink every refresh
cycle. Its layout is static — Reports and Trends render the same sections regardless
of run type, leaving irrelevant sections visible and relevant ones showing "pending"
or blank data. This milestone replaces the refresh mechanism with incremental data
loading and makes the layout adapt to the current run context.

## Scope

### 1. Incremental Data Refresh (No Blink)

**Problem:** `scheduleRefresh()` calls `location.reload()` every
`refresh_interval_ms` (default 10s). This reloads all HTML, CSS, JS, and data
files, causing a full DOM teardown and rebuild. Even with scroll position
persistence via `localStorage`, the visual flash is jarring.

**Fix:** Replace `location.reload()` with `fetch()` calls that reload only the
`data/*.js` files, then re-execute them to update the `window.TK_*` globals,
and selectively re-render changed tabs.

Implementation approach:
```javascript
function refreshData() {
  var dataFiles = ['run_state', 'timeline', 'milestones', 'reports',
                   'metrics', 'security', 'health'];
  var promises = dataFiles.map(function(name) {
    return fetch('data/' + name + '.js?t=' + Date.now())
      .then(function(r) { return r.text(); })
      .then(function(text) {
        // Execute the JS to update window.TK_* globals
        // Use Function constructor instead of eval for CSP compat
        new Function(text)();
      });
  });
  Promise.all(promises).then(function() {
    renderActiveTab();     // Only re-render current tab
    updateStatusIndicator();
    scheduleRefresh();     // Schedule next cycle
  });
}
```

Cache-busting via `?t=` query parameter ensures fresh data on `file://` protocol.
Fall back to `location.reload()` if `fetch()` is unavailable (old browsers).

**Selective re-render:** Only re-render the currently active tab. Other tabs get
`renderedTabs[tabId] = false` so they re-render when switched to.

**Files:** `templates/watchtower/app.js`

### 2. Context-Aware Reports Tab

**Problem:** The Reports tab always shows four accordion sections (Intake, Coder,
Security, Reviewer) regardless of run type. For human-notes runs, there's no
security stage. For ad hoc runs, there may be no intake. Sections show "Pending"
badges when they'll never be populated.

**Fix:**
- Read `run_type` from `TK_RUN_STATE` (added by M34) to determine which report
  sections are relevant.
- Show/hide sections based on run type:
  - `milestone`: All sections visible
  - `human_*`: Intake + Coder + Reviewer (no Security unless security stage ran)
  - `drift`: Coder + Reviewer (architect-driven, no intake)
  - `nonblocker`: Coder + Reviewer
  - `adhoc`: Show sections that have non-null data; hide rest
- Add stage status awareness: if `TK_RUN_STATE.stages[stage].status === "complete"`,
  show its report section; if "pending", hide it (not "pending" badge — hidden).
- Add a "Run Context" header card showing: run type badge, task label, milestone
  ID (if applicable), started timestamp, current/final status.

**Additional report sections** (from existing data, not currently rendered):
- **Test Audit** section: data is already in `TK_REPORTS.test_audit` but no
  render function exists. Add `renderTestAuditBody()`.
- **Notes Backlog** section: data is already in `TK_REPORTS.backlog` but no
  render function exists. Add `renderBacklogBody()` showing bug/feat/polish counts.

**Files:** `templates/watchtower/app.js`, `templates/watchtower/style.css`

### 3. Enhanced Trends Tab

**Problem:** Recent Runs list shows milestone ID as the only run identifier.
Non-milestone runs show "-". The per-stage breakdown was always empty (fixed by
M34's data layer changes), but the display needs updating.

**Fix:**

**Recent Runs enhancements:**
- Show `run_type` as a colored badge alongside run number
- Show `task_label` (truncated to ~40 chars) instead of just milestone ID
- For milestone runs, show both milestone ID and title
- Add run type filter buttons above the list: All | Milestones | Human Notes |
  Drift | Ad Hoc — filter toggles stored in `localStorage`

**Efficiency Summary enhancements:**
- Calculate averages per run type (milestone runs vs human notes vs ad hoc)
- Show the breakdown: "Milestone avg: 42 turns · Human avg: 18 turns · Ad hoc avg: 12 turns"
- Fix trend arrows to work with fewer than 20 runs (currently returns empty string
  if `runs.length < 20`). Lower threshold to 4 runs and compare halves.

**Per-Stage Breakdown enhancements:**
- Now populated with real data (from M34)
- Add a "last run" column showing the most recent run's per-stage values alongside
  the historical averages, so users can spot anomalies
- Color-code budget utilization: green (<80%), amber (80-100%), red (>100%)

**Files:** `templates/watchtower/app.js`, `templates/watchtower/style.css`

### 4. Refresh Lifecycle Cleanup

**Problem:** Auto-refresh continues indefinitely when status is "running" but
never terminates cleanly when the pipeline finishes between reloads.

**Fix:**
- Use `completed_at` timestamp from `TK_RUN_STATE` (added by M34) to detect
  pipeline completion
- On detecting completion, do one final data refresh, then stop the refresh loop
- Show a subtle "Pipeline completed — refresh stopped" indicator in the header
- Add a manual "Refresh" button in the header that triggers a single data reload
  (useful after pipeline completes, for viewing updated metrics)

**Files:** `templates/watchtower/app.js`, `templates/watchtower/index.html`,
`templates/watchtower/style.css`

## Acceptance Criteria

- Watchtower updates data without full page reload (no visible blink/flash)
- Only the active tab re-renders on each refresh cycle
- Scroll position is preserved across refreshes without localStorage hacks
- Reports tab hides sections for stages that didn't run in the current run type
- Reports tab shows Test Audit and Notes Backlog sections when data is available
- Reports tab shows a "Run Context" header with run type, task label, and status
- Trends Recent Runs shows run type badges and task labels for all run types
- Trends Recent Runs supports filtering by run type
- Trends efficiency stats show per-run-type averages
- Trend arrows work with as few as 4 historical runs
- Per-stage breakdown shows color-coded budget utilization
- Auto-refresh stops when pipeline completes, with manual refresh button available
- Fallback to `location.reload()` works when `fetch()` is unavailable
- All existing tests pass (`bash tests/run_tests.sh`)

## Watch For

- `file://` protocol has CORS restrictions in some browsers. `fetch('data/run_state.js')`
  may fail on `file://`. Test with Chrome (allows same-origin file://), Firefox
  (restricts by default), and Safari. Document the `python3 -m http.server` fallback
  prominently.
- The `new Function(text)()` approach for executing loaded JS must handle parse errors
  gracefully. Wrap in try/catch and fall back to `location.reload()` on failure.
- Selective re-render must rebuild the causal index (`buildCausalIndex()`) when
  timeline data changes, not just on initial load.
- The `renderedTabs` lazy-render pattern conflicts with incremental refresh.
  Change to: always re-render active tab on data change, mark other tabs as stale.
- `TK_RUN_STATE.run_type` won't exist in data files from runs before M34. Default
  to `"milestone"` when `run_type` is missing (backward compat).

## Seeds Forward

- M36 adds interactive controls that need non-blinking refresh to feel responsive
- M37 adds parallel team views that rely on selective tab re-rendering
- The fetch-based refresh pattern enables future WebSocket upgrade for real-time push
