#### Milestone 14: Watchtower UI
Static HTML/CSS/JS dashboard that renders Tekhton pipeline state in a browser.
Four-tab interface: Live Run, Milestone Map, Reports, Trends. Responsive design
for full-screen through corner-of-second-monitor sizes. Auto-refreshes by
reloading the page on a configurable interval. No server, no build tools, no
framework — vanilla HTML/CSS/JS that works by opening index.html in any browser.

This is the final V3 milestone before V4 planning begins.

Files to create (all in `templates/watchtower/`):
- `index.html` — Dashboard shell with tab navigation:
  **Structure:**
  ```html
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="UTF-8">
    <title>Tekhton Watchtower</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="style.css">
  </head>
  <body>
    <header>
      <h1>Watchtower</h1>
      <nav><!-- 4 tabs --></nav>
      <span class="status-indicator"><!-- pipeline status badge --></span>
    </header>
    <main>
      <section id="tab-live" class="tab-content active">...</section>
      <section id="tab-milestones" class="tab-content">...</section>
      <section id="tab-reports" class="tab-content">...</section>
      <section id="tab-trends" class="tab-content">...</section>
    </main>
    <!-- Data files loaded as script tags -->
    <script src="data/run_state.js"></script>
    <script src="data/timeline.js"></script>
    <script src="data/milestones.js"></script>
    <script src="data/security.js"></script>
    <script src="data/reports.js"></script>
    <script src="data/metrics.js"></script>
    <script src="app.js"></script>
  </body>
  </html>
  ```
  **Auto-refresh:** The app.js sets `setTimeout(() => location.reload(),
  TK_RUN_STATE?.refresh_interval_ms || 5000)` when pipeline is running.
  When pipeline is idle/complete, refresh stops (no unnecessary reloads).
  Refresh interval is configurable via DASHBOARD_REFRESH_INTERVAL in pipeline
  config, written into run_state.js by the data layer.

- `style.css` — Dashboard styles:
  **Design language:**
  - Dark theme by default (developer-friendly, second-monitor-friendly).
    Light theme toggle via CSS custom properties (prefers-color-scheme respected).
  - Monospace font for data, sans-serif for labels and navigation.
  - Color palette: neutral grays for chrome, semantic colors for status
    (green=pass/done, amber=in-progress/warning, red=fail/critical,
    blue=info/pending, purple=tweaked/split).
  - Status badges: colored pills with text (e.g., `[PASS]`, `[CRITICAL]`).
  - Cards with subtle borders and shadows for report sections.
  **Responsive breakpoints:**
  - `>=1200px` (full): side-by-side panels, full DAG lanes, all columns visible
  - `>=768px` (medium): stacked panels, condensed DAG, timeline scrollable
  - `<768px` (compact): single column, collapsible sections, essential info only.
    Live Run tab prioritizes: status badge + current stage + timeline.
    Milestone Map degrades to a simple ordered list with status badges.
    Reports show headers only (expand on tap).
    Trends show summary stats only (no charts).
  **Animations:** Minimal. Subtle fade on tab switch. Pulse animation on
  "running" status indicator. No heavy animations — this runs on refresh cycles.

- `app.js` — Dashboard rendering logic (~400-600 lines of vanilla JS):
  **Architecture:**
  - `render()` — Main entry point. Reads TK_* globals, delegates to tab renderers.
  - `renderLiveRun()` — Populates the Live Run tab.
  - `renderMilestoneMap()` — Populates the Milestone Map tab.
  - `renderReports()` — Populates the Reports tab.
  - `renderTrends()` — Populates the Trends tab.
  - `initTabs()` — Tab switching logic. Remembers active tab in localStorage
    so refresh doesn't reset your view.
  - Tab selection persists across refreshes via localStorage.

  **Tab 1: Live Run**
  Layout:
  ```
  ┌─────────────────────────────────────────────────────┐
  │ [●] Pipeline RUNNING — Milestone 3: Indexer Infra   │
  ├─────────────────────────────────────────────────────┤
  │ Stage Progress                                       │
  │ ✓ Intake  ✓ Scout  ✓ Coder  ✓ Build  ● Security  ○ Review  ○ Test │
  │                                        ^^^^^^^^^^^          │
  │                                     12/15 turns  45s       │
  ├─────────────────────────────────────────────────────┤
  │ Timeline                                             │
  │ 10:03  Intake: PASS (confidence 82)                 │
  │ 10:04  Scout: 12 files identified                   │
  │ 10:08  Coder: 6 files modified                      │
  │ 10:09  Build gate: PASS                     [trace] │
  │ 10:10  Security: scanning... (turn 12/15)           │
  └─────────────────────────────────────────────────────┘
  ```
  **Causal trace interaction:** Each timeline event has a `[trace]` link
  (shown on hover at >=768px, always visible at >=1200px). Clicking it
  highlights the event's causal ancestors and descendants in the timeline
  using a colored left-border highlight. The highlight uses CSS classes
  toggled by JS — no separate view, just visual emphasis within the existing
  timeline. This lets users quickly answer "what caused this?" and "what
  did this trigger?" without leaving the Live Run tab.
  When the pipeline has failed, the terminal event's causal chain is
  auto-highlighted on load (no click needed) — the user immediately sees
  the root-cause path.
  When pipeline is paused (NEEDS_CLARITY, security waiver, etc.):
  ```
  ┌─────────────────────────────────────────────────────┐
  │ [⏸] Pipeline WAITING — Human Input Required          │
  ├─────────────────────────────────────────────────────┤
  │ The intake agent needs clarity on Milestone 5:       │
  │                                                      │
  │ Q1: Should the auth system use JWT or session-based? │
  │ Q2: Is the /admin endpoint public or internal-only?  │
  │                                                      │
  │ To respond, edit: .claude/CLARIFICATIONS.md           │
  │ [📋 Copy path to clipboard]                          │
  └─────────────────────────────────────────────────────┘
  ```

  **Tab 2: Milestone Map**
  CSS flexbox swimlanes:
  ```
  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
  │ Pending  │ │  Ready   │ │  Active  │ │   Done   │
  ├──────────┤ ├──────────┤ ├──────────┤ ├──────────┤
  │┌────────┐│ │┌────────┐│ │┌────────┐│ │┌────────┐│
  ││ M05    ││ ││ M04    ││ ││ M03    ││ ││ M01 ✓  ││
  ││ Pipe-  ││ ││ Repo   ││ ││ Indexer││ ││ DAG    ││
  ││ line   ││ ││ Map    ││ ││ Infra  ││ ││ Infra  ││
  ││        ││ ││        ││ ││ ●12min ││ ││        ││
  ││ dep:M04││ ││ dep:M03││ ││        ││ │├────────┤│
  │└────────┘│ │└────────┘│ │└────────┘│ │┌────────┐│
  │┌────────┐│ │          │ │          │ ││ M02 ✓  ││
  ││ M06    ││ │          │ │          │ ││ Sliding││
  ││ Serena ││ │          │ │          │ ││ Window ││
  ││        ││ │          │ │          │ │└────────┘│
  ││dep:M04 ││ │          │ │          │ │          │
  │└────────┘│ │          │ │          │ │          │
  └──────────┘ └──────────┘ └──────────┘ └──────────┘
  ```
  Each card shows: milestone ID, title, dependency badges (dep: M03),
  status indicator, and if active: elapsed time. Click/tap to expand:
  acceptance criteria summary, PM tweaks, security finding count.
  Dependency arrows indicated by `dep:` badges (not SVG lines — V4).
  Cards are color-coded by status (pending=gray, ready=blue, active=amber,
  done=green). Split milestones show `[split from M05]` annotation.

  **Tab 3: Reports**
  Accordion layout — one section per report from the current/last run:
  ```
  ┌─────────────────────────────────────────────────────┐
  │ ▼ Intake Report                        [PASS 82%]  │
  ├─────────────────────────────────────────────────────┤
  │  Verdict: PASS (confidence: 82/100)                 │
  │  No tweaks applied.                                 │
  ├─────────────────────────────────────────────────────┤
  │ ▶ Scout Report                         [12 files]   │
  ├─────────────────────────────────────────────────────┤
  │ ▶ Coder Summary                        [6 modified] │
  ├─────────────────────────────────────────────────────┤
  │ ▼ Security Report                      [1 MEDIUM]   │
  ├─────────────────────────────────────────────────────┤
  │  Findings: 1                                        │
  │  ┌──────────────────────────────────────────────┐   │
  │  │ MEDIUM | A03:Injection | src/api/handler.py:42│  │
  │  │ SQL query uses string interpolation.          │  │
  │  │ Status: logged (not blocking)                 │  │
  │  └──────────────────────────────────────────────┘   │
  ├─────────────────────────────────────────────────────┤
  │ ▶ Reviewer Report                      [APPROVED]   │
  ├─────────────────────────────────────────────────────┤
  │ ▶ Test Results                         [PASS]       │
  └─────────────────────────────────────────────────────┘
  ```
  Each accordion header shows a summary badge (verdict, count, status).
  Expanded view shows parsed report content — NOT raw markdown. Key-value
  pairs, tables for findings, file lists for coder summary.
  When a report hasn't been generated yet (stage pending), show grayed-out
  header with "Pending" badge.

  **Tab 4: Trends**
  Historical metrics from the last DASHBOARD_HISTORY_DEPTH runs:
  ```
  ┌─────────────────────────────────────────────────────┐
  │ Run History (last 50 runs)                          │
  ├─────────────────────────────────────────────────────┤
  │ Efficiency                                          │
  │  Avg turns/run: 42 (↓ from 48 over last 10)        │
  │  Review rejection rate: 15% (↓ from 22%)            │
  │  Split frequency: 8% of milestones                  │
  │  Avg run duration: 12m 34s                          │
  ├─────────────────────────────────────────────────────┤
  │ Per-Stage Breakdown                                 │
  │  Stage     | Avg Turns | Avg Time | Budget Util    │
  │  ─────────┼───────────┼──────────┼────────────     │
  │  Intake   |    4      |   12s    |   40%           │
  │  Scout    |    8      |   34s    |   53%           │
  │  Coder    |   18      |  4m 12s  |   72%           │
  │  Security |   10      |  1m 45s  |   67%           │
  │  Reviewer |    6      |   58s    |   60%           │
  │  Tester   |   12      |  2m 10s  |   80%           │
  ├─────────────────────────────────────────────────────┤
  │ Recent Runs                                         │
  │  #50 | M03 Indexer | 38 turns | 11m | ✓ PASS       │
  │  #49 | M02 Window  | 44 turns | 14m | ✓ PASS       │
  │  #48 | M02 Window  | 52 turns | 18m | ✗ SPLIT      │
  │  #47 | M01 DAG     | 36 turns | 10m | ✓ PASS       │
  │  ...                                                │
  └─────────────────────────────────────────────────────┘
  ```
  At full width: include simple CSS bar charts for turns-per-stage distribution
  (horizontal bars, pure CSS, no charting library). At compact width: tables
  and summary stats only (bars hidden).
  Trend arrows (↑↓) compare last 10 runs against the 10 before that.

Files to modify:
- `lib/dashboard.sh` — Add `_copy_static_files()` helper called by
  `init_dashboard()` to copy templates/watchtower/* to .claude/dashboard/.
  Inject DASHBOARD_REFRESH_INTERVAL into run_state.js as refresh_interval_ms.
- `templates/pipeline.conf.example` — Add commented DASHBOARD_* config section.

Acceptance criteria:
- Opening `.claude/dashboard/index.html` in Chrome, Firefox, Safari, Edge
  displays the 4-tab dashboard with no console errors
- Dashboard loads data from `data/*.js` files via `<script>` tags (no fetch,
  no CORS issues on file:// protocol)
- Auto-refresh reloads the page every DASHBOARD_REFRESH_INTERVAL seconds
  when pipeline is running; stops refreshing when pipeline is idle/complete
- Tab selection persists across refreshes via localStorage
- Live Run tab shows: pipeline status, stage progress bar, current stage
  detail (turns/budget/time), scrollable event timeline with causal trace links
- Timeline events show [trace] interaction: clicking highlights causal
  ancestors and descendants within the timeline via CSS class toggle
- On pipeline failure: terminal event's causal chain is auto-highlighted on load
- Live Run tab shows human-wait banner with instructions when pipeline paused
- Milestone Map tab shows swimlane columns (Pending/Ready/Active/Done) with
  milestone cards, dependency badges, and status colors
- Milestone card expand shows acceptance criteria summary and PM tweaks
- Reports tab shows accordion with one section per stage report, summary
  badges on collapsed headers, parsed (not raw) content when expanded
- Reports for pending stages show grayed-out "Pending" badge
- Security findings displayed as a styled table with severity badges
- Trends tab shows efficiency summary with trend arrows, per-stage breakdown
  table, and recent run history list
- Trends tab shows CSS bar charts at full width, hidden at compact width
- Responsive: 3 breakpoints (>=1200, >=768, <768) with appropriate layout
  changes at each — tested in browser dev tools responsive mode
- Dark theme default, respects prefers-color-scheme, light theme toggle works
- When no data files exist (fresh init, no runs yet): each tab shows a
  friendly empty state message ("No runs yet — run tekhton to see data here")
- When some data files are missing (e.g., security disabled): affected
  sections show "Not enabled" instead of errors
- Zero external dependencies: no CDN links, no npm, no build step
- Total static file size (html + css + js) under 50KB uncompressed
- All existing tests pass
- New test file `tests/test_watchtower_html.sh` validates: HTML syntax
  (via tidy or xmllint if available), no external URL references in static
  files, data file template generates valid JS syntax

Watch For:
- `<script src="data/X.js">` on `file://` protocol: works in Chrome and
  Firefox. Safari may block it with stricter security. Test in Safari and
  document the workaround (--disable-local-file-restrictions or use
  `python3 -m http.server` in the dashboard dir). Add a troubleshooting
  note in the dashboard footer.
- Auto-refresh via location.reload() resets scroll position. Save and restore
  scroll position per tab in localStorage before reload. This is critical for
  the timeline (users scroll through events and don't want to lose position).
- The milestone card expand/collapse state should persist across refreshes
  (localStorage). Otherwise expanding a card to read details gets reset on
  next reload.
- CSS bar charts: use `width: calc(var(--value) / var(--max) * 100%)` pattern.
  Keep it simple — these are directional indicators, not precise visualizations.
- Empty data handling: every render function must gracefully handle undefined
  TK_* globals (data files not yet generated). Use `window.TK_RUN_STATE || {}`
  pattern throughout.
- Tab content should not render until its tab is active (lazy render on tab
  switch). This prevents layout thrashing on load for inactive tabs.
- The 50KB size constraint is intentional. This is a utility dashboard, not
  a web app. If we're approaching the limit, we're overbuilding it. The causal
  trace interaction is lightweight — just CSS class toggling, no graph library.
- Causal trace highlighting: build a simple `caused_by` index on load
  (Map<eventId, Set<parentIds>>). Walking the chain is O(chain_length), not
  O(total_events). Keep it simple — this is visual emphasis, not graph analysis.
- Dark theme colors must have sufficient contrast ratios (WCAG AA minimum).
  Use a contrast checker during development. The causal highlight color must
  be distinct from all status colors (consider a subtle gold/orange left border).

Seeds Forward:
- V4 server-based Watchtower replaces file:// loading with localhost HTTP +
  WebSocket for push updates. The TK_* data format is unchanged.
- V4 adds interactive features: answer clarifications in-browser, approve
  security waivers, trigger manual milestone runs
- V4 DAG visualization upgrades to SVG with a proper graph layout library
- V4/V5 adds metric connectors (DataDog, NewRelic, Prometheus) consuming
  the same structured data from metrics.js
- V4 adds real-time log streaming panel (websocket-based, not file-based)
- The responsive design foundation carries forward to all future versions
