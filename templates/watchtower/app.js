/* Tekhton Watchtower — Dashboard Rendering Logic */
/* eslint-disable no-unused-vars */
(function () {
  'use strict';

  // --- Safe data accessors ---
  var state = function () { return window.TK_RUN_STATE || {}; };
  var timeline = function () { return window.TK_TIMELINE || []; };
  var milestones = function () { return window.TK_MILESTONES || []; };
  var security = function () { return window.TK_SECURITY || {}; };
  var reports = function () { return window.TK_REPORTS || {}; };
  var metrics = function () { return window.TK_METRICS || {}; };
  var health = function () { return window.TK_HEALTH || { available: false }; };

  // --- Causal index (built once on load) ---
  var causalChildren = {};  // eventId -> Set of child eventIds
  var causalParents = {};   // eventId -> Set of parent eventIds

  function buildCausalIndex() {
    var events = timeline();
    causalChildren = {};
    causalParents = {};
    for (var i = 0; i < events.length; i++) {
      var ev = events[i];
      if (!ev || !ev.id) continue;
      if (!causalChildren[ev.id]) causalChildren[ev.id] = [];
      if (!causalParents[ev.id]) causalParents[ev.id] = [];
      if (ev.caused_by) {
        var parents = Array.isArray(ev.caused_by) ? ev.caused_by : [ev.caused_by];
        for (var p = 0; p < parents.length; p++) {
          causalParents[ev.id].push(parents[p]);
          if (!causalChildren[parents[p]]) causalChildren[parents[p]] = [];
          causalChildren[parents[p]].push(ev.id);
        }
      }
    }
  }

  function getCausalChain(eventId) {
    var chain = {};
    // Walk ancestors
    var queue = [eventId];
    while (queue.length) {
      var id = queue.shift();
      if (chain[id]) continue;
      chain[id] = true;
      var ps = causalParents[id] || [];
      for (var i = 0; i < ps.length; i++) queue.push(ps[i]);
    }
    // Walk descendants
    queue = [eventId];
    var visited = {};
    visited[eventId] = true;
    while (queue.length) {
      var cid = queue.shift();
      chain[cid] = true;
      var cs = causalChildren[cid] || [];
      for (var j = 0; j < cs.length; j++) {
        if (!visited[cs[j]]) { visited[cs[j]] = true; queue.push(cs[j]); }
      }
    }
    return chain;
  }

  // --- Utility ---
  function esc(str) {
    if (str == null) return '';
    var d = document.createElement('div');
    d.appendChild(document.createTextNode(String(str)));
    return d.innerHTML;
  }

  function fmtTime(ts) {
    if (!ts) return '';
    try {
      var d = new Date(ts);
      return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    } catch (e) { return String(ts).substring(11, 16); }
  }

  function fmtDuration(secs) {
    if (!secs || secs < 0) return '0s';
    secs = Math.round(secs);
    if (secs < 60) return secs + 's';
    var m = Math.floor(secs / 60);
    var s = secs % 60;
    return m + 'm ' + (s > 0 ? s + 's' : '');
  }

  function statusIcon(s) {
    switch ((s || '').toLowerCase()) {
      case 'done': case 'pass': case 'complete': case 'approved': return '\u2713';
      case 'active': case 'running': case 'in_progress': return '\u25CF';
      case 'failed': case 'fail': case 'critical': return '\u2717';
      default: return '\u25CB';
    }
  }

  function badgeClass(s) {
    return 'badge badge-' + (s || 'pending').toLowerCase().replace(/\s+/g, '_');
  }

  // --- Scroll & state persistence ---
  function saveScrollPositions() {
    var tabs = ['live', 'milestones', 'reports', 'trends'];
    for (var i = 0; i < tabs.length; i++) {
      var el = document.getElementById('tab-' + tabs[i]);
      if (el) {
        try { localStorage.setItem('tk_scroll_' + tabs[i], el.scrollTop); } catch (e) { /* noop */ }
      }
    }
    var tl = document.querySelector('.timeline');
    if (tl) {
      try { localStorage.setItem('tk_scroll_timeline', tl.scrollTop); } catch (e) { /* noop */ }
    }
  }

  function restoreScrollPositions() {
    var tabs = ['live', 'milestones', 'reports', 'trends'];
    for (var i = 0; i < tabs.length; i++) {
      var el = document.getElementById('tab-' + tabs[i]);
      if (el) {
        try {
          var v = localStorage.getItem('tk_scroll_' + tabs[i]);
          if (v) el.scrollTop = parseInt(v, 10);
        } catch (e) { /* noop */ }
      }
    }
    setTimeout(function () {
      var tl = document.querySelector('.timeline');
      if (tl) {
        try {
          var v = localStorage.getItem('tk_scroll_timeline');
          if (v) tl.scrollTop = parseInt(v, 10);
        } catch (e) { /* noop */ }
      }
    }, 50);
  }

  // --- Tab management ---
  var renderedTabs = {};

  function initTabs() {
    var btns = document.querySelectorAll('.tab-btn');
    var saved = null;
    try { saved = localStorage.getItem('tk_active_tab'); } catch (e) { /* noop */ }

    for (var i = 0; i < btns.length; i++) {
      btns[i].addEventListener('click', function () { switchTab(this.dataset.tab); });
    }

    if (saved && document.getElementById('tab-' + saved)) {
      switchTab(saved);
    } else {
      switchTab('live');
    }
  }

  function switchTab(tabId) {
    var btns = document.querySelectorAll('.tab-btn');
    var tabs = document.querySelectorAll('.tab-content');
    for (var i = 0; i < btns.length; i++) {
      btns[i].classList.toggle('active', btns[i].dataset.tab === tabId);
    }
    for (var j = 0; j < tabs.length; j++) {
      tabs[j].classList.toggle('active', tabs[j].id === 'tab-' + tabId);
    }
    try { localStorage.setItem('tk_active_tab', tabId); } catch (e) { /* noop */ }

    // Lazy render
    if (!renderedTabs[tabId]) {
      renderTab(tabId);
      renderedTabs[tabId] = true;
    }
  }

  function renderTab(tabId) {
    switch (tabId) {
      case 'live': renderLiveRun(); break;
      case 'milestones': renderMilestoneMap(); break;
      case 'reports': renderReports(); break;
      case 'trends': renderTrends(); break;
    }
  }

  // --- Theme toggle ---
  function initTheme() {
    var btn = document.getElementById('theme-toggle');
    var saved = null;
    try { saved = localStorage.getItem('tk_theme'); } catch (e) { /* noop */ }
    if (saved) document.documentElement.setAttribute('data-theme', saved);

    if (btn) {
      btn.addEventListener('click', function () {
        var current = document.documentElement.getAttribute('data-theme');
        var next = current === 'light' ? 'dark' : 'light';
        document.documentElement.setAttribute('data-theme', next);
        try { localStorage.setItem('tk_theme', next); } catch (e) { /* noop */ }
      });
    }
  }

  // --- Status indicator ---
  function updateStatusIndicator() {
    var el = document.getElementById('status-indicator');
    if (!el) return;
    var s = state();
    var status = (s.pipeline_status || 'initializing').toLowerCase();
    el.className = 'status-indicator ' + status;
    el.textContent = status.toUpperCase();
  }

  // --- Tab 1: Live Run ---
  function renderLiveRun() {
    var container = document.getElementById('tab-live');
    if (!container) return;
    var s = state();
    var html = '';

    if (!s.pipeline_status || s.pipeline_status === 'initializing') {
      if (!timeline().length) {
        container.innerHTML = '<div class="empty-state">No runs yet \u2014 run tekhton to see data here</div>';
        return;
      }
    }

    var status = (s.pipeline_status || 'idle').toLowerCase();
    var msLabel = '';
    if (s.active_milestone) {
      msLabel = ' \u2014 Milestone ' + esc(s.active_milestone.id) + ': ' + esc(s.active_milestone.title);
    }

    // Status banner
    html += '<div class="live-status-banner ' + esc(status) + '">';
    html += statusIcon(status) + ' Pipeline ' + esc(status.toUpperCase()) + msLabel;
    html += '</div>';

    // Waiting banner
    if (s.waiting_for) {
      html += '<div class="waiting-banner">';
      html += '<h3>\u23F8 Pipeline WAITING \u2014 Human Input Required</h3>';
      html += '<p>' + esc(s.waiting_for) + '</p>';
      html += '<p>To respond, edit: <code>.claude/CLARIFICATIONS.md</code></p>';
      html += '</div>';
    }

    // Stage progress bar
    var stages = s.stages || {};
    var stageOrder = ['intake', 'scout', 'coder', 'build_gate', 'security', 'reviewer', 'tester'];
    var stageLabels = { intake: 'Intake', scout: 'Scout', coder: 'Coder', build_gate: 'Build', security: 'Security', reviewer: 'Review', tester: 'Test' };
    html += '<div class="stage-progress">';
    for (var i = 0; i < stageOrder.length; i++) {
      var sn = stageOrder[i];
      var si = stages[sn] || {};
      var ss = (si.status || 'pending').toLowerCase();
      html += '<span class="stage-chip ' + esc(ss) + '">';
      html += statusIcon(ss) + ' ' + (stageLabels[sn] || sn);
      html += '</span>';
    }
    html += '</div>';

    // Current stage detail
    var cs = s.current_stage;
    if (cs && stages[cs]) {
      var csd = stages[cs];
      html += '<div class="stage-detail">';
      html += esc(stageLabels[cs] || cs) + ': ';
      html += esc(csd.turns || 0) + '/' + esc(csd.budget || '?') + ' turns';
      if (csd.duration_s) html += '  \u00B7  ' + fmtDuration(csd.duration_s);
      html += '</div>';
    }

    // Timeline
    var events = timeline();
    if (events.length) {
      html += '<div class="timeline" id="timeline-scroll">';
      for (var j = 0; j < events.length; j++) {
        var ev = events[j];
        if (!ev) continue;
        var evId = ev.id || '';
        var evType = ev.type || '';
        var evDetail = ev.detail || ev.type || '';
        if (typeof evDetail === 'object') evDetail = JSON.stringify(evDetail);
        html += '<div class="timeline-event" data-event-id="' + esc(evId) + '">';
        html += '<span class="time">' + fmtTime(ev.ts) + '</span>';
        html += '<span class="detail">' + esc(evType) + ': ' + esc(evDetail) + '</span>';
        if (evId) {
          html += '<span class="trace-link" data-trace="' + esc(evId) + '">[trace]</span>';
        }
        html += '</div>';
      }
      html += '</div>';
    }

    container.innerHTML = html;

    // Attach trace click handlers
    var traceLinks = container.querySelectorAll('.trace-link');
    for (var k = 0; k < traceLinks.length; k++) {
      traceLinks[k].addEventListener('click', function (e) {
        e.stopPropagation();
        toggleCausalHighlight(this.dataset.trace);
      });
    }

    // Auto-highlight causal chain on failure
    if (status === 'failed' && events.length) {
      var lastEvent = events[events.length - 1];
      if (lastEvent && lastEvent.id) {
        toggleCausalHighlight(lastEvent.id);
      }
    }
  }

  var activeTrace = null;
  function toggleCausalHighlight(eventId) {
    var allEvents = document.querySelectorAll('.timeline-event');
    if (activeTrace === eventId) {
      // Clear
      for (var i = 0; i < allEvents.length; i++) {
        allEvents[i].classList.remove('causal-highlight');
      }
      activeTrace = null;
      return;
    }
    activeTrace = eventId;
    var chain = getCausalChain(eventId);
    for (var j = 0; j < allEvents.length; j++) {
      var eid = allEvents[j].dataset.eventId || '';
      allEvents[j].classList.toggle('causal-highlight', !!chain[eid]);
    }
  }

  // --- Tab 2: Milestone Map ---
  function renderMilestoneMap() {
    var container = document.getElementById('tab-milestones');
    if (!container) return;
    var ms = milestones();

    if (!ms.length) {
      container.innerHTML = '<div class="empty-state">No milestones yet \u2014 run tekhton to see data here</div>';
      return;
    }

    var s = state();
    var activeMsId = s.active_milestone ? s.active_milestone.id : null;

    // Classify milestones into lanes
    var lanes = { done: [], active: [], ready: [], pending: [] };
    var doneSet = {};
    for (var i = 0; i < ms.length; i++) {
      if ((ms[i].status || '').toLowerCase() === 'done') doneSet[ms[i].id] = true;
    }

    for (var j = 0; j < ms.length; j++) {
      var m = ms[j];
      var st = (m.status || 'pending').toLowerCase();
      if (st === 'done') {
        lanes.done.push(m);
      } else if (st === 'in_progress' || st === 'active' || m.id === activeMsId) {
        lanes.active.push(m);
      } else if (depsAllDone(m, doneSet)) {
        lanes.ready.push(m);
      } else {
        lanes.pending.push(m);
      }
    }

    // Load expanded state
    var expandedCards = {};
    try {
      var saved = localStorage.getItem('tk_ms_expanded');
      if (saved) expandedCards = JSON.parse(saved);
    } catch (e) { /* noop */ }

    var html = '<div class="swimlanes">';
    var laneOrder = [
      { key: 'pending', label: 'Pending' },
      { key: 'ready', label: 'Ready' },
      { key: 'active', label: 'Active' },
      { key: 'done', label: 'Done' }
    ];

    for (var l = 0; l < laneOrder.length; l++) {
      var lane = laneOrder[l];
      var items = lanes[lane.key];
      html += '<div class="swimlane">';
      html += '<div class="swimlane-header">' + lane.label + ' (' + items.length + ')</div>';
      for (var n = 0; n < items.length; n++) {
        var mi = items[n];
        var expanded = expandedCards[mi.id] ? ' expanded' : '';
        var statusClass = 'status-' + (mi.status || 'pending').toLowerCase();
        html += '<div class="ms-card ' + statusClass + expanded + '" data-ms-id="' + esc(mi.id) + '">';
        html += '<span class="ms-id">' + esc(mi.id) + '</span>';
        if (mi.status === 'done') html += ' <span class="badge badge-done">\u2713</span>';
        html += '<div class="ms-title">' + esc(mi.title) + '</div>';
        if (mi.depends_on) {
          html += '<div class="ms-deps">';
          var deps = mi.depends_on.split(',');
          for (var d = 0; d < deps.length; d++) {
            var dep = deps[d].trim();
            if (dep) html += '<span class="dep-badge">dep:' + esc(dep) + '</span>';
          }
          html += '</div>';
        }
        html += '<div class="ms-expanded">';
        html += '<div>Status: ' + esc(mi.status || 'pending') + '</div>';
        if (mi.parallel_group) html += '<div>Group: ' + esc(mi.parallel_group) + '</div>';
        html += '</div>';
        html += '</div>';
      }
      html += '</div>';
    }
    html += '</div>';

    container.innerHTML = html;

    // Attach card expand handlers
    var cards = container.querySelectorAll('.ms-card');
    for (var c = 0; c < cards.length; c++) {
      cards[c].addEventListener('click', function () {
        this.classList.toggle('expanded');
        persistMsExpanded();
      });
    }
  }

  function depsAllDone(m, doneSet) {
    if (!m.depends_on) return true;
    var deps = m.depends_on.split(',');
    for (var i = 0; i < deps.length; i++) {
      var d = deps[i].trim();
      if (d && !doneSet[d]) return false;
    }
    return true;
  }

  function persistMsExpanded() {
    var expanded = {};
    var cards = document.querySelectorAll('.ms-card.expanded');
    for (var i = 0; i < cards.length; i++) {
      expanded[cards[i].dataset.msId] = true;
    }
    try { localStorage.setItem('tk_ms_expanded', JSON.stringify(expanded)); } catch (e) { /* noop */ }
  }

  // --- Tab 3: Reports ---
  function renderReports() {
    var container = document.getElementById('tab-reports');
    if (!container) return;
    var r = reports();
    var sec = security();

    var sections = [
      { key: 'intake', label: 'Intake Report', render: renderIntakeBody },
      { key: 'coder', label: 'Coder Summary', render: renderCoderBody },
      { key: 'security', label: 'Security Report', render: renderSecurityBody },
      { key: 'reviewer', label: 'Reviewer Report', render: renderReviewerBody }
    ];

    var hasAny = false;
    for (var i = 0; i < sections.length; i++) {
      var s = sections[i];
      if (s.key === 'security' && sec.findings && sec.findings.length) { hasAny = true; break; }
      if (r[s.key] && r[s.key] !== null) { hasAny = true; break; }
    }

    if (!hasAny && (!sec.findings || !sec.findings.length)) {
      container.innerHTML = '<div class="empty-state">No reports yet \u2014 run tekhton to see data here</div>';
      return;
    }

    // Load accordion state
    var openState = {};
    try {
      var saved = localStorage.getItem('tk_reports_open');
      if (saved) openState = JSON.parse(saved);
    } catch (e) { /* noop */ }

    var html = '';
    for (var j = 0; j < sections.length; j++) {
      var sect = sections[j];
      var data = sect.key === 'security' ? sec : r[sect.key];
      var isPending = !data || data === null;
      var badge = '';
      var open = openState[sect.key] ? ' open' : '';
      var disabled = isPending ? ' disabled' : '';

      if (isPending) {
        badge = '<span class="badge badge-pending">Pending</span>';
      } else {
        badge = getSectionBadge(sect.key, data);
      }

      html += '<div class="accordion-item' + open + disabled + '" data-section="' + sect.key + '">';
      html += '<div class="accordion-header">';
      html += '<span class="arrow">\u25B6</span>';
      html += '<span class="title">' + esc(sect.label) + '</span>';
      html += badge;
      html += '</div>';
      html += '<div class="accordion-body">';
      if (isPending) {
        html += '<em>Pending</em>';
      } else {
        html += sect.render(data);
      }
      html += '</div></div>';
    }

    container.innerHTML = html;

    // Attach accordion handlers
    var headers = container.querySelectorAll('.accordion-header');
    for (var h = 0; h < headers.length; h++) {
      headers[h].addEventListener('click', function () {
        var item = this.parentElement;
        if (item.classList.contains('disabled')) return;
        item.classList.toggle('open');
        persistReportState();
      });
    }
  }

  function getSectionBadge(key, data) {
    switch (key) {
      case 'intake':
        if (data.verdict) return '<span class="' + badgeClass(data.verdict) + '">' + esc(data.verdict) + (data.confidence ? ' ' + data.confidence + '%' : '') + '</span>';
        return '';
      case 'coder':
        if (data.files_modified != null) return '<span class="badge badge-info">' + data.files_modified + ' modified</span>';
        return '';
      case 'security':
        var f = (data.findings || []);
        if (!f.length) return '<span class="badge badge-pass">Clean</span>';
        var maxSev = 'LOW';
        for (var i = 0; i < f.length; i++) {
          var s = (f[i].severity || '').toUpperCase();
          if (s === 'CRITICAL' || s === 'HIGH') { maxSev = s; break; }
          if (s === 'MEDIUM') maxSev = 'MEDIUM';
        }
        return '<span class="' + badgeClass(maxSev) + '">' + f.length + ' ' + maxSev + '</span>';
      case 'reviewer':
        if (data.verdict) return '<span class="' + badgeClass(data.verdict) + '">' + esc(data.verdict) + '</span>';
        return '';
      default: return '';
    }
  }

  function renderIntakeBody(data) {
    var html = '<div class="stat-row"><span class="stat-label">Verdict:</span><span class="stat-value">' + esc(data.verdict || 'unknown') + '</span></div>';
    html += '<div class="stat-row"><span class="stat-label">Confidence:</span><span class="stat-value">' + esc(data.confidence || 0) + '/100</span></div>';
    return html;
  }

  function renderCoderBody(data) {
    var html = '<div class="stat-row"><span class="stat-label">Status:</span><span class="stat-value">' + esc(data.status || 'unknown') + '</span></div>';
    html += '<div class="stat-row"><span class="stat-label">Files modified:</span><span class="stat-value">' + esc(data.files_modified || 0) + '</span></div>';
    return html;
  }

  function renderSecurityBody(data) {
    var findings = data.findings || [];
    if (!findings.length) return '<em>No findings</em>';
    var html = '<table class="findings-table"><thead><tr><th>Severity</th><th>Category</th><th>Detail</th></tr></thead><tbody>';
    for (var i = 0; i < findings.length; i++) {
      var f = findings[i];
      html += '<tr>';
      html += '<td><span class="' + badgeClass(f.severity) + '">' + esc(f.severity) + '</span></td>';
      html += '<td>' + esc(f.category || '-') + '</td>';
      html += '<td>' + esc(f.detail || '') + '</td>';
      html += '</tr>';
    }
    html += '</tbody></table>';
    return html;
  }

  function renderReviewerBody(data) {
    return '<div class="stat-row"><span class="stat-label">Verdict:</span><span class="stat-value">' + esc(data.verdict || 'unknown') + '</span></div>';
  }

  function persistReportState() {
    var open = {};
    var items = document.querySelectorAll('.accordion-item.open');
    for (var i = 0; i < items.length; i++) {
      open[items[i].dataset.section] = true;
    }
    try { localStorage.setItem('tk_reports_open', JSON.stringify(open)); } catch (e) { /* noop */ }
  }

  // --- Tab 4: Trends ---
  function renderTrends() {
    var container = document.getElementById('tab-trends');
    if (!container) return;
    var m = metrics();
    var runs = m.runs || [];

    if (!runs.length) {
      container.innerHTML = '<div class="empty-state">No runs yet \u2014 run tekhton to see data here</div>';
      return;
    }

    var html = '<div class="trends-grid">';

    // Efficiency summary
    html += '<div class="card trend-section">';
    html += '<h3>Efficiency</h3>';
    var totalTurns = 0, totalTime = 0, splitCount = 0, rejectCount = 0;
    for (var i = 0; i < runs.length; i++) {
      totalTurns += (runs[i].total_turns || 0);
      totalTime += (runs[i].total_time_s || 0);
      if ((runs[i].outcome || '').toLowerCase() === 'split') splitCount++;
      if ((runs[i].outcome || '').toLowerCase() === 'rejected') rejectCount++;
    }
    var avgTurns = runs.length ? Math.round(totalTurns / runs.length) : 0;
    var avgTime = runs.length ? Math.round(totalTime / runs.length) : 0;
    var rejectRate = runs.length ? Math.round((rejectCount / runs.length) * 100) : 0;
    var splitRate = runs.length ? Math.round((splitCount / runs.length) * 100) : 0;

    // Trend arrows (last 10 vs prior 10)
    var turnsArrow = trendArrow(runs, 'total_turns');
    var timeArrow = trendArrow(runs, 'total_time_s');

    html += '<div class="stat-row"><span class="stat-label">Avg turns/run</span><span class="stat-value">' + avgTurns + turnsArrow + '</span></div>';
    html += '<div class="stat-row"><span class="stat-label">Avg run duration</span><span class="stat-value">' + fmtDuration(avgTime) + timeArrow + '</span></div>';
    html += '<div class="stat-row"><span class="stat-label">Review rejection rate</span><span class="stat-value">' + rejectRate + '%</span></div>';
    html += '<div class="stat-row"><span class="stat-label">Split frequency</span><span class="stat-value">' + splitRate + '%</span></div>';
    html += '</div>';

    // Health score card (Milestone 15)
    html += renderHealthCard();

    // Per-stage breakdown
    html += '<div class="card trend-section">';
    html += '<h3>Per-Stage Breakdown</h3>';
    html += renderStageBreakdown(runs);
    html += '</div>';

    html += '</div>'; // end trends-grid

    // Recent runs
    html += '<div class="card trend-section" style="margin-top:0.75rem">';
    html += '<h3>Recent Runs (last ' + runs.length + ')</h3>';
    html += '<ul class="run-list">';
    for (var r = 0; r < runs.length; r++) {
      var run = runs[r];
      var outcomeIcon = (run.outcome || '').toLowerCase() === 'pass' || (run.outcome || '').toLowerCase() === 'success' ? '\u2713' : '\u2717';
      html += '<li>';
      html += '<span class="run-num">#' + (runs.length - r) + '</span>';
      html += '<span class="run-milestone">' + esc(run.milestone || '-') + '</span>';
      html += '<span class="run-turns">' + (run.total_turns || 0) + ' turns</span>';
      html += '<span class="run-time">' + fmtDuration(run.total_time_s || 0) + '</span>';
      html += '<span class="' + badgeClass(run.outcome) + '">' + outcomeIcon + ' ' + esc(run.outcome || 'unknown') + '</span>';
      html += '</li>';
    }
    html += '</ul></div>';

    container.innerHTML = html;
  }

  function renderHealthCard() {
    var h = health();
    if (!h.available) return '';

    var data = h.data || {};
    var composite = data.composite || 0;
    var belt = h.belt || '';
    var dims = data.dimensions || {};
    var prevComposite = data.previous_composite;
    var delta = data.delta;

    var html = '<div class="card trend-section">';
    html += '<h3>Project Health</h3>';

    // Composite score with belt badge
    var scoreClass = composite >= 75 ? 'health-good' : composite >= 40 ? 'health-ok' : 'health-low';
    html += '<div class="health-composite ' + scoreClass + '">';
    html += '<span class="health-score">' + composite + '/100</span>';
    if (belt) html += '<span class="health-belt">' + esc(belt) + '</span>';
    if (typeof delta === 'number' && typeof prevComposite === 'number') {
      var arrow = delta > 0 ? '\u2191' : delta < 0 ? '\u2193' : '\u2192';
      var deltaClass = delta > 0 ? 'trend-arrow down' : delta < 0 ? 'trend-arrow up' : 'trend-arrow neutral';
      html += '<span class="' + deltaClass + '">' + arrow + ' ' + (delta > 0 ? '+' : '') + delta + '</span>';
    }
    html += '</div>';

    // Per-dimension bar chart
    var dimNames = ['test_health', 'code_quality', 'dependency_health', 'doc_quality', 'project_hygiene'];
    var dimLabels = { test_health: 'Tests', code_quality: 'Quality', dependency_health: 'Dependencies', doc_quality: 'Documentation', project_hygiene: 'Hygiene' };

    html += '<div class="health-dimensions">';
    for (var i = 0; i < dimNames.length; i++) {
      var dim = dims[dimNames[i]] || {};
      var score = dim.score || 0;
      var weight = dim.weight || 0;
      var dimDelta = dim.delta;
      var barClass = score >= 75 ? 'bar-good' : score >= 40 ? 'bar-ok' : 'bar-low';

      html += '<div class="health-dim-row">';
      html += '<span class="health-dim-label">' + (dimLabels[dimNames[i]] || dimNames[i]) + ' (' + weight + '%)</span>';
      html += '<div class="health-bar-container"><div class="health-bar ' + barClass + '" style="width:' + score + '%"></div></div>';
      html += '<span class="health-dim-score">' + score + '</span>';
      if (typeof dimDelta === 'number' && dimDelta !== 0) {
        var dArrow = dimDelta > 0 ? '\u2191' : '\u2193';
        html += '<span class="health-dim-delta">' + dArrow + (dimDelta > 0 ? '+' : '') + dimDelta + '</span>';
      }
      html += '</div>';
    }
    html += '</div>';
    html += '</div>';
    return html;
  }

  function trendArrow(runs, field) {
    if (runs.length < 20) return '';
    // Assumes runs[] is sorted newest-first (as emitted by dashboard_parsers.sh).
    // recent = runs[0..9], prior = runs[10..19].
    var recent = runs.slice(0, 10);
    var prior = runs.slice(10, 20);
    var recentAvg = 0, priorAvg = 0;
    for (var i = 0; i < recent.length; i++) recentAvg += (recent[i][field] || 0);
    for (var j = 0; j < prior.length; j++) priorAvg += (prior[j][field] || 0);
    recentAvg /= recent.length;
    priorAvg /= prior.length;
    var diff = recentAvg - priorAvg;
    var pct = priorAvg ? Math.abs(Math.round((diff / priorAvg) * 100)) : 0;
    if (pct < 5) return '<span class="trend-arrow neutral">\u2192</span>';
    if (diff < 0) return '<span class="trend-arrow down">\u2193</span>';
    return '<span class="trend-arrow up">\u2191</span>';
  }

  function renderStageBreakdown(runs) {
    var stageNames = ['intake', 'scout', 'coder', 'build_gate', 'security', 'reviewer', 'tester'];
    var stageLabels = { intake: 'Intake', scout: 'Scout', coder: 'Coder', build_gate: 'Build', security: 'Security', reviewer: 'Reviewer', tester: 'Tester' };
    var stageTotals = {};
    var stageCount = {};

    for (var i = 0; i < stageNames.length; i++) {
      stageTotals[stageNames[i]] = { turns: 0, time: 0, budget: 0 };
      stageCount[stageNames[i]] = 0;
    }

    for (var r = 0; r < runs.length; r++) {
      var stages = runs[r].stages || {};
      for (var s = 0; s < stageNames.length; s++) {
        var sn = stageNames[s];
        var sd = stages[sn];
        if (sd) {
          stageTotals[sn].turns += (sd.turns || 0);
          stageTotals[sn].time += (sd.duration_s || 0);
          if (sd.budget > 0) stageTotals[sn].budget += Math.round(((sd.turns || 0) / sd.budget) * 100);
          stageCount[sn]++;
        }
      }
    }

    var maxAvgTurns = 1;
    for (var t = 0; t < stageNames.length; t++) {
      var avg = stageCount[stageNames[t]] ? stageTotals[stageNames[t]].turns / stageCount[stageNames[t]] : 0;
      if (avg > maxAvgTurns) maxAvgTurns = avg;
    }

    var html = '<table class="breakdown-table"><thead><tr><th>Stage</th><th>Avg Turns</th><th>Avg Time</th><th>Budget Util</th><th class="bar-chart-cell">Distribution</th></tr></thead><tbody>';
    for (var b = 0; b < stageNames.length; b++) {
      var sn2 = stageNames[b];
      var cnt = stageCount[sn2] || 1;
      var avgT = Math.round(stageTotals[sn2].turns / cnt);
      var avgTm = fmtDuration(Math.round(stageTotals[sn2].time / cnt));
      var budgetUtil = Math.round(stageTotals[sn2].budget / cnt);
      var barPct = Math.round((avgT / maxAvgTurns) * 100);

      html += '<tr>';
      html += '<td>' + (stageLabels[sn2] || sn2) + '</td>';
      html += '<td>' + avgT + '</td>';
      html += '<td>' + avgTm + '</td>';
      html += '<td>' + budgetUtil + '%</td>';
      html += '<td class="bar-chart-cell"><div class="bar-wrap"><div class="bar-fill" style="width:' + barPct + '%"></div></div></td>';
      html += '</tr>';
    }
    html += '</tbody></table>';
    return html;
  }

  // --- Auto-refresh ---
  function scheduleRefresh() {
    var s = state();
    var status = (s.pipeline_status || '').toLowerCase();
    if (status === 'running' || status === 'initializing') {
      var interval = s.refresh_interval_ms || 5000;
      saveScrollPositions();
      setTimeout(function () { location.reload(); }, interval);
    }
  }

  // --- Main render ---
  function render() {
    buildCausalIndex();
    updateStatusIndicator();
    initTheme();
    initTabs();
    restoreScrollPositions();
    scheduleRefresh();
  }

  // Boot
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', render);
  } else {
    render();
  }
})();
