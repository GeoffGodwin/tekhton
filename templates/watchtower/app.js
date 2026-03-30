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
  var actionItems = function () { return window.TK_ACTION_ITEMS || {}; };

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
    var defaultTab = saved && saved !== 'live' && document.getElementById('tab-' + saved) ? saved : 'reports';
    switchTab(defaultTab);
  }
  function switchTab(tabId) {
    var btns = document.querySelectorAll('.tab-btn'), tabs = document.querySelectorAll('.tab-content');
    for (var i = 0; i < btns.length; i++) btns[i].classList.toggle('active', btns[i].dataset.tab === tabId);
    for (var j = 0; j < tabs.length; j++) tabs[j].classList.toggle('active', tabs[j].id === 'tab-' + tabId);
    try { localStorage.setItem('tk_active_tab', tabId); } catch (e) { /* noop */ }
    renderTab(tabId);
  }
  function getActiveTab() {
    try { var t = localStorage.getItem('tk_active_tab'); return t && t !== 'live' ? t : 'reports'; } catch (e) { return 'reports'; }
  }
  function renderActiveTab() {
    renderTab(getActiveTab());
  }
  function renderTab(tabId) {
    switch (tabId) {
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

  // --- Stage constants ---
  var stageOrder = ['intake', 'scout', 'coder', 'build_gate', 'security', 'reviewer', 'tester'];
  var stageLabels = { intake: 'Intake', scout: 'Scout', coder: 'Coder', build_gate: 'Build', security: 'Security', reviewer: 'Review', tester: 'Test' };
  var teamColors = ['#4a9eff', '#22c55e', '#f59e0b', '#a855f7', '#ef4444', '#06b6d4'];
  var activeTeamFilter = null;

  function getTeamColor(teamId, teamIds) {
    for (var i = 0; i < teamIds.length; i++) if (teamIds[i] === teamId) return teamColors[i % teamColors.length];
    return teamColors[0];
  }

  function renderStageChips(stgs) {
    var h = '';
    for (var i = 0; i < stageOrder.length; i++) {
      var sn = stageOrder[i];
      // Scout renders as a sub-badge inside the Coder chip, not as a top-level chip
      if (sn === 'scout') continue;
      var si = stgs[sn] || {}, ss = (si.status || 'pending').toLowerCase();
      h += '<span class="stage-chip ' + esc(ss) + '">' + statusIcon(ss) + ' ' + (stageLabels[sn] || sn);
      // Nest scout sub-badge inside coder chip when scout has run
      if (sn === 'coder') {
        var scoutInfo = stgs['scout'] || {};
        var scoutSt = (scoutInfo.status || 'pending').toLowerCase();
        if (scoutSt !== 'pending') {
          h += ' <span class="scout-sub-badge ' + esc(scoutSt) + '">(' + statusIcon(scoutSt) + ' Scout)</span>';
        }
      }
      h += '</span>';
    }
    return h;
  }

  function renderTeamCard(teamId, team, color) {
    var ts = (team.status || 'pending').toLowerCase();
    var msLabel = team.milestone ? esc(team.milestone.id) + ': ' + esc(truncate(team.milestone.title, 20)) : 'No milestone';
    var stg = team.current_stage || 'unknown';
    var stgData = (team.stages || {})[stg] || {};
    var h = '<div class="team-card" data-team="' + esc(teamId) + '" style="border-top-color:' + color + '">';
    h += '<div class="team-card-header"><span class="team-name" style="color:' + color + '">' + esc(teamId) + '</span>';
    h += '<span class="' + badgeClass(ts) + '">' + esc(ts) + '</span></div>';
    h += '<div class="team-milestone">' + statusIcon(ts) + ' ' + msLabel + '</div>';
    h += '<div class="stage-progress compact">' + renderStageChips(team.stages || {}) + '</div>';
    h += '<div class="stage-detail">' + esc(stageLabels[stg] || stg) + ': ';
    if ((stgData.status || '').toLowerCase() === 'active') {
      h += fmtDuration(stgData.duration_s || 0) + ' \u00B7 budget: ' + esc(stgData.budget || '?') + ' turns';
    } else {
      h += esc(stgData.turns || 0) + ' turns used';
      if (stgData.duration_s) h += ' \u00B7 ' + fmtDuration(stgData.duration_s);
    }
    h += '</div></div>';
    return h;
  }

  function renderActionItemsSummary() {
    var ai = actionItems();
    var items = [];
    if (ai.human_actions && ai.human_actions.count > 0) {
      items.push({ label: 'HUMAN_ACTION_REQUIRED.md', count: ai.human_actions.count, severity: 'warning', hint: '' });
    }
    if (ai.nonblocking && ai.nonblocking.count > 0) {
      var nbSev = ai.nonblocking.severity || 'normal';
      var nbHint = nbSev === 'critical' ? 'tekhton --fix-nonblockers --complete' : '';
      items.push({ label: 'NON_BLOCKING_LOG.md', count: ai.nonblocking.count, severity: nbSev, hint: nbHint });
    }
    if (ai.human_notes && ai.human_notes.count > 0) {
      var hnSev = ai.human_notes.severity || 'normal';
      var hnHint = hnSev === 'critical' ? 'tekhton --human --complete' : '';
      items.push({ label: 'HUMAN_NOTES.md', count: ai.human_notes.count, severity: hnSev, hint: hnHint });
    }
    if (ai.drift && ai.drift.count > 0) {
      items.push({ label: 'DRIFT_LOG.md', count: ai.drift.count, severity: 'normal', hint: '' });
    }
    if (!items.length) return '';
    var h = '<div class="action-items-summary"><div class="action-items-title">Action Items</div>';
    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      h += '<div class="action-item-row action-' + esc(it.severity) + '">';
      var icon = it.severity === 'critical' ? '\u2717' : it.severity === 'warning' ? '\u26A0' : '\u2139';
      h += '<span class="action-icon">' + icon + '</span>';
      h += '<span>' + esc(it.label) + ' \u2014 ' + it.count + ' item(s)';
      if (it.severity === 'critical') h += ' [CRITICAL]';
      h += '</span>';
      if (it.hint) h += '<div class="action-hint">\u2192 Suggested: <code>' + esc(it.hint) + '</code></div>';
      h += '</div>';
    }
    h += '</div>';
    return h;
  }

  // --- Persistent Live Run Banner ---
  function renderLiveRunBanner() {
    var banner = document.getElementById('live-banner');
    if (!banner) return;
    var s = state();
    var st = (s.pipeline_status || 'idle').toLowerCase();
    var isActive = st === 'running' || st === 'initializing' || st === 'waiting';
    if (!isActive) {
      banner.className = 'banner-hidden';
      banner.innerHTML = '';
      return;
    }
    banner.className = 'banner-visible';
    var h = '';
    var teams = s.teams || {};
    var teamIds = []; for (var tk in teams) if (teams.hasOwnProperty(tk)) teamIds.push(tk);
    teamIds.sort();
    var isParallel = s.parallel_mode === true && teamIds.length > 1;
    if (isParallel) {
      h += '<div class="live-status-banner ' + esc(st) + '">' + statusIcon(st) + ' Pipeline ' + esc(st.toUpperCase()) + ' \u2014 ' + teamIds.length + ' teams active</div>';
      h += '<div class="stage-progress compact">';
      for (var ti = 0; ti < teamIds.length; ti++) {
        var team = teams[teamIds[ti]], ts = (team.status || 'pending').toLowerCase();
        var tColor = getTeamColor(teamIds[ti], teamIds);
        h += '<span class="stage-chip ' + esc(ts) + '" style="color:' + tColor + '">' + statusIcon(ts) + ' ' + esc(teamIds[ti]);
        if (team.current_stage) h += ': ' + esc(stageLabels[team.current_stage] || team.current_stage);
        h += '</span>';
      }
      h += '</div>';
    } else {
      var ml = s.active_milestone ? ' \u2014 Milestone ' + esc(s.active_milestone.id) + ': ' + esc(s.active_milestone.title) : '';
      h += '<div class="live-status-banner ' + esc(st) + '">' + statusIcon(st) + ' Pipeline ' + esc(st.toUpperCase()) + ml + '</div>';
      var stgs = s.stages || {};
      h += '<div class="stage-progress compact">' + renderStageChips(stgs) + '</div>';
      if (s.current_stage && stgs[s.current_stage]) {
        var d = stgs[s.current_stage];
        h += '<div class="stage-detail">' + esc(stageLabels[s.current_stage] || s.current_stage) + ': ';
        if ((d.status || '').toLowerCase() === 'active') {
          h += fmtDuration(d.duration_s || 0) + ' \u00B7 budget: ' + esc(d.budget || '?') + ' turns';
        } else {
          h += esc(d.turns || 0) + ' turns used';
          if (d.duration_s) h += ' \u00B7 ' + fmtDuration(d.duration_s);
        }
        h += '</div>';
      }
    }
    if (s.waiting_for) {
      h += '<div class="waiting-banner"><h3>\u23F8 Pipeline WAITING</h3><p>' + esc(s.waiting_for) + '</p></div>';
    }
    banner.innerHTML = h;
  }

  // --- Tab 2: Milestone Map ---
  var msViewMode = 'status'; // 'status' or 'parallel_group'
  function getMsViewMode() { try { return localStorage.getItem('tk_ms_view') || 'status'; } catch (e) { return 'status'; } }
  function setMsViewMode(m) { msViewMode = m; try { localStorage.setItem('tk_ms_view', m); } catch (e) { /* noop */ } }

  function scrollToMilestone(msId) {
    var card = document.querySelector('.ms-card[data-ms-id="' + msId + '"]');
    if (card) {
      card.scrollIntoView({ behavior: 'smooth', block: 'center' });
      card.classList.add('milestone-highlight');
      // Duration must match the CSS milestone-highlight animation (1.5s)
      setTimeout(function () { card.classList.remove('milestone-highlight'); }, 1500);
    }
  }

  function renderMsCard(mi, ec) {
    var h = '<div class="ms-card status-' + (mi.status || 'pending').toLowerCase() + (ec[mi.id] ? ' expanded' : '') + '" data-ms-id="' + esc(mi.id) + '"><span class="ms-id">' + esc(mi.id) + '</span>';
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
    // Summary paragraph
    if (mi.summary) {
      h += '<div class="milestone-summary">' + esc(mi.summary) + '</div>';
    }
    // Enabled by (dependencies) chips
    if (mi.depends_on) {
      var depList = mi.depends_on.split(',');
      var hasValidDeps = false;
      for (var di = 0; di < depList.length; di++) if (depList[di].trim()) { hasValidDeps = true; break; }
      if (hasValidDeps) {
        h += '<div class="ms-dep-section"><div class="ms-dep-label">Enabled by:</div><div class="ms-deps">';
        for (var dj = 0; dj < depList.length; dj++) {
          var depId = depList[dj].trim();
          if (depId) h += '<span class="dep-chip-enabledby" data-scroll-ms="' + esc(depId) + '">' + esc(depId) + '</span> ';
        }
        h += '</div></div>';
      }
    }
    // Enables (forward dependencies) chips
    if (mi.enables) {
      var enList = mi.enables.split(',');
      var hasValidEn = false;
      for (var ei = 0; ei < enList.length; ei++) if (enList[ei].trim()) { hasValidEn = true; break; }
      if (hasValidEn) {
        h += '<div class="ms-dep-section"><div class="ms-dep-label">Enables:</div><div class="ms-deps">';
        for (var ej = 0; ej < enList.length; ej++) {
          var enId = enList[ej].trim();
          if (enId) h += '<span class="dep-chip-enables" data-scroll-ms="' + esc(enId) + '">' + esc(enId) + '</span> ';
        }
        h += '</div></div>';
      }
    }
    h += '</div></div>';
    return h;
  }

  function renderMilestoneMap() {
    var ct = document.getElementById('tab-milestones');
    if (!ct) return;
    var ms = milestones();
    if (!ms.length) { ct.innerHTML = '<div class="empty-state">No milestones yet \u2014 run tekhton to see data here</div>'; return; }

    // Check if parallel groups exist
    var hasGroups = false;
    for (var gi = 0; gi < ms.length; gi++) if (ms[gi].parallel_group) { hasGroups = true; break; }
    msViewMode = getMsViewMode();

    var ec = {};
    try { var sv = localStorage.getItem('tk_ms_expanded'); if (sv) ec = JSON.parse(sv); } catch (e) { /* noop */ }

    var h = '';
    // View toggle (only if groups exist)
    if (hasGroups) {
      h += '<div class="ms-view-toggle">';
      h += '<span class="ms-view-label">View by:</span>';
      h += '<button class="filter-btn' + (msViewMode === 'status' ? ' active' : '') + '" data-ms-view="status">Status</button>';
      h += '<button class="filter-btn' + (msViewMode === 'parallel_group' ? ' active' : '') + '" data-ms-view="parallel_group">Parallel Group</button>';
      h += '</div>';
    }

    if (msViewMode === 'parallel_group' && hasGroups) {
      h += renderMilestonesByGroup(ms, ec);
    } else {
      h += renderMilestonesByStatus(ms, ec);
    }

    ct.innerHTML = h;

    // Bind view toggle
    var vbs = ct.querySelectorAll('[data-ms-view]');
    for (var v = 0; v < vbs.length; v++) vbs[v].addEventListener('click', function () {
      setMsViewMode(this.dataset.msView);
      renderMilestoneMap();
    });

    var cards = ct.querySelectorAll('.ms-card');
    for (var c = 0; c < cards.length; c++) cards[c].addEventListener('click', function () { this.classList.toggle('expanded'); persistMsExpanded(); });

    // Bind dep chip click-to-scroll (stop propagation so card toggle doesn't fire)
    var depChips = ct.querySelectorAll('[data-scroll-ms]');
    for (var dc = 0; dc < depChips.length; dc++) depChips[dc].addEventListener('click', function (e) {
      e.stopPropagation();
      scrollToMilestone(this.dataset.scrollMs);
    });
  }

  function renderMilestonesByStatus(ms, ec) {
    var aId = (state().active_milestone || {}).id, lanes = { done: [], active: [], ready: [], pending: [] }, ds = {}, m, st;
    for (var i = 0; i < ms.length; i++) if ((ms[i].status || '').toLowerCase() === 'done') ds[ms[i].id] = true;
    for (var j = 0; j < ms.length; j++) {
      m = ms[j]; st = (m.status || 'pending').toLowerCase();
      if (st === 'done') lanes.done.push(m);
      else if (st === 'in_progress' || st === 'active' || m.id === aId) lanes.active.push(m);
      else if (depsAllDone(m, ds)) lanes.ready.push(m);
      else lanes.pending.push(m);
    }
    var h = '<div class="swimlanes">', lo = [['pending','Pending'],['ready','Ready'],['active','Active'],['done','Done']];
    for (var l = 0; l < lo.length; l++) {
      var items = lanes[lo[l][0]];
      h += '<div class="swimlane"><div class="swimlane-header">' + lo[l][1] + ' (' + items.length + ')</div>';
      for (var n = 0; n < items.length; n++) h += renderMsCard(items[n], ec);
      h += '</div>';
    }
    h += '</div>';
    return h;
  }

  function renderMilestonesByGroup(ms, ec) {
    // Collect groups and assign milestones
    var groups = {}, order = [];
    for (var i = 0; i < ms.length; i++) {
      var g = ms[i].parallel_group || 'default';
      if (!groups[g]) { groups[g] = []; order.push(g); }
      groups[g].push(ms[i]);
    }
    // Topological sort within each group (by dependency chain)
    var ds = {};
    for (var d = 0; d < ms.length; d++) if ((ms[d].status || '').toLowerCase() === 'done') ds[ms[d].id] = true;

    // Cross-group dependencies for display
    var crossDeps = [];
    for (var cd = 0; cd < ms.length; cd++) {
      if (!ms[cd].depends_on) continue;
      var cdeps = ms[cd].depends_on.split(',');
      var srcGroup = ms[cd].parallel_group || 'default';
      for (var cdi = 0; cdi < cdeps.length; cdi++) {
        var depId = cdeps[cdi].trim();
        if (!depId) continue;
        for (var cj = 0; cj < ms.length; cj++) {
          if (ms[cj].id === depId) {
            var depGroup = ms[cj].parallel_group || 'default';
            if (depGroup !== srcGroup) crossDeps.push({ from: depId, fromGroup: depGroup, to: ms[cd].id, toGroup: srcGroup });
            break;
          }
        }
      }
    }

    var h = '<div class="swimlanes parallel-group-view">';
    for (var g2 = 0; g2 < order.length; g2++) {
      var gName = order[g2], gItems = groups[gName];
      var gColor = getTeamColor(gName, order);
      h += '<div class="swimlane"><div class="swimlane-header" style="border-bottom-color:' + gColor + '">' + esc(gName) + ' (' + gItems.length + ')</div>';
      for (var n = 0; n < gItems.length; n++) h += renderMsCard(gItems[n], ec);
      h += '</div>';
    }
    h += '</div>';

    // Cross-group dependency summary
    if (crossDeps.length) {
      h += '<div class="cross-deps-summary card"><h4>Cross-Group Dependencies</h4>';
      for (var x = 0; x < crossDeps.length; x++) {
        h += '<div class="cross-dep-row"><span class="dep-badge">' + esc(crossDeps[x].from) + '</span>';
        h += '<span class="cross-dep-arrow">\u2192</span>';
        h += '<span class="dep-badge">' + esc(crossDeps[x].to) + '</span>';
        h += '<span class="cross-dep-groups">(' + esc(crossDeps[x].fromGroup) + ' \u2192 ' + esc(crossDeps[x].toGroup) + ')</span></div>';
      }
      h += '</div>';
    }
    return h;
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
  var activeReportTeam = null; // null = aggregate, or team id

  function getRelevantSections(reportData) {
    var s = state(), runType = (s.run_type || 'milestone').toLowerCase();
    var stages = s.stages || {}, r = reportData || reports(), sec = security();
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
    var r = reports(), sec = security();

    // Check for per-team reports
    var teamReports = r.teams || {};
    var teamIds = []; for (var tk in teamReports) if (teamReports.hasOwnProperty(tk)) teamIds.push(tk);
    teamIds.sort();
    var hasTeams = teamIds.length > 0;

    // Determine effective report data
    var effectiveReports = r;
    if (hasTeams && activeReportTeam && teamReports[activeReportTeam]) {
      effectiveReports = teamReports[activeReportTeam];
    }

    var secs = getRelevantSections(effectiveReports), hasAny = false;
    for (var i = 0; i < secs.length; i++) {
      var sk = secs[i].key; if (sk === 'run_context') continue;
      if ((sk === 'security' && sec.findings && sec.findings.length) || effectiveReports[sk]) { hasAny = true; break; }
    }
    if (!hasAny && secs.length <= 1 && !hasTeams) { ct.innerHTML = '<div class="empty-state">No reports yet \u2014 run tekhton to see data here</div>'; return; }

    var h = '';

    // Team selector tabs (M37)
    if (hasTeams) {
      h += '<div class="report-team-selector">';
      h += '<button class="filter-btn' + (!activeReportTeam ? ' active' : '') + '" data-report-team="">All Teams</button>';
      for (var ti = 0; ti < teamIds.length; ti++) {
        h += '<button class="filter-btn' + (activeReportTeam === teamIds[ti] ? ' active' : '') + '" data-report-team="' + esc(teamIds[ti]) + '">' + esc(teamIds[ti]) + '</button>';
      }
      h += '</div>';
    }

    var os = {}; try { var sv = localStorage.getItem('tk_reports_open'); if (sv) os = JSON.parse(sv); } catch (e) { /* noop */ }
    for (var j = 0; j < secs.length; j++) {
      var s = secs[j];
      if (s.key === 'run_context') { h += s.render(); continue; }
      var data = s.key === 'security' ? sec : effectiveReports[s.key], ip = !data;
      h += '<div class="accordion-item' + (os[s.key] ? ' open' : '') + (ip ? ' disabled' : '') + '" data-section="' + s.key + '">';
      h += '<div class="accordion-header"><span class="arrow">\u25B6</span><span class="title">' + esc(s.label) + '</span>';
      h += (ip ? '<span class="badge badge-pending">Pending</span>' : getSectionBadge(s.key, data));
      h += '</div><div class="accordion-body">' + (ip ? '<em>Pending</em>' : s.render(data)) + '</div></div>';
    }
    ct.innerHTML = h;

    // Bind team selector
    var rtbs = ct.querySelectorAll('[data-report-team]');
    for (var rt = 0; rt < rtbs.length; rt++) rtbs[rt].addEventListener('click', function () {
      activeReportTeam = this.dataset.reportTeam || null;
      renderReports();
    });

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
    if (key === 'test_audit' && data.verdict) return '<span class="' + badgeClass(data.verdict) + '">' + esc(data.verdict) + '</span>';
    if (key === 'backlog') { var tot = (data.bug || 0) + (data.feat || 0) + (data.polish || 0); if (tot > 0) return '<span class="badge badge-info">' + tot + ' items</span>'; }
    return '';
  }
  function statRow(label, value) { return '<div class="stat-row"><span class="stat-label">' + label + '</span><span class="stat-value">' + value + '</span></div>'; }
  function renderIntakeBody(data) {
    var html = statRow('Verdict:', esc(data.verdict || 'unknown')) + statRow('Confidence:', esc(data.confidence || 0) + '/100');
    if (data.task_text) html += '<div class="intake-task-text"><span class="stat-label">Task:</span><div class="intake-task-content">' + esc(data.task_text) + '</div></div>';
    var s = state(), msId = s.active_milestone ? s.active_milestone.id : '';
    if (msId) html += '<div class="intake-ms-link"><a href="#" data-ms-link="' + esc(msId) + '">View in Milestone Map \u2192</a></div>';
    return html;
  }
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
    var html = statRow('Verdict:', '<span class="' + badgeClass(data.verdict || 'skipped') + '">' + esc(data.verdict || 'skipped') + '</span>');
    if (data.high_findings != null) html += statRow('High severity findings:', esc(data.high_findings));
    if (data.medium_findings != null) html += statRow('Medium severity findings:', esc(data.medium_findings));
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
    // Filter to meaningful runs (exclude crashed/null runs with no turns and no time)
    var mRuns = [];
    for (var mi = 0; mi < runs.length; mi++) { if ((runs[mi].total_turns || 0) > 0 || (runs[mi].total_time_s || 0) > 0) mRuns.push(runs[mi]); }
    var h = '<div class="trends-grid">', tT = 0, tTm = 0, tTmCount = 0, sC = 0, rC = 0, oc;
    for (var i = 0; i < mRuns.length; i++) {
      tT += (mRuns[i].total_turns || 0);
      if (mRuns[i].total_time_s > 0) { tTm += mRuns[i].total_time_s; tTmCount++; }
      oc = (mRuns[i].outcome || '').toLowerCase();
      if (oc === 'split') sC++; if (oc === 'rejected') rC++;
    }
    var mLen = mRuns.length || 1;
    h += '<div class="card trend-section"><h3>Efficiency</h3>';
    h += statRow('Avg turns/run', Math.round(tT / mLen) + trendArrow(mRuns, 'total_turns'));
    h += statRow('Avg run duration', (tTmCount > 0 ? fmtDuration(Math.round(tTm / tTmCount)) : '-') + trendArrow(mRuns, 'total_time_s'));
    h += statRow('Review rejection rate', Math.round((rC / mLen) * 100) + '%');
    h += statRow('Split frequency', Math.round((sC / mLen) * 100) + '%');
    var tg = {}, tn, ta = '';
    for (var g = 0; g < mRuns.length; g++) { tn = (mRuns[g].run_type || 'adhoc').toLowerCase(); if (!tg[tn]) tg[tn] = { t: 0, c: 0 }; tg[tn].t += (mRuns[g].total_turns || 0); tg[tn].c++; }
    var tns = []; for (tn in tg) if (tg.hasOwnProperty(tn)) tns.push(tn); tns.sort();
    for (var t = 0; t < tns.length; t++) { var lb = tns[t].replace(/_/g, ' '); if (ta) ta += ' \u00B7 '; ta += lb.charAt(0).toUpperCase() + lb.slice(1) + ' avg: ' + Math.round(tg[tns[t]].t / tg[tns[t]].c) + ' turns'; }
    if (ta) h += '<div class="stat-row type-averages"><span class="stat-label">By type</span><span class="stat-value stat-value-small">' + ta + '</span></div>';
    h += '</div>' + renderHealthCard();
    h += '<div class="card trend-section"><h3>Per-Stage Breakdown</h3>' + renderStageBreakdown(mRuns) + '</div></div>';
    var af = getRunTypeFilter();
    var visCount = 0;
    for (var vc = 0; vc < runs.length; vc++) { if (matchFilter(af, (runs[vc].run_type || 'adhoc').toLowerCase())) visCount++; }
    h += '<div class="card trend-section" style="margin-top:0.75rem"><div class="trends-header-row"><h3>Recent Runs (<span class="run-count">' + visCount + '</span>)</h3><div class="run-type-filters">';
    var fl = [['all','All'],['milestone','Milestones'],['human','Human Notes'],['drift','Drift'],['adhoc','Ad Hoc']];
    for (var fi = 0; fi < fl.length; fi++) h += '<button class="filter-btn' + (af === fl[fi][0] ? ' active' : '') + '" data-filter="' + fl[fi][0] + '">' + fl[fi][1] + '</button>';
    h += '</div></div><ul class="run-list">';
    for (var r = 0; r < runs.length; r++) {
      var run = runs[r], rt = (run.run_type || 'adhoc').toLowerCase();
      var oi = (run.outcome || '').toLowerCase() === 'pass' || (run.outcome || '').toLowerCase() === 'success' ? '\u2713' : '\u2717';
      h += '<li data-run-type="' + esc(rt) + '"' + (matchFilter(af, rt) ? '' : ' class="hidden"') + '><span class="run-num">#' + (runs.length - r) + '</span>';
      h += '<span class="' + badgeClass(rt) + ' run-type-tag">' + esc(rt.replace(/_/g, ' ')) + '</span>';
      if (run.team) h += '<span class="run-team-tag">' + esc(run.team) + '</span>';
      h += '<span class="run-milestone">' + (run.milestone && rt === 'milestone' ? esc(run.milestone) + (run.milestone_title ? ': ' + esc(truncate(run.milestone_title, 30)) : '') : esc(truncate(run.task_label || run.milestone || '-', 40))) + '</span>';
      h += '<span class="run-turns">' + (run.total_turns || 0) + ' turns</span><span class="run-time">' + fmtDuration(run.total_time_s || 0) + '</span>';
      h += '<span class="' + badgeClass(run.outcome) + '">' + oi + ' ' + esc(run.outcome || 'unknown') + '</span></li>';
    }
    h += '</ul></div>';

    // Per-Team Performance section (M37)
    h += renderTeamPerformance(mRuns);
    ct.innerHTML = h;
    var fbs = ct.querySelectorAll('.filter-btn');
    for (var fb = 0; fb < fbs.length; fb++) fbs[fb].addEventListener('click', function () {
      var f = this.dataset.filter; setRunTypeFilter(f);
      var ab = document.querySelectorAll('.filter-btn');
      for (var a = 0; a < ab.length; a++) ab[a].classList.toggle('active', ab[a].dataset.filter === f);
      var lis = document.querySelectorAll('.run-list li');
      var shown = 0;
      for (var ri = 0; ri < lis.length; ri++) {
        var it = lis[ri].getAttribute('data-run-type') || '';
        var vis = matchFilter(f, it);
        lis[ri].classList.toggle('hidden', !vis);
        if (vis) shown++;
      }
      var rc = document.querySelector('.run-count');
      if (rc) rc.textContent = shown;
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
    var stageTotals = {}, stageTurnCount = {}, stageTimeCount = {}, sn;
    for (var i = 0; i < stageOrder.length; i++) { stageTotals[stageOrder[i]] = { turns: 0, time: 0 }; stageTurnCount[stageOrder[i]] = 0; stageTimeCount[stageOrder[i]] = 0; }
    for (var r = 0; r < runs.length; r++) {
      var stages = runs[r].stages || {};
      for (var s = 0; s < stageOrder.length; s++) {
        sn = stageOrder[s]; var sd = stages[sn];
        if (sd) {
          stageTotals[sn].turns += (sd.turns || 0); stageTurnCount[sn]++;
          if (sd.duration_s > 0) { stageTotals[sn].time += sd.duration_s; stageTimeCount[sn]++; }
        }
      }
    }
    var lastRun = runs.length ? runs[0] : null, lastStages = lastRun ? (lastRun.stages || {}) : {};
    var activeStages = [];
    for (var f = 0; f < stageOrder.length; f++) { if (stageTurnCount[stageOrder[f]] > 0) activeStages.push(stageOrder[f]); }
    if (activeStages.length === 0) return '<p>No per-stage data available yet.</p>';
    var maxAvg = 1;
    for (var t = 0; t < activeStages.length; t++) { var a = stageTurnCount[activeStages[t]] ? stageTotals[activeStages[t]].turns / stageTurnCount[activeStages[t]] : 0; if (a > maxAvg) maxAvg = a; }
    var html = '<table class="breakdown-table"><thead><tr><th>Stage</th><th>Avg Turns</th><th>Last Run</th><th>Avg Time</th><th class="bar-chart-cell">Distribution</th></tr></thead><tbody>';
    for (var b = 0; b < activeStages.length; b++) {
      sn = activeStages[b]; var cnt = stageTurnCount[sn] || 1;
      var avgT = Math.round(stageTotals[sn].turns / cnt);
      var lsd = lastStages[sn];
      var lastCell = '-';
      if (lsd) {
        var lt = lsd.turns || 0, lb = lsd.budget || 0;
        if (lb > 0) {
          var lbu = Math.round((lt / lb) * 100);
          var lbc = lbu >= 100 ? 'budget-red' : lbu >= 80 ? 'budget-amber' : 'budget-green';
          lastCell = lt + '/' + lb + ' <span class="' + lbc + '">(' + lbu + '%)</span>';
        } else {
          lastCell = '' + lt;
        }
      }
      var timeCnt = stageTimeCount[sn];
      var avgTime = timeCnt > 0 ? Math.round(stageTotals[sn].time / timeCnt) : 0;
      html += '<tr><td>' + (stageLabels[sn] || sn) + '</td><td>' + avgT + '</td>';
      html += '<td>' + lastCell + '</td>';
      html += '<td>' + (avgTime > 0 ? fmtDuration(avgTime) : '-') + '</td>';
      html += '<td class="bar-chart-cell"><div class="bar-wrap"><div class="bar-fill" style="width:' + Math.round((avgT / maxAvg) * 100) + '%"></div></div></td></tr>';
    }
    return html + '</tbody></table>';
  }

  function renderTeamPerformance(runs) {
    // Collect team stats from runs that have a team field
    var teamStats = {}, hasAny = false;
    for (var i = 0; i < runs.length; i++) {
      var t = runs[i].team || runs[i].parallel_group;
      if (!t) continue;
      hasAny = true;
      if (!teamStats[t]) teamStats[t] = { runs: 0, turns: 0, time: 0, success: 0 };
      teamStats[t].runs++;
      teamStats[t].turns += (runs[i].total_turns || 0);
      teamStats[t].time += (runs[i].total_time_s || 0);
      var oc = (runs[i].outcome || '').toLowerCase();
      if (oc === 'success' || oc === 'pass') teamStats[t].success++;
    }
    if (!hasAny) return '';
    var teamNames = []; for (var tn in teamStats) if (teamStats.hasOwnProperty(tn)) teamNames.push(tn);
    teamNames.sort();
    var maxTurns = 1;
    for (var m = 0; m < teamNames.length; m++) {
      var avg = teamStats[teamNames[m]].turns / teamStats[teamNames[m]].runs;
      if (avg > maxTurns) maxTurns = avg;
    }
    var html = '<div class="card trend-section" style="margin-top:0.75rem"><h3>Per-Team Performance</h3>';
    html += '<table class="breakdown-table"><thead><tr><th>Team</th><th>Runs</th><th>Avg Turns</th><th>Avg Duration</th><th>Success Rate</th><th class="bar-chart-cell">Turns</th></tr></thead><tbody>';
    for (var j = 0; j < teamNames.length; j++) {
      var ts = teamStats[teamNames[j]], avgT = Math.round(ts.turns / ts.runs), avgD = Math.round(ts.time / ts.runs), sr = Math.round((ts.success / ts.runs) * 100);
      var color = getTeamColor(teamNames[j], teamNames);
      html += '<tr><td><span style="color:' + color + ';font-weight:700">' + esc(teamNames[j]) + '</span></td>';
      html += '<td>' + ts.runs + '</td><td>' + avgT + '</td><td>' + fmtDuration(avgD) + '</td><td>' + sr + '%</td>';
      html += '<td class="bar-chart-cell"><div class="bar-wrap"><div class="bar-fill" style="width:' + Math.round((avgT / maxTurns) * 100) + '%;background:' + color + '"></div></div></td></tr>';
    }
    html += '</tbody></table></div>';
    return html;
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
    h += '<div class="form-group"><label>Parallel Group (optional)</label><input type="text" id="ms-group" list="ms-group-list" placeholder="Type new or pick existing">';
    h += '<datalist id="ms-group-list">';
    for (var g = 0; g < groups.length; g++) h += '<option value="' + esc(groups[g]) + '">';
    h += '</datalist><div class="form-hint">Free-text: type any group name</div></div>';
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
            if (group.trim()) { var dl = document.getElementById('ms-group-list'); if (dl) { var dup = false; for (var o = 0; o < dl.options.length; o++) if (dl.options[o].value === group.trim()) { dup = true; break; } if (!dup) { var opt = document.createElement('option'); opt.value = group.trim(); dl.appendChild(opt); } } }
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
      buildCausalIndex();
      renderLiveRunBanner();
      var active = getActiveTab();
      if (active === 'reports') renderActiveTab();
      updateStatusIndicator(); checkRefreshLifecycle();
    }).catch(function (err) { if (typeof console !== 'undefined') console.error('Watchtower refresh failed:', err); scheduleRefresh(); });
  }
  function checkRefreshLifecycle() {
    var s = state(), status = (s.pipeline_status || '').toLowerCase();
    if (s.completed_at || status === 'pass' || status === 'complete' || status === 'failed') {
      if (!refreshStopped) { refreshStopped = true; updateRefreshIndicator(true); }
      return;
    }
    if (!refreshStopped && (status === 'running' || status === 'initializing' || status === 'waiting')) scheduleRefresh();
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
    buildCausalIndex(); updateStatusIndicator(); initTheme(); initTabs(); renderLiveRunBanner();
    var btn = document.getElementById('manual-refresh');
    if (btn) btn.addEventListener('click', manualRefresh);
    document.addEventListener('click', function (e) {
      var link = e.target.closest('[data-ms-link]');
      if (!link) return;
      e.preventDefault();
      var msId = link.getAttribute('data-ms-link');
      switchTab('milestones');
      setTimeout(function () { scrollToMilestone(msId); }, 100);
    });
    checkRefreshLifecycle();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', render); else render();
})();
