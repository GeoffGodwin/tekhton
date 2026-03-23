
#### Milestone 13: Watchtower Data Layer & Causal Event Log
<!-- milestone-meta
id: "13"
status: "done"
-->
<!-- PM-tweaked: 2026-03-23 -->

Pipeline-side event emission system built on a **causal event log** — a structured
JSONL file where every pipeline event carries a unique ID and causal edges linking
it to the events that triggered it. The causal log is the primary data store;
Watchtower JS files are materialized views over it.

This is not just a dashboard data layer — it's Tekhton's **structured memory**.
Every stage transition, verdict, finding, rework cycle, and milestone state change
is recorded with causal provenance. Downstream consumers (M17 Diagnostics, M10 PM
Agent, M16 Autonomous Runtime) query the causal log for root-cause analysis,
pattern detection, and history-aware judgment. The Watchtower dashboard renders it.

The design is inspired by effect system architectures where agents declare intent
and the host records outcomes. Tekhton's judgment agents (reviewer, security, intake)
already emit structured verdicts that the shell interprets — this milestone formalizes
that pattern into a queryable causal graph stored as flat files.

Files to create:
- `lib/causality.sh` — Causal event log infrastructure:
  **Event schema:**
  Every event in the causal log is a single JSON line with these fields:
  ```json
  {
    "id": "coder.003",
    "ts": "2024-01-15T10:08:12Z",
    "run_id": "run_20240115_100000",
    "milestone": "m03",
    "type": "stage_end",
    "stage": "coder",
    "detail": "6 files modified",
    "caused_by": ["scout.001"],
    "verdict": null,
    "context": { "files_changed": 6, "turns_used": 22 }
  }
  ```
  Fields: `id` (unique within run: `stage.sequence_number`), `ts` (ISO 8601),
  `run_id` (links events across runs), `milestone` (active milestone ID or null),
  `type` (event type), `stage` (which stage emitted), `detail` (human-readable),
  `caused_by` (array of event IDs that triggered this event — the causal edges),
  `verdict` (structured verdict if this is a judgment event, null otherwise),
  `context` (type-specific structured data).

  **Event types:**
  pipeline_start, pipeline_end, stage_start, stage_end, verdict (intake, review,
  security), finding (security), build_gate (pass/fail), rework_trigger,
  rework_cycle, milestone_advance, milestone_split, human_wait, error,
  quota_pause, quota_resume, continuation, transient_retry.

  **Causal edge rules (how caused_by is populated):**
  - `stage_start` caused_by the previous `stage_end` (or `pipeline_start`)
  - `rework_trigger` caused_by the `verdict` event that returned CHANGES_REQUIRED
  - `rework_cycle` caused_by the `rework_trigger`
  - `build_gate` caused_by the `stage_end` of coder (or rework cycle)
  - `finding` caused_by the `stage_start` of security
  - `milestone_split` caused_by the `error` or `verdict` that triggered splitting
  - `error` caused_by the `stage_start` of the failing stage
  - `quota_resume` caused_by `quota_pause`
  The shell populates `caused_by` at each emission site — it knows what triggered
  the current action because it controls the flow.

  **Core functions:**
  - `emit_event(type, stage, detail, caused_by, verdict, context)` — Append a
    JSON line to `CAUSAL_LOG_FILE` (`.claude/logs/CAUSAL_LOG.jsonl`). Auto-assigns
    monotonic event ID via `_next_event_id(stage)`. Returns the assigned event ID
    (captured by callers to pass as `caused_by` to downstream events). Also calls
    `_regenerate_timeline_js()` if dashboard is enabled.
  - `_next_event_id(stage)` — Returns `stage.NNN` using a per-stage counter stored
    in `_EVENT_SEQ` associative array (bash 4+). Counter resets per run.
  - `_last_event_id()` — Returns the most recently emitted event ID. Convenience
    for linear cause chains where each event is caused by the previous one.

  **Query functions (consumed by M17 Diagnostics, M10 PM Agent, etc.):**
  - `trace_cause_chain(event_id)` — Walk `caused_by` edges backward from the given
    event, printing each ancestor event. Returns the chain as newline-delimited
    JSON lines. Uses grep + associative array lookup on the in-memory log.
  - `trace_effect_chain(event_id)` — Walk forward: find all events whose
    `caused_by` array contains this event ID. Breadth-first traversal.
  - `events_for_milestone(milestone_id, [run_id])` — Filter log by milestone field.
    Optional run_id filter; defaults to current run.
  - `events_by_type(event_type, [lookback_runs])` — Return events of a given type
    across the last N runs. Reads from archived causal logs.
  - `recurring_pattern(event_type, lookback_runs)` — Count occurrences of an event
    type across runs. Returns count + list of run_ids where it occurred.
  - `verdict_history(stage, lookback_runs)` — Extract all verdict events for a
    stage across recent runs. Used by M10 PM Agent for calibration.
  - `cause_chain_summary(event_id)` — Produce a human-readable one-line summary
    of the causal chain: "BUILD_FAILURE ← coder.stage_end ← scout.stage_end".
    Used by M17 Diagnostics for the terminal summary.

  **Log lifecycle:**
  - At pipeline start: create new CAUSAL_LOG.jsonl (or append if resuming).
    Set `_CURRENT_RUN_ID` from session timestamp.
  - At pipeline end: copy CAUSAL_LOG.jsonl to `.claude/logs/runs/CAUSAL_LOG_${RUN_ID}.jsonl`
    for cross-run queries. Prune archives older than CAUSAL_LOG_RETENTION_RUNS.
  - The causal log is append-only during a run. Never modified in place.

- `lib/dashboard.sh` — Dashboard data emission module (views over causal log):
  **Event emission:**
  - `emit_dashboard_event(event_type, stage, detail, caused_by)` — Wrapper around
    `emit_event()` that also regenerates the dashboard JS view files. Events include
    all types from `lib/causality.sh`. The `caused_by` parameter accepts a
    comma-separated string of event IDs (or empty string for root events).
  - Dashboard JS files are materialized views regenerated from the causal log,
    NOT the primary store.
  **State emission:**
  - `emit_dashboard_run_state()` — Read current pipeline state and generate
    `data/run_state.js`. Includes: current stage, active milestone, turns used
    vs budget per stage, elapsed time, pipeline status (running/paused/complete/
    failed), what it's waiting for (if paused).
  - `emit_dashboard_milestones()` — Read MANIFEST.cfg and generate
    `data/milestones.js`. Includes: all milestones with id, title, status,
    dependencies, parallel_group, intake confidence score (if evaluated),
    PM tweaks applied (if any), security finding count (if scanned).
  - `emit_dashboard_security()` — Read SECURITY_REPORT.md and SECURITY_NOTES.md,
    generate `data/security.js`. Includes: findings array with severity, category,
    file, fixable, fix_status (fixed/escalated/waivered/unfixed).
  - `emit_dashboard_reports()` — Read stage reports (INTAKE_REPORT.md,
    SCOUT_REPORT.md, CODER_SUMMARY.md, REVIEWER_REPORT.md, TEST_RESULTS.md)
    and generate `data/reports.js`. Each report parsed from markdown to structured
    data (not raw markdown — extracted sections and key values).
  - `emit_dashboard_metrics()` — Read RUN_SUMMARY.json files from the last
    DASHBOARD_HISTORY_DEPTH runs (default 50), generate `data/metrics.js`.
    Includes: per-run stats (turns, duration, outcome, stage breakdown),
    aggregated trends (average turns per stage, rejection rate, split frequency).
  **Lifecycle:**
  - `init_dashboard(project_dir)` — Create `.claude/dashboard/` directory,
    copy static files (index.html, app.js, style.css) from
    `${TEKHTON_HOME}/templates/watchtower/`, create `data/` subdirectory,
    generate initial data files with empty/default state. Called by --init.
  - `cleanup_dashboard(project_dir)` — Remove `.claude/dashboard/` directory.
    Called when DASHBOARD_ENABLED transitions from true to false.
  - `is_dashboard_enabled()` — Check DASHBOARD_ENABLED config. Returns 0/1.

  **CLI progress heartbeat:**
  The existing spinner in `lib/agent.sh` (elapsed time display) is enhanced
  to also show turn count and stage context. During agent runs, the spinner
  line becomes:
  `[tekhton] Coder (4m12s, 14/25 turns)`
  `[tekhton] Security (1m03s, 6/15 turns)`
  This runs in the same spinner PID — no new processes. The heartbeat also
  triggers `emit_dashboard_run_state()` on a configurable interval
  (DASHBOARD_REFRESH_INTERVAL, default 10s) so Watchtower picks up mid-stage
  progress, not just stage boundaries.

  **Verbosity levels:**
  - `DASHBOARD_VERBOSITY=normal` (default): stage start/end, verdicts, findings,
    milestone changes, build gate results.
  - `DASHBOARD_VERBOSITY=minimal`: stage end only, final verdicts only.
  - `DASHBOARD_VERBOSITY=verbose`: all of normal + individual agent turn counts,
    rework cycle events, context budget utilization, template variable sizes,
    continuation attempts, transient retry events.

  **Data format (JS global assignments):**
  Each `.js` file in `data/` follows the pattern:
  ```javascript
  // Generated by Tekhton Watchtower — do not edit
  // Updated: 2024-01-15T10:03:42Z
  window.TK_RUN_STATE = {
    pipeline_status: "running",
    current_stage: "security",
    active_milestone: { id: "m03", title: "..." },
    stages: {
      intake: { status: "complete", turns: 4, budget: 10, duration_s: 12 },
      scout: { status: "complete", turns: 8, budget: 15, duration_s: 34 },
      coder: { status: "complete", turns: 22, budget: 30, duration_s: 187 },
      build_gate: { status: "pass" },
      security: { status: "running", turns: 6, budget: 15, elapsed_s: 45 },
      reviewer: { status: "pending" },
      tester: { status: "pending" }
    },
    waiting_for: null,
    started_at: "2024-01-15T10:00:00Z"
  };
  ```
  Timeline events include causal edges for UI rendering:
  ```javascript
  window.TK_TIMELINE = [
    { id: "pipeline.001", ts: "...", type: "pipeline_start", caused_by: [], ... },
    { id: "intake.001", ts: "...", type: "stage_start", stage: "intake",
      caused_by: ["pipeline.001"], ... },
    { id: "intake.002", ts: "...", type: "verdict", stage: "intake",
      verdict: { result: "PASS", confidence: 82 },
      caused_by: ["intake.001"], ... },
    { id: "security.002", ts: "...", type: "finding", stage: "security",
      detail: "SQL injection in handler.py:42",
      caused_by: ["security.001"],
      context: { severity: "MEDIUM", category: "A03", fixable: true }, ... },
    { id: "review.002", ts: "...", type: "rework_trigger", stage: "review",
      caused_by: ["review.001"],
      detail: "CHANGES_REQUIRED — 3 findings", ... }
  ];
  ```

  **Emit timing (when data files are regenerated):**
  - `run_state.js` — on every stage transition + every 30s during active stage
  - `timeline.js` — on every event (append + regenerate)
  - `milestones.js` — on milestone state change (advance, split, done)
  - `security.js` — after security stage completes
  - `reports.js` — after each stage that produces a report
  - `metrics.js` — on pipeline completion only (reads historical RUN_SUMMARY files)

- `lib/dashboard_parsers.sh` — Report parsing functions:
  - `_parse_security_report(file)` — Extract findings from SECURITY_REPORT.md
    into structured pipe-delimited format for JS generation.
  - `_parse_intake_report(file)` — Extract verdict, confidence, tweaks from
    INTAKE_REPORT.md.
  - `_parse_coder_summary(file)` — Extract file list, change summary from
    CODER_SUMMARY.md.
  - `_parse_reviewer_report(file)` — Extract verdict, feedback items from
    reviewer output.
  - `_parse_run_summaries(dir, depth)` — Read last N RUN_SUMMARY.json files,
    extract per-run metrics. Uses `python3 -c` for JSON parsing if available,
    falls back to grep/awk extraction for key fields.
  - `_to_js_string(varname, json_content)` — Wrap JSON content in a JS global
    assignment: `window.${varname} = ${json_content};`
  - `_to_js_timestamp()` — Current ISO 8601 timestamp for the generated header.

Files to modify:
- `tekhton.sh` — Source `lib/causality.sh` and `lib/dashboard.sh`. At startup:
  - Always initialize the causal event log (`init_causal_log()`). The causal log
    is independent of the dashboard — it runs even when DASHBOARD_ENABLED=false.
  - Check `is_dashboard_enabled()`: if enabled and `.claude/dashboard/` doesn't
    exist, run `init_dashboard()`. If disabled and exists, run `cleanup_dashboard()`.
  - Emit `pipeline_start` event (root event, no caused_by). Capture its event ID.
  - Pass event IDs between stage calls so each stage knows its causal parent.
  Insert `emit_event()` calls at each stage transition point. Each call captures
  the returned event ID and passes it as `caused_by` to the next stage's events.
  On pipeline completion, call `emit_dashboard_metrics()` and archive the causal log.
  **Event ID threading pattern:**
  ```bash
  local pipeline_evt
  pipeline_evt=$(emit_event "pipeline_start" "pipeline" "$TASK" "" "" "")
  # ... later:
  local intake_start_evt
  intake_start_evt=$(emit_event "stage_start" "intake" "" "$pipeline_evt" "" "")
  ```
- `lib/agent.sh` — [PM: added to Files to modify; required for CLI progress heartbeat] Enhance the existing spinner loop to display stage name and turn count alongside elapsed time: `[tekhton] Coder (4m12s, 14/25 turns)`. The spinner already has elapsed-time logic — extend it to accept stage name and turn-budget parameters passed from the call site. Also trigger `emit_dashboard_run_state()` on the DASHBOARD_REFRESH_INTERVAL tick within the existing monitor loop.
- `stages/coder.sh` — Emit `stage_start` (caused_by previous stage_end),
  `stage_end` with file change context. Capture event IDs for build_gate linkage.
  Emit `emit_dashboard_reports` after coder completes.
- `stages/security.sh` — Emit `stage_start`, individual `finding` events
  (each caused_by the stage_start), `verdict` event. Call `emit_dashboard_security`
  after security stage. Each finding event carries severity/category in context.
- `stages/review.sh` — Emit `verdict` event. If CHANGES_REQUIRED, emit
  `rework_trigger` event (caused_by the verdict), then `rework_cycle` events
  for each iteration (each caused_by the rework_trigger).
- `stages/tester.sh` — Emit `stage_end` with test result context.
- `stages/intake.sh` — Emit `verdict` event with confidence score in context.
  If TWEAKED, the tweak details go in the event context.
- `lib/milestone_ops.sh` — Emit `milestone_advance` or `milestone_split` events
  (caused_by the verdict or error that triggered the transition). Call
  `emit_dashboard_milestones()` after any milestone state change.
- `lib/config_defaults.sh` — Add:
  DASHBOARD_ENABLED=true,
  DASHBOARD_VERBOSITY=normal (minimal|normal|verbose),
  DASHBOARD_HISTORY_DEPTH=50,
  DASHBOARD_REFRESH_INTERVAL=5 (seconds, written into generated HTML meta),
  DASHBOARD_DIR=.claude/dashboard,
  CAUSAL_LOG_FILE=.claude/logs/CAUSAL_LOG.jsonl,
  CAUSAL_LOG_RETENTION_RUNS=50,
  CAUSAL_LOG_ENABLED=true,
  CAUSAL_LOG_MAX_EVENTS=2000, [PM: added; Watch For references this cap but it was absent from the config_defaults list — needs a default so cap logic has a value to read]
  DASHBOARD_MAX_TIMELINE_EVENTS=500 [PM: added; Watch For references this cap for timeline JS but it was absent from the config_defaults list]
- `lib/config.sh` — Validate DASHBOARD_* and CAUSAL_LOG_* keys. DASHBOARD_VERBOSITY
  must be one of minimal|normal|verbose. DASHBOARD_HISTORY_DEPTH must be 1-100.
  CAUSAL_LOG_RETENTION_RUNS must be 1-200. [PM: also validate CAUSAL_LOG_MAX_EVENTS (1-10000) and DASHBOARD_MAX_TIMELINE_EVENTS (1-2000)]
- `lib/hooks.sh` — Add `.claude/dashboard/data/` to archive exclusion list
  (data files are regenerated, not archived). CAUSAL_LOG.jsonl IS archived
  (it's the primary historical record).
- `lib/finalize.sh` — Call `emit_dashboard_metrics()` and
  `emit_dashboard_run_state()` with final status during finalization. Archive
  the causal log to `.claude/logs/runs/CAUSAL_LOG_${RUN_ID}.jsonl`. Prune
  archived logs beyond CAUSAL_LOG_RETENTION_RUNS.

**Migration Impact:** [PM: added; required for new config keys]
New keys added to `config_defaults.sh` with safe defaults — no action required
for existing projects. All new keys are opt-in or default-on with conservative
defaults (DASHBOARD_ENABLED=true creates `.claude/dashboard/` on next run;
CAUSAL_LOG_ENABLED=true writes `.claude/logs/CAUSAL_LOG.jsonl`). Projects that
do not want the dashboard directory created should set DASHBOARD_ENABLED=false
before upgrading. Recommend adding `.claude/dashboard/data/` to `.gitignore`
(data files regenerate each run); the static files under `.claude/dashboard/`
and `CAUSAL_LOG.jsonl` can be committed. `CAUSAL_LOG_MAX_EVENTS` and
`DASHBOARD_MAX_TIMELINE_EVENTS` are new config keys — existing pipeline.conf
files will use the defaults silently.

Acceptance criteria:
**Causal event log (lib/causality.sh):**
- `emit_event()` appends a valid JSON line to CAUSAL_LOG.jsonl with all schema
  fields (id, ts, run_id, milestone, type, stage, detail, caused_by, verdict, context)
- `emit_event()` returns the assigned event ID so callers can thread causality
- Event IDs are unique within a run (stage.sequence_number format)
- `caused_by` arrays correctly link events: rework_trigger → verdict,
  stage_start → previous stage_end, build_gate → coder stage_end, etc.
- `trace_cause_chain()` walks backward through caused_by edges and returns
  ancestor events in causal order
- `trace_effect_chain()` walks forward and returns descendant events
- `events_for_milestone()` filters events by milestone ID
- `events_by_type()` returns events of a given type across multiple runs
- `recurring_pattern()` counts event type occurrences across archived logs
- `verdict_history()` extracts verdict events for a stage across recent runs
- `cause_chain_summary()` produces a human-readable one-line causal chain
- Causal log is archived to `.claude/logs/runs/` on pipeline completion
- Archived logs are pruned beyond CAUSAL_LOG_RETENTION_RUNS
- When CAUSAL_LOG_ENABLED=false, emit_event is a no-op returning synthetic IDs
- Causal log runs independently of DASHBOARD_ENABLED (it's infrastructure, not UI)
- [PM: added] Causal log is capped at CAUSAL_LOG_MAX_EVENTS per run; oldest events are evicted when cap is reached
**Dashboard (lib/dashboard.sh):**
- `init_dashboard()` creates `.claude/dashboard/` with static files + data dir
- `cleanup_dashboard()` removes `.claude/dashboard/` cleanly
- Config transition: setting DASHBOARD_ENABLED=false cleans up dashboard dir
  on next run; setting it back to true recreates it
- Dashboard JS files are materialized views regenerated from the causal log
- `emit_dashboard_run_state()` produces valid JS with current pipeline state
- `emit_dashboard_milestones()` reads MANIFEST.cfg and produces valid JS
- `emit_dashboard_security()` parses SECURITY_REPORT.md into structured JS
- `emit_dashboard_reports()` parses each stage report into structured JS
- `emit_dashboard_metrics()` reads up to DASHBOARD_HISTORY_DEPTH RUN_SUMMARY
  files and produces trend data
- Timeline JS includes causal edges (caused_by arrays) for each event
- [PM: added] Timeline JS is capped at DASHBOARD_MAX_TIMELINE_EVENTS entries
- All `.js` data files follow `window.TK_* = { ... };` pattern
- All data files include generation timestamp in header comment
- Verbosity levels control event granularity:
  minimal emits stage_end + final verdicts only,
  normal adds stage_start + findings + build gate,
  verbose adds turn counts + rework events + context budget
- Dashboard data files are excluded from pipeline archives
- When DASHBOARD_ENABLED=false, dashboard emit functions are no-ops (zero overhead)
- All existing tests pass
- `bash -n lib/causality.sh lib/dashboard.sh lib/dashboard_parsers.sh` passes
- `shellcheck lib/causality.sh lib/dashboard.sh lib/dashboard_parsers.sh` passes
- New test file `tests/test_causal_log.sh` covers: event emission, ID assignment,
  caused_by threading, cause chain traversal, effect chain traversal, cross-run
  queries, log archival, log pruning, milestone filtering
- New test file `tests/test_dashboard_data.sh` covers: init, cleanup, JS view
  generation from causal log, state generation, report parsing, config transitions
**CLI progress heartbeat:**
- Agent spinner shows stage name, elapsed time, AND turn count (e.g.,
  "Coder (4m12s, 14/25 turns)")
- Watchtower run_state.js refreshed during active agent runs at
  DASHBOARD_REFRESH_INTERVAL (default 10s), not just at stage boundaries
- Heartbeat refresh uses existing agent_monitor loop (no new background process)

Watch For:
- JSON generation in pure bash is fragile. Use printf with proper escaping for
  string values. Special characters in report content (quotes, newlines,
  backslashes) must be escaped for valid JS. Consider a `_json_escape()` helper.
  The causal log uses the same escaping for JSONL — share the helper.
- The 30-second periodic refresh of run_state.js during active stages needs a
  lightweight mechanism — NOT a background process. Use the existing
  agent_monitor loop to trigger it (it already runs periodically).
- RUN_SUMMARY.json parsing: prefer python3 -c for JSON if available, but the
  fallback grep/awk path must handle the full format. Test both paths.
- The `.claude/dashboard/data/` directory will contain generated files that
  change every run. Add it to `.gitignore` recommendations during --init.
  The static files (index.html, app.js, style.css) CAN be committed.
  CAUSAL_LOG.jsonl should NOT be gitignored — it's a valuable project artifact.
- File locking: multiple emit calls could race if the pipeline has concurrent
  operations (future V4 parallel). Use atomic writes (tmpfile + mv) for all
  data file generation, same pattern as manifest writes. The causal log itself
  is append-only (no races for appends in single-process bash).
- The causal log can grow large on verbose runs with many rework cycles. Cap
  at CAUSAL_LOG_MAX_EVENTS (default 2000) per run with oldest-first eviction
  (keep the most recent events, they're most diagnostically useful). The
  dashboard timeline JS caps separately at DASHBOARD_MAX_TIMELINE_EVENTS (500).
- **Event ID threading requires discipline at every emission site.** Each
  `emit_event()` call must capture the returned ID and pass it forward. If a
  call site forgets, downstream events will have empty caused_by arrays —
  functional but causally disconnected. The test suite should verify that
  no event (except pipeline_start) has an empty caused_by in a normal run.
- **Cross-run queries read archived JSONL files.** For 50 retained runs with
  2000 events each, that's 100k lines. Query functions must use grep with
  targeted patterns (type filter first, then parse matching lines), not load
  everything into memory. Profile with realistic log sizes.
- The `_EVENT_SEQ` associative array (per-stage counters) must be declared
  with `declare -A` (bash 4+ — already enforced by Tekhton).
- `caused_by` is always an array, even for single causes. This keeps the
  schema consistent and supports future fan-in events (e.g., a milestone_advance
  caused by both the tester verdict and the acceptance check).

Seeds Forward:
- **M17 (Diagnostics)** queries the causal log for root-cause chains instead
  of pattern-matching against state files alone
- **M10 (PM Agent)** queries verdict_history() for calibration data —
  historical verdict accuracy, typical rework cycle counts for similar milestones
- **M14 (Watchtower UI)** renders causal edges in the timeline (click event
  to highlight its cause chain)
- **M16 (Autonomous Runtime)** uses causal event counts for smarter progress
  detection (events emitted = work happening, even without git diff changes)
- V4 server-based dashboard replaces file polling with WebSocket push but
  the causal log format and TK_* globals remain identical
- V4 metric connectors (DataDog, NewRelic) consume the same structured data
- V4 full effect system: when Claude CLI supports tool-use event streams,
  the causal log becomes the intercept layer for coder/tester execution events.
  The infrastructure built here is the foundation for that transition.
- The causal log is a natural fit for future LLM-based post-mortem analysis —
  feed the log to an agent and ask "why did this run fail?"
