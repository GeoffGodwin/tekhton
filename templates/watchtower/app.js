/* Tekhton Watchtower — Dashboard Rendering Logic */
/* eslint-disable no-unused-vars */
(function () {
  'use strict';
  var state = function () { return window.TK_RUN_STATE || {}; };
  var timeline = function () { return window.TK_TIMELINE || []; };
  var milestones = function () { return window.TK_MILESTONES || []; };
  var security = function () { return window.TK_SECURITY || {}; };
  var reports = function () { return window.TK_REPORTS || {}; };
  var metrics = function () { return window.TK_METRICS || {}; };
  var health = function () { return window.TK_HEALTH || { available: false }; };
  var inbox = function () { return window.TK_INBOX || { items: [] }; };

  var causalChildren = {}, causalParents = {};
  function buildCausalIndex() {
    var ev, events = timeline(), p, parents;
    causalChildren = {}; causalParents = {};
    for (var i = 0; i < events.length; i++) {
      ev = events[i];
      if (!ev || !ev.id) continue;
      if (!causalChildren[ev.id]) causalChildren[ev.id] = [];
      if (!causalParents[ev.id]) causalParents[ev.id] = [];
      if (ev.caused_by) {
        parents = Array.isArray(ev.caused_by) ? ev.caused_by : [ev.caused_by];
        for (p = 0; p < parents.length; p++) {
          causalParents[ev.id].push(parents[p]);
          if (!causalChildren[parents[p]]) causalChildren[parents[p]] = [];
          causalChildren[parents[p]].push(ev.id);
        }
      }
    }
  }
  function getCausalChain(eventId) {
    var chain = {}, queue = [eventId], id, cs, ps;
    while (queue.length) {
      id = queue.shift();
      if (chain[id]) continue;
      chain[id] = true;
      ps = causalParents[id] || [];
      for (var i = 0; i < ps.length; i++) queue.push(ps[i]);
    }
    queue = [eventId]; var visited = {}; visited[eventId] = true;
    while (queue.length) {
      id = queue.shift(); chain[id] = true;
      cs = causalChildren[id] || [];
      for (var j = 0; j < cs.length; j++) {
        if (!visited[cs[j]]) { visited[cs[j]] = true; queue.push(cs[j]); }
      }
    }
    return chain;
  }
  function esc(str) {
    if (str == null) return '';
    var d = document.createElement('div');
    d.appendChild(document.createTextNode(String(str)));
    return d.innerHTML;
  }
  function fmtTime(ts) {
    if (!ts) return '';
    try { return new Date(ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); }
    catch (e) { return String(ts).substring(11, 16); }
  }
  function fmtDuration(secs) {
    if (!secs || secs < 0) return '0s';
    secs = Math.round(secs);
    if (secs < 60) return secs + 's';
    var m = Math.floor(secs / 60), s = secs % 60;
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
  function badgeClass(s) { return 'badge badge-' + (s || 'pending').toLowerCase().replace(/\s+/g, '_'); }
  function truncate(str, max) {
    if (!str) return '';
    return str.length <= max ? str : str.substring(0, max - 1) + '\u2026';
  }

  function initTabs() {
    var btns = document.querySelectorAll('.tab-btn'), saved = null;
    try { saved = localStorage.getItem('tk_active_tab'); } catch (e) { /* noop */ }
    for (var i = 0; i < btns.length; i++)
      btns[i].addEventListener('click', function () { switchTab(this.dataset.tab); });
    switchTab(saved && document.getElementById('tab-' + saved) ? saved : 'live');
  }
  function switchTab(tabId) {
    var btns = document.querySelectorAll('.tab-btn'), tabs = document.querySelectorAll('.tab-content');
    for (var i = 0; i < btns.length; i++) btns[i].classList.toggle('active', btns[i].dataset.tab === tabId);
    for (var j = 0; j < tabs.length; j++) tabs[j].classList.toggle('active', tabs[j].id === 'tab-' + tabId);
    try { localStorage.setItem('tk_active_tab', tabId); } catch (e) { /* noop */ }
    renderTab(tabId);
  }
  function getActiveTab() {
    try { return localStorage.getItem('tk_active_tab') || 'live'; } catch (e) { return 'live'; }
  }
  function renderActiveTab() {
    renderTab(getActiveTab());
  }
  function renderTab(tabId) {
    switch (tabId) {
      case 'live': renderLiveRun(); break;
      case 'milestones': renderMilestoneMap(); break;
      case 'reports': renderReports(); break;
      case 'trends': renderTrends(); break;
      case 'actions': renderActions(); break;
    }
  }
  function initTheme() {
    var btn = document.getElementById('theme-toggle'), saved = null;
    try { saved = localStorage.getItem('tk_theme'); } catch (e) { /* noop */ }
    if (saved) document.documentElement.setAttribute('data-theme', saved);
    if (btn) btn.addEventListener('click', function () {
      var cur = document.documentElement.getAttribute('data-theme');
      var next = cur === 'light' ? 'dark' : 'light';
      document.documentElement.setAttribute('data-theme', next);
      try { localStorage.setItem('tk_theme', next); } catch (e) { /* noop */ }
    });
  }
  function updateStatusIndicator() {
    var el = document.getElementById('status-indicator');
    if (!el) return;
    var status = (state().pipeline_status || 'initializing').toLowerCase();
    el.className = 'status-indicator ' + status;
    el.textContent = status.toUpperCase();
  }
  function updateRefreshIndicator(stopped) {
    var el = document.getElementById('refresh-indicator');
    if (!el) return;
    el.textContent = stopped ? 'Pipeline completed \u2014 refresh stopped' : '';
    el.style.display = stopped ? 'inline' : 'none';
  }

  // --- Tab 1: Live Run ---
  var stageOrder = ['intake', 'scout', 'coder', 'build_gate', 'security', 'reviewer', 'tester'];
  var stageLabels = { intake: 'Intake', scout: 'Scout', coder: 'Coder', build_gate: 'Build', security: 'Security', reviewer: 'Review', tester: 'Test' };

  function renderLiveRun() {
    var c = document.getElementById('tab-live');
    if (!c) return;
    var s = state(), h = '';
    if ((!s.pipeline_status || s.pipeline_status === 'initializing') && !timeline().length) {
      c.innerHTML = '<div class="empty-state">No runs yet \u2014 run tekhton to see data here</div>'; return;
    }
    var st = (s.pipeline_status || 'idle').toLowerCase();
    var ml = s.active_milestone ? ' \u2014 Milestone ' + esc(s.active_milestone.id) + ': ' + esc(s.active_milestone.title) : '';
    h += '<div class="live-status-banner ' + esc(st) + '">' + statusIcon(st) + ' Pipeline ' + esc(st.toUpperCase()) + ml + '</div>';
    if (s.waiting_for)
      h += '<div class="waiting-banner"><h3>\u23F8 Pipeline WAITING \u2014 Human Input Required</h3><p>' + esc(s.waiting_for) + '</p><p>To respond, edit: <code>.claude/CLARIFICATIONS.md</code></p></div>';
    var stgs = s.stages || {};
    h += '<div class="stage-progress">';
    for (var i = 0; i < stageOrder.length; i++) {
      var si = stgs[stageOrder[i]] || {}, ss = (si.status || 'pending').toLowerCase();
      h += '<span class="stage-chip ' + esc(ss) + '">' + statusIcon(ss) + ' ' + (stageLabels[stageOrder[i]] || stageOrder[i]) + '</span>';
    }
    h += '</div>';
    if (s.current_stage && stgs[s.current_stage]) {
      var d = stgs[s.current_stage];
      h += '<div class="stage-detail">' + esc(stageLabels[s.current_stage] || s.current_stage) + ': ' + esc(d.turns || 0) + '/' + esc(d.budget || '?') + ' turns';
      if (d.duration_s) h += '  \u00B7  ' + fmtDuration(d.duration_s);
      h += '</div>';
    }
    var ev, events = timeline();
    if (events.length) {
      h += '<div class="timeline" id="timeline-scroll">';
      for (var j = 0; j < events.length; j++) {
        ev = events[j]; if (!ev) continue;
        var eid = ev.id || '', det = ev.detail || ev.type || '';
        if (typeof det === 'object') det = JSON.stringify(det);
        h += '<div class="timeline-event" data-event-id="' + esc(eid) + '"><span class="time">' + fmtTime(ev.ts) + '</span><span class="detail">' + esc(ev.type || '') + ': ' + esc(det) + '</span>';
        if (eid) h += '<span class="trace-link" data-trace="' + esc(eid) + '">[trace]</span>';
        h += '</div>';
      }
      h += '</div>';
    }
    c.innerHTML = h;
    var tl = c.querySelectorAll('.trace-link');
    for (var k = 0; k < tl.length; k++)
      tl[k].addEventListener('click', function (e) { e.stopPropagation(); toggleCausalHighlight(this.dataset.trace); });
    if (st === 'failed' && events.length) { var last = events[events.length - 1]; if (last && last.id) toggleCausalHighlight(last.id); }
  }
  var activeTrace = null;
  function toggleCausalHighlight(eventId) {
    var allEvents = document.querySelectorAll('.timeline-event');
    if (activeTrace === eventId) {
      for (var i = 0; i < allEvents.length; i++) allEvents[i].classList.remove('causal-highlight');
      activeTrace = null; return;
    }
    activeTrace = eventId;
    var chain = getCausalChain(eventId);
    for (var j = 0; j < allEvents.length; j++) allEvents[j].classList.toggle('causal-highlight', !!chain[allEvents[j].dataset.eventId || '']);
  }

  // --- Tab 2: Milestone Map ---
  function renderMilestoneMap() {
    var ct = document.getElementById('tab-milestones');
    if (!ct) return;
    var ms = milestones();
    if (!ms.length) { ct.innerHTML = '<div class="empty-state">No milestones yet \u2014 run tekhton to see data here</div>'; return; }
    var aId = (state().active_milestone || {}).id, lanes = { done: [], active: [], ready: [], pending: [] }, ds = {}, m, st;
    for (var i = 0; i < ms.length; i++) if ((ms[i].status || '').toLowerCase() === 'done') ds[ms[i].id] = true;
    for (var j = 0; j < ms.length; j++) {
      m = ms[j]; st = (m.status || 'pending').toLowerCase();
      if (st === 'done') lanes.done.push(m);
      else if (st === 'in_progress' || st === 'active' || m.id === aId) lanes.active.push(m);
      else if (depsAllDone(m, ds)) lanes.ready.push(m);
      else lanes.pending.push(m);
    }
    var ec = {};
    try { var sv = localStorage.getItem('tk_ms_expanded'); if (sv) ec = JSON.parse(sv); } catch (e) { /* noop */ }
    var h = '<div class="swimlanes">', lo = [['pending','Pending'],['ready','Ready'],['active','Active'],['done','Done']];
    for (var l = 0; l < lo.length; l++) {
      var items = lanes[lo[l][0]];
      h += '<div class="swimlane"><div class="swimlane-header">' + lo[l][1] + ' (' + items.length + ')</div>';
      for (var n = 0; n < items.length; n++) {
        var mi = items[n];
        h += '<div class="ms-card status-' + (mi.status || 'pending').toLowerCase() + (ec[mi.id] ? ' expanded' : '') + '" data-ms-id="' + esc(mi.id) + '"><span class="ms-id">' + esc(mi.id) + '</span>';
        if (mi.status === 'done') h += ' <span class="badge badge-done">\u2713</span>';
        h += '<div class="ms-title">' + esc(mi.title) + '</div>';
        if (mi.depends_on) {
          h += '<div class="ms-deps">';
          var deps = mi.depends_on.split(',');
          for (var d = 0; d < deps.length; d++) { var dp = deps[d].trim(); if (dp) h += '<span class="dep-badge">dep:' + esc(dp) + '</span>'; }
          h += '</div>';
        }
        h += '<div class="ms-expanded"><div>Status: ' + esc(mi.status || 'pending') + '</div>';
        if (mi.parallel_group) h += '<div>Group: ' + esc(mi.parallel_group) + '</div>';
        h += '</div></div>';
      }
      h += '</div>';
    }
    h += '</div>';
    ct.innerHTML = h;
    var cards = ct.querySelectorAll('.ms-card');
    for (var c = 0; c < cards.length; c++) cards[c].addEventListener('click', function () { this.classList.toggle('expanded'); persistMsExpanded(); });
  }
  function depsAllDone(m, doneSet) {
    if (!m.depends_on) return true;
    var deps = m.depends_on.split(',');
    for (var i = 0; i < deps.length; i++) { var d = deps[i].trim(); if (d && !doneSet[d]) return false; }
    return true;
  }
  function persistMsExpanded() {
    var expanded = {}, cards = document.querySelectorAll('.ms-card.expanded');
    for (var i = 0; i < cards.length; i++) expanded[cards[i].dataset.msId] = true;
    try { localStorage.setItem('tk_ms_expanded', JSON.stringify(expanded)); } catch (e) { /* noop */ }
  }

  // --- Tab 3: Reports (context-aware) ---
  function getRelevantSections() {
    var s = state(), runType = (s.run_type || 'milestone').toLowerCase();
    var stages = s.stages || {}, r = reports(), sec = security();
    var all = [
      { key: 'run_context', label: 'Run Context', render: renderRunContextBody, always: true },
      { key: 'intake', label: 'Intake Report', render: renderIntakeBody, stage: 'intake' },
      { key: 'coder', label: 'Coder Summary', render: renderCoderBody, stage: 'coder' },
      { key: 'security', label: 'Security Report', render: renderSecurityBody, stage: 'security' },
      { key: 'reviewer', label: 'Reviewer Report', render: renderReviewerBody, stage: 'reviewer' },
      { key: 'test_audit', label: 'Test Audit', render: renderTestAuditBody },
      { key: 'backlog', label: 'Notes Backlog', render: renderBacklogBody }
    ];
    var result = [];
    for (var i = 0; i < all.length; i++) {
      var sect = all[i];
      if (sect.always) { result.push(sect); continue; }
      var hasData = sect.key === 'security' ? (sec.findings && sec.findings.length > 0) : !!(r[sect.key]);
      var stg = sect.stage ? stages[sect.stage] : null;
      var stgDone = stg && stg.status && stg.status !== 'pending';
      var visible = false;
      if (runType === 'milestone') visible = true;
      else if (runType.indexOf('human') === 0) visible = sect.key === 'intake' || sect.key === 'coder' || sect.key === 'reviewer' || (sect.key === 'security' && stgDone) || hasData;
      else if (runType === 'drift' || runType === 'nonblocker') visible = sect.key === 'coder' || sect.key === 'reviewer' || hasData;
      else visible = hasData;
      if (stg && stg.status === 'complete') visible = true;
      if (stg && stg.status === 'pending' && !hasData) visible = false;
      if (visible) result.push(sect);
    }
    return result;
  }
  function renderReports() {
    var ct = document.getElementById('tab-reports');
    if (!ct) return;
    var r = reports(), sec = security(), secs = getRelevantSections(), hasAny = false;
    for (var i = 0; i < secs.length; i++) {
      var sk = secs[i].key; if (sk === 'run_context') continue;
      if ((sk === 'security' && sec.findings && sec.findings.length) || r[sk]) { hasAny = true; break; }
    }
    if (!hasAny && secs.length <= 1) { ct.innerHTML = '<div class="empty-state">No reports yet \u2014 run tekhton to see data here</div>'; return; }
    var os = {}; try { var sv = localStorage.getItem('tk_reports_open'); if (sv) os = JSON.parse(sv); } catch (e) { /* noop */ }
    var h = '';
    for (var j = 0; j < secs.length; j++) {
      var s = secs[j];
      if (s.key === 'run_context') { h += s.render(); continue; }
      var data = s.key === 'security' ? sec : r[s.key], ip = !data;
      h += '<div class="accordion-item' + (os[s.key] ? ' open' : '') + (ip ? ' disabled' : '') + '" data-section="' + s.key + '">';
      h += '<div class="accordion-header"><span class="arrow">\u25B6</span><span class="title">' + esc(s.label) + '</span>';
      h += (ip ? '<span class="badge badge-pending">Pending</span>' : getSectionBadge(s.key, data));
      h += '</div><div class="accordion-body">' + (ip ? '<em>Pending</em>' : s.render(data)) + '</div></div>';
    }
    ct.innerHTML = h;
    var hds = ct.querySelectorAll('.accordion-header');
    for (var k = 0; k < hds.length; k++) hds[k].addEventListener('click', function () {
      var it = this.parentElement;
      if (!it.classList.contains('disabled')) { it.classList.toggle('open'); persistReportState(); }
    });
  }
  function renderRunContextBody() {
    var s = state(), runType = s.run_type || 'milestone', task = s.task_label || s.task || '';
    var msId = s.active_milestone ? s.active_milestone.id : '', msTitle = s.active_milestone ? s.active_milestone.title : '';
    var html = '<div class="run-context-card"><span class="' + badgeClass(runType) + ' run-type-badge">' + esc(runType.replace(/_/g, ' ')) + '</span>';
    if (task) html += '<span class="run-context-task">' + esc(truncate(task, 60)) + '</span>';
    if (msId) html += '<span class="run-context-ms">Milestone ' + esc(msId) + (msTitle ? ': ' + esc(truncate(msTitle, 40)) : '') + '</span>';
    if (s.started_at) html += '<span class="run-context-time">Started ' + fmtTime(s.started_at) + '</span>';
    html += '<span class="' + badgeClass(s.pipeline_status) + '">' + esc(s.pipeline_status || 'initializing') + '</span></div>';
    return html;
  }
  function getSectionBadge(key, data) {
    if (key === 'intake' && data.verdict) return '<span class="' + badgeClass(data.verdict) + '">' + esc(data.verdict) + (data.confidence ? ' ' + data.confidence + '%' : '') + '</span>';
    if (key === 'coder' && data.files_modified != null) return '<span class="badge badge-info">' + data.files_modified + ' modified</span>';
    if (key === 'security') {
      var f = data.findings || [];
      if (!f.length) return '<span class="badge badge-pass">Clean</span>';
      var mx = 'LOW';
      for (var i = 0; i < f.length; i++) { var sv = (f[i].severity || '').toUpperCase(); if (sv === 'CRITICAL' || sv === 'HIGH') { mx = sv; break; } if (sv === 'MEDIUM') mx = 'MEDIUM'; }
      return '<span class="' + badgeClass(mx) + '">' + f.length + ' ' + mx + '</span>';
    }
    if (key === 'reviewer' && data.verdict) return '<span class="' + badgeClass(data.verdict) + '">' + esc(data.verdict) + '</span>';
    if (key === 'test_audit' && data.total != null) return '<span class="badge badge-info">' + (data.passed || 0) + '/' + data.total + ' passed</span>';
    if (key === 'backlog') { var tot = (data.bug || 0) + (data.feat || 0) + (data.polish || 0); if (tot > 0) return '<span class="badge badge-info">' + tot + ' items</span>'; }
    return '';
  }
  function statRow(label, value) { return '<div class="stat-row"><span class="stat-label">' + label + '</span><span class="stat-value">' + value + '</span></div>'; }
  function renderIntakeBody(data) { return statRow('Verdict:', esc(data.verdict || 'unknown')) + statRow('Confidence:', esc(data.confidence || 0) + '/100'); }
  function renderCoderBody(data) { return statRow('Status:', esc(data.status || 'unknown')) + statRow('Files modified:', esc(data.files_modified || 0)); }
  function renderSecurityBody(data) {
    var findings = data.findings || [];
    if (!findings.length) return '<em>No findings</em>';
    var html = '<table class="findings-table"><thead><tr><th>Severity</th><th>Category</th><th>Detail</th></tr></thead><tbody>';
    for (var i = 0; i < findings.length; i++) {
      var f = findings[i];
      html += '<tr><td><span class="' + badgeClass(f.severity) + '">' + esc(f.severity) + '</span></td><td>' + esc(f.category || '-') + '</td><td>' + esc(f.detail || '') + '</td></tr>';
    }
    return html + '</tbody></table>';
  }
  function renderReviewerBody(data) { return statRow('Verdict:', esc(data.verdict || 'unknown')); }
  function renderTestAuditBody(data) {
    if (!data) return '<em>No test audit data</em>';
    var html = '';
    if (data.total != null) { html += statRow('Total tests:', esc(data.total)) + statRow('Passed:', esc(data.passed || 0)) + statRow('Failed:', esc(data.failed || 0)); }
    if (data.pre_existing_failures != null) html += statRow('Pre-existing failures:', esc(data.pre_existing_failures));
    if (data.details) html += '<div style="white-space:pre-wrap;font-size:0.75rem;margin-top:0.5rem">' + esc(data.details) + '</div>';
    return html;
  }
  function renderBacklogBody(data) {
    if (!data) return '<em>No backlog data</em>';
    return statRow('Bug notes:', esc(data.bug || 0)) + statRow('Feature notes:', esc(data.feat || 0)) + statRow('Polish notes:', esc(data.polish || 0)) + statRow('Total:', (data.bug || 0) + (data.feat || 0) + (data.polish || 0));
  }
  function persistReportState() {
    var open = {}, items = document.querySelectorAll('.accordion-item.open');
    for (var i = 0; i < items.length; i++) open[items[i].dataset.section] = true;
    try { localStorage.setItem('tk_reports_open', JSON.stringify(open)); } catch (e) { /* noop */ }
  }

  // --- Tab 4: Trends (enhanced) ---
  function getRunTypeFilter() { try { return localStorage.getItem('tk_run_type_filter') || 'all'; } catch (e) { return 'all'; } }
  function setRunTypeFilter(f) { try { localStorage.setItem('tk_run_type_filter', f); } catch (e) { /* noop */ } }

  function matchFilter(fl, rt) { return fl === 'all' || (fl === 'human' ? rt.indexOf('human') === 0 : (fl === 'adhoc' ? rt === 'adhoc' || rt === 'ad_hoc' : rt === fl)); }
  function renderTrends() {
    var ct = document.getElementById('tab-trends');
    if (!ct) return;
    var runs = (metrics().runs || []);
    if (!runs.length) { ct.innerHTML = '<div class="empty-state">No runs yet \u2014 run tekhton to see data here</div>'; return; }
    var h = '<div class="trends-grid">', tT = 0, tTm = 0, sC = 0, rC = 0, oc;
    for (var i = 0; i < runs.length; i++) {
      tT += (runs[i].total_turns || 0); tTm += (runs[i].total_time_s || 0);
      oc = (runs[i].outcome || '').toLowerCase();
      if (oc === 'split') sC++; if (oc === 'rejected') rC++;
    }
    h += '<div class="card trend-section"><h3>Efficiency</h3>';
    h += statRow('Avg turns/run', Math.round(tT / runs.length) + trendArrow(runs, 'total_turns'));
    h += statRow('Avg run duration', fmtDuration(Math.round(tTm / runs.length)) + trendArrow(runs, 'total_time_s'));
    h += statRow('Review rejection rate', Math.round((rC / runs.length) * 100) + '%');
    h += statRow('Split frequency', Math.round((sC / runs.length) * 100) + '%');
    var tg = {}, tn, ta = '';
    for (var g = 0; g < runs.length; g++) { tn = (runs[g].run_type || 'milestone').toLowerCase(); if (!tg[tn]) tg[tn] = { t: 0, c: 0 }; tg[tn].t += (runs[g].total_turns || 0); tg[tn].c++; }
    var tns = []; for (tn in tg) if (tg.hasOwnProperty(tn)) tns.push(tn); tns.sort();
    for (var t = 0; t < tns.length; t++) { var lb = tns[t].replace(/_/g, ' '); if (ta) ta += ' \u00B7 '; ta += lb.charAt(0).toUpperCase() + lb.slice(1) + ' avg: ' + Math.round(tg[tns[t]].t / tg[tns[t]].c) + ' turns'; }
    if (ta) h += '<div class="stat-row type-averages"><span class="stat-label">By type</span><span class="stat-value stat-value-small">' + ta + '</span></div>';
    h += '</div>' + renderHealthCard();
    h += '<div class="card trend-section"><h3>Per-Stage Breakdown</h3>' + renderStageBreakdown(runs) + '</div></div>';
    var af = getRunTypeFilter();
    h += '<div class="card trend-section" style="margin-top:0.75rem"><div class="trends-header-row"><h3>Recent Runs (' + runs.length + ')</h3><div class="run-type-filters">';
    var fl = [['all','All'],['milestone','Milestones'],['human','Human Notes'],['drift','Drift'],['adhoc','Ad Hoc']];
    for (var fi = 0; fi < fl.length; fi++) h += '<button class="filter-btn' + (af === fl[fi][0] ? ' active' : '') + '" data-filter="' + fl[fi][0] + '">' + fl[fi][1] + '</button>';
    h += '</div></div><ul class="run-list">';
    for (var r = 0; r < runs.length; r++) {
      var run = runs[r], rt = (run.run_type || 'milestone').toLowerCase();
      var oi = (run.outcome || '').toLowerCase() === 'pass' || (run.outcome || '').toLowerCase() === 'success' ? '\u2713' : '\u2717';
      h += '<li' + (matchFilter(af, rt) ? '' : ' class="hidden"') + '><span class="run-num">#' + (runs.length - r) + '</span>';
      h += '<span class="' + badgeClass(rt) + ' run-type-tag">' + esc(rt.replace(/_/g, ' ')) + '</span>';
      h += '<span class="run-milestone">' + (run.milestone && rt === 'milestone' ? esc(run.milestone) + (run.milestone_title ? ': ' + esc(truncate(run.milestone_title, 30)) : '') : esc(truncate(run.task_label || run.milestone || '-', 40))) + '</span>';
      h += '<span class="run-turns">' + (run.total_turns || 0) + ' turns</span><span class="run-time">' + fmtDuration(run.total_time_s || 0) + '</span>';
      h += '<span class="' + badgeClass(run.outcome) + '">' + oi + ' ' + esc(run.outcome || 'unknown') + '</span></li>';
    }
    h += '</ul></div>';
    ct.innerHTML = h;
    var fbs = ct.querySelectorAll('.filter-btn');
    for (var fb = 0; fb < fbs.length; fb++) fbs[fb].addEventListener('click', function () {
      var f = this.dataset.filter; setRunTypeFilter(f);
      var ab = document.querySelectorAll('.filter-btn');
      for (var a = 0; a < ab.length; a++) ab[a].classList.toggle('active', ab[a].dataset.filter === f);
      var lis = document.querySelectorAll('.run-list li');
      for (var ri = 0; ri < lis.length; ri++) {
        var b = lis[ri].querySelector('.run-type-tag'), it = b ? b.textContent.toLowerCase().replace(/\s+/g, '_') : '';
        lis[ri].classList.toggle('hidden', !matchFilter(f, it));
      }
    });
  }
  function renderHealthCard() {
    var h = health();
    if (!h.available) return '';
    var data = h.data || {}, composite = data.composite || 0, belt = h.belt || '';
    var dims = data.dimensions || {}, delta = data.delta, prevC = data.previous_composite;
    var sc = composite >= 75 ? 'health-good' : composite >= 40 ? 'health-ok' : 'health-low';
    var html = '<div class="card trend-section"><h3>Project Health</h3><div class="health-composite ' + sc + '"><span class="health-score">' + composite + '/100</span>';
    if (belt) html += '<span class="health-belt">' + esc(belt) + '</span>';
    if (typeof delta === 'number' && typeof prevC === 'number') {
      var ar = delta > 0 ? '\u2191' : delta < 0 ? '\u2193' : '\u2192';
      html += '<span class="' + (delta > 0 ? 'trend-arrow down' : delta < 0 ? 'trend-arrow up' : 'trend-arrow neutral') + '">' + ar + ' ' + (delta > 0 ? '+' : '') + delta + '</span>';
    }
    html += '</div>';
    var dn = ['test_health', 'code_quality', 'dependency_health', 'doc_quality', 'project_hygiene'];
    var dl = { test_health: 'Tests', code_quality: 'Quality', dependency_health: 'Dependencies', doc_quality: 'Documentation', project_hygiene: 'Hygiene' };
    html += '<div class="health-dimensions">';
    for (var i = 0; i < dn.length; i++) {
      var dim = dims[dn[i]] || {}, score = dim.score || 0, w = dim.weight || 0, dd = dim.delta;
      var bc = score >= 75 ? 'bar-good' : score >= 40 ? 'bar-ok' : 'bar-low';
      html += '<div class="health-dim-row"><span class="health-dim-label">' + (dl[dn[i]] || dn[i]) + ' (' + w + '%)</span>';
      html += '<div class="health-bar-container"><div class="health-bar ' + bc + '" style="width:' + score + '%"></div></div>';
      html += '<span class="health-dim-score">' + score + '</span>';
      if (typeof dd === 'number' && dd !== 0) html += '<span class="health-dim-delta">' + (dd > 0 ? '\u2191+' : '\u2193') + dd + '</span>';
      html += '</div>';
    }
    html += '</div></div>';
    return html;
  }
  function trendArrow(runs, field) {
    if (runs.length < 4) return '';
    var half = Math.floor(runs.length / 2), recentAvg = 0, priorAvg = 0;
    for (var i = 0; i < half; i++) recentAvg += (runs[i][field] || 0);
    for (var j = half; j < runs.length; j++) priorAvg += (runs[j][field] || 0);
    recentAvg /= half; priorAvg /= (runs.length - half) || 1;
    var diff = recentAvg - priorAvg, pct = priorAvg ? Math.abs(Math.round((diff / priorAvg) * 100)) : 0;
    if (pct < 5) return '<span class="trend-arrow neutral">\u2192</span>';
    return diff < 0 ? '<span class="trend-arrow down">\u2193</span>' : '<span class="trend-arrow up">\u2191</span>';
  }
  function renderStageBreakdown(runs) {
    var stageTotals = {}, stageCount = {}, sn;
    for (var i = 0; i < stageOrder.length; i++) { stageTotals[stageOrder[i]] = { turns: 0, time: 0, budget: 0 }; stageCount[stageOrder[i]] = 0; }
    for (var r = 0; r < runs.length; r++) {
      var stages = runs[r].stages || {};
      for (var s = 0; s < stageOrder.length; s++) { sn = stageOrder[s]; var sd = stages[sn]; if (sd) { stageTotals[sn].turns += (sd.turns || 0); stageTotals[sn].time += (sd.duration_s || 0); if (sd.budget > 0) stageTotals[sn].budget += Math.round(((sd.turns || 0) / sd.budget) * 100); stageCount[sn]++; } }
    }
    var lastRun = runs.length ? runs[0] : null, lastStages = lastRun ? (lastRun.stages || {}) : {};
    var maxAvg = 1;
    for (var t = 0; t < stageOrder.length; t++) { var a = stageCount[stageOrder[t]] ? stageTotals[stageOrder[t]].turns / stageCount[stageOrder[t]] : 0; if (a > maxAvg) maxAvg = a; }
    var html = '<table class="breakdown-table"><thead><tr><th>Stage</th><th>Avg Turns</th><th>Last Run</th><th>Avg Time</th><th>Budget Util</th><th class="bar-chart-cell">Distribution</th></tr></thead><tbody>';
    for (var b = 0; b < stageOrder.length; b++) {
      sn = stageOrder[b]; var cnt = stageCount[sn] || 1;
      var avgT = Math.round(stageTotals[sn].turns / cnt), bu = Math.round(stageTotals[sn].budget / cnt);
      var lsd = lastStages[sn], lbu = lsd && lsd.budget > 0 ? Math.round(((lsd.turns || 0) / lsd.budget) * 100) : 0;
      var bc = bu >= 100 ? 'budget-red' : bu >= 80 ? 'budget-amber' : 'budget-green';
      var lbc = lbu >= 100 ? 'budget-red' : lbu >= 80 ? 'budget-amber' : 'budget-green';
      html += '<tr><td>' + (stageLabels[sn] || sn) + '</td><td>' + avgT + '</td>';
      html += '<td>' + (lsd ? (lsd.turns || 0) + ' <span class="' + lbc + '">(' + lbu + '%)</span>' : '-') + '</td>';
      html += '<td>' + fmtDuration(Math.round(stageTotals[sn].time / cnt)) + '</td>';
      html += '<td><span class="' + bc + '">' + bu + '%</span></td>';
      html += '<td class="bar-chart-cell"><div class="bar-wrap"><div class="bar-fill" style="width:' + Math.round((avgT / maxAvg) * 100) + '%"></div></div></td></tr>';
    }
    return html + '</tbody></table>';
  }

  // --- Tab 5: Actions ---
  var serverAvailable = null; // null = unknown, true/false after probe
  function probeServer() {
    if (serverAvailable !== null) return;
    if (typeof fetch !== 'function') { serverAvailable = false; return; }
    fetch('/api/ping', { method: 'GET' }).then(function (r) {
      serverAvailable = r.ok;
    }).catch(function () { serverAvailable = false; });
  }
  probeServer();

  function getNextMilestoneId() {
    var ms = milestones(), maxNum = 0;
    for (var i = 0; i < ms.length; i++) {
      var m = ms[i].id.replace(/^m0*/, '');
      var n = parseInt(m, 10);
      if (!isNaN(n) && n > maxNum) maxNum = n;
    }
    var next = maxNum + 1;
    return next < 10 ? 'm0' + next : 'm' + next;
  }
  function getExistingGroups() {
    var ms = milestones(), groups = {};
    for (var i = 0; i < ms.length; i++) {
      var g = ms[i].parallel_group;
      if (g) groups[g] = true;
    }
    var result = [];
    for (var k in groups) if (groups.hasOwnProperty(k)) result.push(k);
    return result.sort();
  }
  function milestoneIdExists(id) {
    var ms = milestones();
    for (var i = 0; i < ms.length; i++) if (ms[i].id === id) return true;
    return false;
  }
  function generateFilename(prefix, type) {
    var ts = new Date().toISOString().replace(/[-:T]/g, '').replace(/\.\d+Z$/, '');
    return prefix + '_' + ts + (type ? '_' + type.toLowerCase() : '') + (prefix === 'task' ? '.txt' : '.md');
  }
  function downloadFile(filename, content) {
    var blob = new Blob([content], { type: 'text/plain;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    setTimeout(function () { document.body.removeChild(a); URL.revokeObjectURL(a.href); }, 100);
  }
  function submitFile(filename, content, callback) {
    if (serverAvailable) {
      fetch('/api/submit', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ filename: filename, content: content })
      }).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        callback(true, 'Saved to inbox');
      }).catch(function () { downloadFile(filename, content); callback(true, 'Downloaded (save to .claude/watchtower_inbox/)'); });
    } else {
      downloadFile(filename, content);
      callback(true, 'Downloaded (save to .claude/watchtower_inbox/)');
    }
  }
  function showFormSuccess(formId, msg) {
    var el = document.getElementById(formId + '-success');
    if (el) { el.textContent = msg; el.style.display = 'block'; setTimeout(function () { el.style.display = 'none'; }, 4000); }
  }
  function showFormError(formId, msg) {
    var el = document.getElementById(formId + '-error');
    if (el) { el.textContent = msg; el.style.display = 'block'; setTimeout(function () { el.style.display = 'none'; }, 4000); }
  }

  function renderActions() {
    var ct = document.getElementById('tab-actions');
    if (!ct) return;
    var h = '<div class="actions-grid">';

    // --- Human Notes Form ---
    h += '<div class="action-card"><h3>Submit Human Note</h3>';
    h += '<form id="note-form" onsubmit="return false">';
    h += '<div class="form-group"><label>Type (required)</label><div class="radio-group">';
    h += '<label><input type="radio" name="note-type" value="BUG"><span>BUG</span></label>';
    h += '<label><input type="radio" name="note-type" value="FEAT" checked><span>FEAT</span></label>';
    h += '<label><input type="radio" name="note-type" value="POLISH"><span>POLISH</span></label>';
    h += '</div></div>';
    h += '<div class="form-group"><label>Title (required)</label><input type="text" id="note-title" maxlength="120" placeholder="Brief description of the issue or request"></div>';
    h += '<div class="form-group"><label>Description (optional)</label><textarea id="note-desc" maxlength="2000" placeholder="Additional details, steps to reproduce, etc."></textarea><div class="char-count"><span id="note-desc-count">0</span>/2000</div></div>';
    h += '<div class="form-group"><label>Priority</label><div class="radio-group">';
    h += '<label><input type="radio" name="note-priority" value="Low"><span>Low</span></label>';
    h += '<label><input type="radio" name="note-priority" value="Medium" checked><span>Medium</span></label>';
    h += '<label><input type="radio" name="note-priority" value="High"><span>High</span></label>';
    h += '</div></div>';
    h += '<div class="form-actions"><button class="btn-submit" id="note-submit">Submit Note</button></div>';
    h += '<div class="form-error" id="note-form-error"></div>';
    h += '<div class="form-success" id="note-form-success"></div>';
    h += '</form></div>';

    // --- Milestone Form ---
    var nextId = getNextMilestoneId();
    var groups = getExistingGroups();
    h += '<div class="action-card"><h3>Create Milestone</h3>';
    h += '<form id="ms-form" onsubmit="return false">';
    h += '<div class="form-group"><label>Milestone ID</label><input type="text" id="ms-id" value="' + esc(nextId) + '" maxlength="10"></div>';
    h += '<div class="form-group"><label>Title (required)</label><input type="text" id="ms-title" maxlength="100" placeholder="Milestone title"></div>';
    h += '<div class="form-group"><label>Description (required)</label><textarea id="ms-desc" maxlength="5000" placeholder="Scope description for this milestone"></textarea><div class="char-count"><span id="ms-desc-count">0</span>/5000</div></div>';
    h += '<div class="form-group"><label>Depends On (optional)</label><select id="ms-deps" multiple style="min-height:3rem">';
    var ms = milestones();
    for (var i = 0; i < ms.length; i++) h += '<option value="' + esc(ms[i].id) + '">' + esc(ms[i].id) + ' — ' + esc(truncate(ms[i].title, 40)) + '</option>';
    h += '</select><div class="form-hint">Hold Ctrl/Cmd to select multiple</div></div>';
    h += '<div class="form-group"><label>Parallel Group (optional)</label><input type="text" id="ms-group" list="ms-group-list" placeholder="e.g. foundation"><datalist id="ms-group-list">';
    for (var g = 0; g < groups.length; g++) h += '<option value="' + esc(groups[g]) + '">';
    h += '</datalist></div>';
    h += '<div class="form-actions"><button class="btn-submit" id="ms-submit">Create Milestone</button></div>';
    h += '<div class="form-error" id="ms-form-error"></div>';
    h += '<div class="form-success" id="ms-form-success"></div>';
    h += '</form></div>';

    // --- Ad Hoc Task Form ---
    h += '<div class="action-card"><h3>Queue Ad Hoc Task</h3>';
    h += '<form id="task-form" onsubmit="return false">';
    h += '<div class="form-group"><label>Task Description (required)</label><textarea id="task-desc" maxlength="2000" placeholder="Describe the task to queue for the next pipeline run"></textarea><div class="char-count"><span id="task-desc-count">0</span>/2000</div></div>';
    h += '<div class="form-actions"><button class="btn-submit" id="task-submit">Queue Task</button></div>';
    h += '<div class="form-error" id="task-form-error"></div>';
    h += '<div class="form-success" id="task-form-success"></div>';
    h += '</form></div>';

    // --- Pending Submissions ---
    var items = inbox().items || [];
    h += '<div class="action-card full-width inbox-section"><h3>Pending Submissions (' + items.length + ')</h3>';
    if (items.length === 0) {
      h += '<div class="empty-state" style="padding:1rem">No pending items in inbox</div>';
    } else {
      for (var p = 0; p < items.length; p++) {
        var it = items[p];
        h += '<div class="inbox-item"><span class="' + badgeClass(it.type || 'info') + ' inbox-type">' + esc(it.type || 'unknown') + '</span>';
        h += '<span class="inbox-title">' + esc(it.title || it.filename || '') + '</span>';
        h += '<span class="inbox-time">' + esc(it.submitted || '') + '</span></div>';
      }
    }
    h += '</div>';

    h += '</div>'; // actions-grid
    ct.innerHTML = h;
    bindActionForms();
  }

  function bindActionForms() {
    // Character counters
    var pairs = [['note-desc', 'note-desc-count'], ['ms-desc', 'ms-desc-count'], ['task-desc', 'task-desc-count']];
    for (var i = 0; i < pairs.length; i++) (function (id, cid) {
      var el = document.getElementById(id);
      if (el) el.addEventListener('input', function () {
        var c = document.getElementById(cid);
        if (c) c.textContent = el.value.length;
      });
    })(pairs[i][0], pairs[i][1]);

    // Milestone ID collision check
    var msIdEl = document.getElementById('ms-id');
    if (msIdEl) msIdEl.addEventListener('input', function () {
      var btn = document.getElementById('ms-submit');
      if (milestoneIdExists(msIdEl.value.trim())) {
        showFormError('ms-form', 'Milestone ID already exists');
        if (btn) btn.disabled = true;
      } else {
        var errEl = document.getElementById('ms-form-error');
        if (errEl) errEl.style.display = 'none';
        if (btn) btn.disabled = false;
      }
    });

    // Note submit
    var noteBtn = document.getElementById('note-submit');
    if (noteBtn) noteBtn.addEventListener('click', function () {
      var title = (document.getElementById('note-title') || {}).value || '';
      if (!title.trim()) { showFormError('note-form', 'Title is required'); return; }
      var typeEl = document.querySelector('input[name="note-type"]:checked');
      var type = typeEl ? typeEl.value : 'FEAT';
      var desc = (document.getElementById('note-desc') || {}).value || '';
      var prioEl = document.querySelector('input[name="note-priority"]:checked');
      var prio = prioEl ? prioEl.value : 'Medium';
      var ts = new Date().toISOString();
      var content = '<!-- watchtower-note -->\n- [ ] [' + type + '] ' + title.trim() + '\n';
      if (desc.trim()) content += '\n' + desc.trim() + '\n';
      content += '\nPriority: ' + prio + '\nSubmitted: ' + ts + '\nSource: watchtower\n';
      var filename = generateFilename('note', type);
      submitFile(filename, content, function (ok, msg) {
        if (ok) {
          showFormSuccess('note-form', 'Note submitted. ' + msg);
          (document.getElementById('note-title') || {}).value = '';
          (document.getElementById('note-desc') || {}).value = '';
          var cnt = document.getElementById('note-desc-count'); if (cnt) cnt.textContent = '0';
        }
      });
    });

    // Milestone submit
    var msBtn = document.getElementById('ms-submit');
    if (msBtn) msBtn.addEventListener('click', function () {
      var id = (document.getElementById('ms-id') || {}).value || '';
      var title = (document.getElementById('ms-title') || {}).value || '';
      var desc = (document.getElementById('ms-desc') || {}).value || '';
      if (!id.trim()) { showFormError('ms-form', 'Milestone ID is required'); return; }
      if (!title.trim()) { showFormError('ms-form', 'Title is required'); return; }
      if (!desc.trim()) { showFormError('ms-form', 'Description is required'); return; }
      if (milestoneIdExists(id.trim())) { showFormError('ms-form', 'Milestone ID already exists'); return; }
      var depsEl = document.getElementById('ms-deps'), deps = [];
      if (depsEl) for (var d = 0; d < depsEl.options.length; d++) if (depsEl.options[d].selected) deps.push(depsEl.options[d].value);
      var group = (document.getElementById('ms-group') || {}).value || '';
      var num = id.trim().replace(/^m0*/, '');
      var mdContent = '# Milestone ' + num + ': ' + title.trim() + '\n\n## Overview\n\n' + desc.trim() + '\n\n## Scope\n\n(To be detailed during planning or execution)\n\n## Acceptance Criteria\n\n- (To be defined)\n\n## Watch For\n\n- (To be defined)\n';
      var cfgLine = id.trim() + '|' + title.trim() + '|pending|' + deps.join(',') + '|milestone_' + id.trim() + '.md|' + group.trim() + '\n';
      submitFile('milestone_' + id.trim() + '.md', mdContent, function (ok, msg) {
        if (ok) submitFile('manifest_append_' + id.trim() + '.cfg', cfgLine, function (ok2, msg2) {
          if (ok2) {
            showFormSuccess('ms-form', 'Milestone created. ' + msg2);
            (document.getElementById('ms-title') || {}).value = '';
            (document.getElementById('ms-desc') || {}).value = '';
            var cnt = document.getElementById('ms-desc-count'); if (cnt) cnt.textContent = '0';
          }
        });
      });
    });

    // Task submit
    var taskBtn = document.getElementById('task-submit');
    if (taskBtn) taskBtn.addEventListener('click', function () {
      var desc = (document.getElementById('task-desc') || {}).value || '';
      if (!desc.trim()) { showFormError('task-form', 'Task description is required'); return; }
      var filename = generateFilename('task');
      submitFile(filename, desc.trim() + '\n', function (ok, msg) {
        if (ok) {
          showFormSuccess('task-form', 'Task queued. ' + msg);
          (document.getElementById('task-desc') || {}).value = '';
          var cnt = document.getElementById('task-desc-count'); if (cnt) cnt.textContent = '0';
        }
      });
    });
  }

  // --- Incremental data refresh ---
  var refreshTimer = null, refreshStopped = false;
  function refreshData() {
    var dataFiles = ['run_state', 'timeline', 'milestones', 'reports', 'metrics', 'security', 'health', 'inbox'];
    var promises = [];
    for (var i = 0; i < dataFiles.length; i++) (function (name) {
      promises.push(fetch('data/' + name + '.js?t=' + Date.now()).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status); return r.text();
      }).then(function (text) { try { new Function(text)(); } catch (e) { throw new Error('Parse error in ' + name + '.js'); } }));
    })(dataFiles[i]);
    Promise.all(promises).then(function () {
      buildCausalIndex(); renderActiveTab(); updateStatusIndicator(); checkRefreshLifecycle();
    }).catch(function (err) { if (typeof console !== 'undefined') console.error('Watchtower refresh failed:', err); location.reload(); });
  }
  function checkRefreshLifecycle() {
    var s = state(), status = (s.pipeline_status || '').toLowerCase();
    if (s.completed_at || status === 'pass' || status === 'complete' || status === 'failed') {
      if (!refreshStopped) { refreshStopped = true; updateRefreshIndicator(true); }
      return;
    }
    if (!refreshStopped && (status === 'running' || status === 'initializing')) scheduleRefresh();
  }
  function scheduleRefresh() {
    if (refreshTimer) clearTimeout(refreshTimer);
    var interval = state().refresh_interval_ms || 5000;
    refreshTimer = setTimeout(function () {
      if (typeof fetch === 'function' && typeof Promise === 'function') refreshData(); else location.reload();
    }, interval);
  }
  function manualRefresh() {
    if (typeof fetch === 'function' && typeof Promise === 'function') refreshData(); else location.reload();
  }

  // --- Main render ---
  function render() {
    buildCausalIndex(); updateStatusIndicator(); initTheme(); initTabs();
    var btn = document.getElementById('manual-refresh');
    if (btn) btn.addEventListener('click', manualRefresh);
    checkRefreshLifecycle();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', render); else render();
})();
