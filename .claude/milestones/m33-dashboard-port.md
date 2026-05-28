<!-- milestone-meta
id: "33"
status: "split"
-->

# m33 — Dashboard Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — penultimate bash-subsystem port of the Watchtower data layer. M21 ported finalize. M22 ported preflight. M23 ported the TUI ops bash glue (the `tui_status.json` writer; `tools/tui.py` stays). M24 ported notes. M25 ported drift+clarify. M26/M27 closed the env contract. The Watchtower dashboard data layer — the bash files that *write* `.claude/dashboard/data/*.js` and the parsers that *read* the stage report files those emitters consume — is the last large bash subsystem on the dogfood-able critical path. After M33 the only meaningful bash remaining under `lib/` is the legacy-only `tekhton-legacy.sh` shell entry, the per-stage stubs that exec into Go, and a handful of leaf utilities. |
| **Gap** | `lib/dashboard.sh` + `lib/dashboard_emitters.sh` + `lib/dashboard_parsers.sh` + `lib/dashboard_parsers_runs.sh` + `lib/dashboard_parsers_runs_files.sh` total 1547 lines of bash that run on every finalize pass. The 13 `emit_dashboard_*` / `_regenerate_*` functions write 10 JSON-in-JS files under `.claude/dashboard/data/` consumed by `templates/watchtower/app.js` (browser, static site) and by the Python sidecar tick reader. The schemas are ad-hoc — no versioned proto — so a typo in any emitter silently produces a payload the parser can't round-trip. The write side and read side share a private contract that today only exists in the heads of the bash authors and in the `_parse_*` regex patterns. |
| **m33 fills** | This is a **split** milestone. Implementation lands as two children: **m33.1** (WRITE side — emitters) and **m33.2** (READ side — parsers, which depends on m33.1 because the emitter freezes the proto). The parent file (this one) captures: (a) the `internal/dashboard/` Go package shape both children share; (b) the `tekhton dashboard <subcommand>` Cobra surface; (c) the `dashboard.v1` proto family under `internal/proto/` that formalizes the 10 JSON shapes; (d) the relationship to the existing TUI ports (`internal/tui/`, `tui_status.json` — different schema, different code path, kept separate); (e) the dependency hand-off from the bash finalize hooks (`lib/finalize_dashboard_hooks.sh` keeps wrapping the calls; only the call body changes). No code lands at the parent level; status moves to `split` on manifest sync. |
| **Depends on** | m27 |
| **Files changed** | (parent) None directly — see m33.1 and m33.2 children. The parent file documents the shared design; the manifest entry tracks it as `split`. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m21 | Finalize orchestrator port. Established the "bash hooks wrap Go subsystem calls" pattern m33 inherits. `lib/finalize_dashboard_hooks.sh` is the wrapper. |
| m23 | TUI ops port. Established the proto-versioned JSON envelope pattern (`tekhton.tui.status.v1`) m33 reuses. The TUI sidecar's `tui_status.json` is a *different* file from any dashboard emission — Watch For below. |
| m25 | Drift+clarify port. Most recent bash-subsystem port; reference for the "delete the bash files, route the bash callers through the Go binary" cleanup ritual. |
| m27 | Env contract hardening. The contract that the bash dashboard emitters currently read (PROJECT_DIR, DASHBOARD_DIR, CURRENT_STAGE, PIPELINE_STATUS, _STAGE_* arrays) all flows through `StageEnvV1`. The Go port reads the same vars from `internal/runner/env.go`. |
| **m33** | **Dashboard data layer ported to Go. Five bash files delete; the Python sidecar and the static Watchtower site continue to consume the same JSON files, now written by Go with versioned proto envelopes.** |

---

## Design

### Sequencing note

m33 splits because the write side (m33.1, ~992 LOC of bash → Go) and the read side (m33.2, ~555 LOC of bash → Go) form a producer/consumer pair where the producer must land first. The proto envelope frozen in m33.1 is what m33.2's parsers round-trip against. Trying to land both in one milestone produces a single oversized commit (the m21-finalize port at ~1500 LOC drove 17 patch bumps; this would be similar or worse). Splitting also lets m33.1 be independently dogfood-able: after m33.1, the dashboard emitters are Go but the parsers are still bash reading from the same legacy report files — nothing breaks because the read side (parsers) only ingests *stage reports* like `SECURITY_REPORT.md`, not the dashboard files the emitter writes. Read and write sides of the dashboard are coupled by the static site's JS files, not by the bash code itself.

Land m33.1 before m33.2 strictly. Manifest reflects the dependency.

### Goal 1 — `internal/dashboard/` package shape (shared by m33.1 + m33.2)

```
internal/dashboard/
├── dashboard.go         # Lifecycle: init, sync_static_files, cleanup. m33.1.
├── emit.go              # Emitter type + per-shape write methods. m33.1.
├── emit_runstate.go     # emit_dashboard_run_state port. m33.1.
├── emit_timeline.go     # _regenerate_timeline_js port. m33.1.
├── emit_milestones.go   # emit_dashboard_milestones port. m33.1.
├── emit_security.go     # emit_dashboard_security port. m33.1.
├── emit_reports.go      # emit_dashboard_reports port. m33.1.
├── emit_metrics.go      # emit_dashboard_metrics port. m33.1.
├── emit_health.go       # emit_dashboard_health port. m33.1.
├── emit_init.go         # emit_dashboard_init port. m33.1.
├── emit_inbox.go        # emit_dashboard_inbox + emit_dashboard_action_items + emit_dashboard_notes ports. m33.1.
├── parse.go             # StatusReader type; report parsers used by emitters and by external callers. m33.2.
├── parse_security.go    # _parse_security_report port. m33.2.
├── parse_intake.go      # _parse_intake_report port. m33.2.
├── parse_coder.go       # _parse_coder_summary port. m33.2.
├── parse_reviewer.go    # _parse_reviewer_report port. m33.2.
├── parse_runs.go        # _parse_run_summaries* family (metrics.jsonl primary, RUN_SUMMARY_*.json fallback). m33.2.
├── jsfile.go            # Atomic JS-file write (tempfile + rename, mirrors _write_js_file). m33.1.
├── testdata/            # Captured-run fixtures for parity gate. Populated incrementally m33.1 + m33.2.
└── *_test.go            # Per-shape unit tests + integration test calling Emitter end-to-end against a fixture project.
```

Key types:

```go
// Emitter is the WRITE side of the dashboard data layer. m33.1.
type Emitter struct {
    ProjectDir string
    DashDir    string // resolved from DashboardDir config; defaults to .claude/dashboard
    Now        func() time.Time // injectable for deterministic timestamps in tests
    Enabled    bool             // mirrors is_dashboard_enabled — short-circuit on false
}

// StatusReader is the READ side. Parses on-disk report files (security,
// intake, coder, reviewer, metrics.jsonl, RUN_SUMMARY_*.json) into the
// typed shapes the dashboard.v1 proto defines. m33.2.
type StatusReader struct {
    ProjectDir string
    LogDir     string
}
```

The Emitter and StatusReader are independent — neither imports the other — but both depend on `internal/proto/dashboard_v1.go` for the schemas.

### Goal 2 — `tekhton dashboard <subcommand>` CLI surface

Hidden Cobra subcommand tree, matching `tekhton finalize` and `tekhton preflight` precedent:

```
tekhton dashboard init           → Emitter.Init() — m33.1
tekhton dashboard sync           → Emitter.SyncStaticFiles() — m33.1
tekhton dashboard cleanup        → Emitter.Cleanup() — m33.1
tekhton dashboard emit run-state — Emitter.EmitRunState() — m33.1
tekhton dashboard emit timeline  — Emitter.EmitTimeline() — m33.1
tekhton dashboard emit metrics   — Emitter.EmitMetrics() — m33.1
tekhton dashboard emit reports   — Emitter.EmitReports() — m33.1
... (one per emit_dashboard_* function)
tekhton dashboard parse security <file> → StatusReader.ParseSecurity() — m33.2
tekhton dashboard parse intake <file>   → StatusReader.ParseIntake()   — m33.2
... (one per _parse_* function)
```

The `parse <kind> <file>` arms are developer-facing introspection — useful for piping a single report through the Go parser to see what shape it produces. The `emit <kind>` arms mirror the per-function bash entry points so the legacy bash callers can switch from `emit_dashboard_X` (sourced) to `tekhton dashboard emit X` (exec'd). All `tekhton dashboard` subcommands are Hidden in `--help` (developer/internal); end users invoke them transitively via finalize.

### Goal 3 — `internal/proto/dashboard_v1.go` — formalized JSON shapes

Each of the 10 JS data files (`run_state.js`, `timeline.js`, `milestones.js`, `security.js`, `reports.js`, `metrics.js`, `health.js`, `diagnosis.js`, `inbox.js`, `notes.js`) gains a Go struct with explicit JSON tags. The bash emitter today builds these by string-concatenating JSON inside `printf` calls; the Go port marshals from typed structs:

```go
// dashboard.v1 — schemas for the .claude/dashboard/data/*.js files.
const DashboardV1 = "tekhton.dashboard.v1"

// DashboardRunStateV1 — payload of data/run_state.js (window.TK_RUN_STATE).
type DashboardRunStateV1 struct {
    PipelineStatus     string                          `json:"pipeline_status"`
    CurrentStage       string                          `json:"current_stage"`
    ActiveMilestone    *DashboardMilestoneRef          `json:"active_milestone"` // nullable
    Stages             map[string]DashboardStageState  `json:"stages"`
    WaitingFor         *string                         `json:"waiting_for"`      // nullable
    StartedAt          string                          `json:"started_at"`
    CompletedAt        *string                         `json:"completed_at"`     // nullable
    ElapsedS           int                             `json:"elapsed_s"`
    EstimatedRemaining *int                            `json:"estimated_remaining_s"` // nullable
    RefreshIntervalMS  int                             `json:"refresh_interval_ms"`
    QuotaStatus        string                          `json:"quota_status"`
    QuotaPausedAt      string                          `json:"quota_paused_at"`
    QuotaRetryCount    int                             `json:"quota_retry_count"`
    ParallelMode       bool                            `json:"parallel_mode"`
    Teams              map[string]DashboardTeamState   `json:"teams"`
}
```

Identical pattern for `DashboardTimelineV1`, `DashboardMilestonesV1`, `DashboardSecurityV1`, `DashboardReportsV1`, `DashboardMetricsV1`, `DashboardHealthV1`, `DashboardDiagnosisV1`, `DashboardInboxV1`, `DashboardNotesV1`.

Important: the JS file format wraps the JSON payload in a `window.TK_<KIND> = <json>;` assignment. The proto is the payload, not the wrapper. The wrapper lives in `internal/dashboard/jsfile.go`'s `WriteJSFile(path, varname, payload)` helper, which serializes the payload via `encoding/json` then writes the JS scaffold atomically (tempfile + rename). The varname tag (`TK_RUN_STATE`, etc.) stays on the wrapper side.

A `dashboard.v1` envelope (proto tag + payload) is NOT introduced for these files. Reason: the static HTML site at `templates/watchtower/index.html` loads each `data/*.js` as a `<script>` tag and reads `window.TK_<KIND>` directly. Wrapping the payload in `{proto: ..., payload: {...}}` would require a parallel change to `templates/watchtower/app.js`, which is out of scope (per DESIGN_v4.md §6 the Python/JS sidecar is preserved). The proto tag is captured at the *type* level (`DashboardRunStateV1`) and asserted in the parity gate; the JS file payload stays bare for compatibility.

### Goal 4 — Bash caller hand-off

`lib/finalize_dashboard_hooks.sh` is the canonical caller surface. Its bodies look like:

```bash
if command -v emit_dashboard_run_state &>/dev/null; then
    emit_dashboard_run_state 2>/dev/null || true
fi
```

After m33.1 lands, those bodies route through the Go binary:

```bash
"${TEKHTON_BIN:-${TEKHTON_HOME:-.}/bin/tekhton}" dashboard emit run-state 2>/dev/null || true
```

The wrapper hook (`_hook_causal_log_finalize`, `_hook_final_dashboard_status`, etc.) stays bash because it composes multiple subsystem calls (causal log + dashboard + health + notes) in a known order. Only the per-emitter bodies switch. `lib/finalize_dashboard_hooks.sh` itself is in scope for **edit only**, not deletion. The five `lib/dashboard*.sh` files delete (m33.1 deletes the two write-side files; m33.2 deletes the three parser files).

### Goal 5 — Relationship to TUI (`internal/tui/`) — kept separate

The TUI sidecar (ported in m23) writes a different file (`.tekhton/.tui_status.json`) consumed by `tools/tui.py`. The dashboard subsystem writes 10 files under `.claude/dashboard/data/`, consumed by `templates/watchtower/app.js` (browser) and by a Python tick reader on the Python sidecar side (different from `tui.py`). These are two physically and logically distinct data layers with overlapping concepts (current stage, pipeline status) but different consumers, different cadence (TUI: every state mutation; dashboard: on finalize hooks), and different schemas (TUI status carries per-substage detail the dashboard run_state does not; dashboard run_state carries per-team parallel-mode state the TUI status does not).

Do not merge them. Do not import `internal/tui` from `internal/dashboard` (or vice versa). The fields they share (CurrentStage, PipelineStatus) are duplicated by design — the dashboard reads them from the bash globals via `StageEnvV1` and the TUI reads them from the supervisor's in-memory state. Two writers, two contracts, no shared types.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `.claude/milestones/MANIFEST.cfg` | Modify | Add three rows: `m33|Dashboard Port|split|m27|m33-dashboard-port.md|phase5`; `m33.1|Dashboard Emitters|todo|m27|m33.1-dashboard-emitters.md|`; `m33.2|Dashboard Parsers|todo|m33.1|m33.2-dashboard-parsers.md|`. Human handles the manifest edit as part of sequential review — NOT in scope for the m33 parent commit. |

The parent milestone produces no code. All deliverables land via m33.1 and m33.2.

---

## Acceptance Criteria

- [ ] `.claude/milestones/m33.1-dashboard-emitters.md` exists and parses against the milestone-meta linter (`id: "33.1"`, `status: "todo"`).
- [ ] `.claude/milestones/m33.2-dashboard-parsers.md` exists and parses against the milestone-meta linter (`id: "33.2"`, `status: "todo"`).
- [ ] Both child files declare `## Depends on` rows that match the planned MANIFEST.cfg entries (`m27` for m33.1; `m33.1` for m33.2).
- [ ] `internal/proto/dashboard_v1.go` is named (but not yet authored) in both children's Files Modified tables, with each child responsible for the subset of structs its scope produces (m33.1: emit-side structs; m33.2: parse-side structs).
- [ ] `internal/dashboard/` is named as the target package in both children.
- [ ] `tekhton dashboard <subcommand>` Cobra surface is described in m33.1 (registration) and extended in m33.2 (parse subarms).
- [ ] The parent file's status is `split` (not `todo`, not `done`) — per the m05 / m27 split-milestone precedent.
- [ ] The parent file emits no code-touching acceptance criteria; all observable predicates live in the children.

## Watch For

- **Watchtower as a separate distribution.** `templates/watchtower/` (the static site itself: `index.html`, `style.css`, `app.js`) is preserved indefinitely per DESIGN_v4.md §6. M33 ports only the bash WRITERS and READERS, not the JS frontend. A future V5 milestone could promote the Watchtower static site to a Go-served standalone process, but that is explicitly out of scope here.
- **The Python tick reader is also out of scope.** The dashboard data files are read by both a browser (loading the static site) and a Python tick process (the one inside `tools/` that watches `.claude/dashboard/data/` and pushes updates to a long-running web client). Both keep reading the JSON files; only the writers change. If the Python tick process needs schema introspection, it can call `tekhton dashboard parse <kind>` once m33.2 lands.
- **TUI vs dashboard.** The TUI port (m23, `internal/tui/`) and the dashboard port (m33, `internal/dashboard/`) are independent subsystems writing to different files for different consumers. Merging them is a category error: the TUI sidecar serves the terminal display, the dashboard serves the static web UI. They share concepts (current stage, pipeline status) but not contracts. Don't import `internal/tui` from `internal/dashboard`.
- **`lib/metrics_dashboard.sh` is NOT in scope.** Despite the name, that 233-line file is the bash `--metrics` CLI text-summary printer (an `lib/dashboard*.sh`-glob-miss). It ports separately in a future milestone (probably bundled with the `tekhton metrics` Cobra command). Touching it in m33 would expand scope and confuse the parity gate.
- **`lib/finalize_dashboard_hooks.sh` is the caller, not callee.** It composes per-emitter calls in a sequence the finalize chain depends on (causal log → run_state → metrics → milestones → health → action_items → notes). m33.1 edits its bodies to exec `tekhton dashboard emit <kind>` instead of calling sourced bash functions. The hook ordering must not change — verified by `internal/finalize/orchestrator_test.go`-style order tests if any need to be added. The file itself does NOT delete.
- **Five bash files delete, not four.** `lib/dashboard.sh`, `lib/dashboard_emitters.sh` (m33.1) and `lib/dashboard_parsers.sh`, `lib/dashboard_parsers_runs.sh`, `lib/dashboard_parsers_runs_files.sh` (m33.2). The parsers split into three files for the 300-line bash readability tax; in Go they collapse into one or two files under `internal/dashboard/`.

## Seeds Forward

- **m33.1 → m33.2 hand-off:** The emit-side proto structs (`DashboardSecurityV1`, `DashboardReportsV1`, `DashboardRunStateV1`, etc.) authored in m33.1 are exactly what the parse-side StatusReader in m33.2 must round-trip against. m33.2 cannot start until those structs are stable in `internal/proto/dashboard_v1.go`.
- **Watchtower V5 promotion:** Once both children land, `templates/watchtower/` is the only bash↔dashboard surface remaining. Promoting it to a Go-served process becomes a clean parallel-spine job — the data shapes are typed, the producers and consumers are decoupled, and the JS file format is a leaf concern.
- **Per-team parallel mode (M37 reference in `dashboard.sh:213`):** The Go emit_runstate must preserve the `_PARALLEL_TEAMS` / `_TEAM_*` array shape today's bash carries. Future parallel-execution work in V5+ will likely promote teams to typed structs, but m33.1 freezes the on-the-wire shape so the static site keeps working through that transition.
- **Proto registry:** `dashboard.v1` adds 10 new types to `internal/proto/`. A future maintenance milestone might add a registry index (`internal/proto/registry.go`) that enumerates every proto version live on disk so a `tekhton doctor` command can surface skew. m33 doesn't add the registry; it does ensure each new struct gets its own file and a top-of-file `// dashboard.v1.<kind>` comment so the registry is grep-able when it lands.
- **Dogfooding cadence:** m33.1 lands first (write side, ~992 LOC bash → Go). m33.2 lands second (read side, ~555 LOC bash → Go, smaller because the parsers are simpler). Both should be driven by their own `tekhton run --milestone m33.1 --complete` / `tekhton run --milestone m33.2 --complete` passes. Track patch bumps the same way m21 and m22 did.
