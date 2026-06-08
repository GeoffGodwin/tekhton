# V4 Phase 5 — Bash Deprecation Inventory (stub)

This is the pre-design inventory. It seeds the eventual `DESIGN_v5_phase5.md`
once the first Phase 5 milestone (m21) is authored. Treat the dispositions
below as candidate orderings, not commitments — the actual milestone graph
will be drawn after m21 surfaces real ordering constraints.

## Status as of m20 (4.20.0-dogfood)

`tekhton.sh` is a 75-line dispatcher. `tekhton run` (the Go binary) owns
every pipeline run. The remaining bash lives in:

- `tekhton-legacy.sh` — V3 entry-point body (~3050 lines, transition file).
- `lib/*.sh` — sourced subsystems that have not been ported.
- `stages/*.sh` — stage implementations called by the legacy entry point.
- `prompts/*.prompt.md` — prompt templates rendered by the Go engine.

Phase 5's end state, per `DESIGN_v4.md` Phase Plan: **Repository contains
no `.sh` files in `lib/` or `stages/`.**

## Inventory: bash subsystems still standing

The disposition column is one of:

- **port**: the subsystem has clear cross-language seams and is a clean
  port candidate for Phase 5.
- **shim**: the subsystem is a wedge shim already (the canonical owner is
  Go); cleanup is just deletion as soon as no callers remain.
- **leave**: the subsystem is bash-only by design (e.g., target-project
  install scripts, completion scripts) and Phase 5 does not touch it.

| # | Subsystem (`lib/` unless noted)        | Disposition | Notes |
|---|-----------------------------------------|-------------|-------|
| 1 | `finalize.sh` + 26 finalize hooks       | in progress (m21) | Orchestrator + 6 hooks in Go (`internal/finalize/`); 20 hooks routed through `lib/finalize_shim.sh`. Follow-up m22–m25 swap shim cases for Go bodies one subsystem at a time. |
| 2 | `preflight.sh` + checks/services       | done (m22)  | Subsystem ported in full to `internal/preflight/` — five Go check families (foundation, ui_audit, env, services_infer, services) registered behind `Orchestrator`. Six `lib/preflight*.sh` files deleted; `tekhton-legacy.sh::run_preflight_checks` execs `tekhton preflight`. M131 UI config audit (the behavior-heaviest sub-piece) ports cleanly with byte-identical report output validated by `tests/test_preflight_parity.sh`. |
| 3 | `tui_ops.sh` mid-run writers            | done (m23 — writers ported, six files deleted, finalize_shim arm removed) | Subsystem ported to `internal/tui/` — state.go + ops.go + pause.go + substage.go + builder.go + liveness.go all behind `tekhton tui …` Cobra subcommand. `tui.status.v1` proto formalised. Five satellite files (tui_helpers, tui_liveness, tui_ops, tui_ops_pause, tui_ops_substage) deleted; `lib/tui.sh` retained as a ~250-line thin shim (each `tui_*` function execs `tekhton tui …` so the 28+ existing bash callsites in agent.sh / quota.sh / stages/*.sh / tekhton-legacy.sh stay coherent). `_hook_tui_complete` ported to `internal/finalize/tui_complete.go` and removed from `lib/finalize_shim.sh`. Strategy A taken on Python: `tools/tui.py:_read_status` accepts both bare-payload (legacy) and envelope (m23) shapes. |
| 4 | `dashboard.sh` + emitters/parsers       | done (m33.2 — parsers ported, m33 arc closed) | Watchtower data-layer ported in full across the m33 arc. **WRITE side (m33.1):** `internal/dashboard/` ships the Emitter type, lifecycle (Init/SyncStaticFiles/Cleanup), 10 emit kinds, and `WriteJSFile` atomic writer; `internal/proto/dashboard_v1.go` formalises 13 typed payload structs. **READ side (m33.2):** `internal/dashboard/parse_*.go` ships the `StatusReader` with `ParseSecurity`/`ParseIntake`/`ParseCoder`/`ParseReviewer`/`ParseRunSummaries`; the metrics-jsonl parser's bash Python heredoc collapses into one Go path. `tekhton dashboard {init,sync,cleanup,emit,parse}` Cobra subcommand (Hidden). `lib/finalize_dashboard_hooks.sh` execs `tekhton dashboard emit <kind>` directly; `lib/dashboard.sh` + `lib/dashboard_emitters.sh` + `lib/dashboard_parsers.sh` + `lib/dashboard_parsers_runs.sh` + `lib/dashboard_parsers_runs_files.sh` deleted (1547 bash LOC removed across the arc); `lib/dashboard_shim.sh` retains the emit-side bash-compat function names for legacy callers. `tests/test_dashboard_emit_parity.sh` covers the WRITE contract (26 structural assertions); `tests/test_dashboard_parse_parity.sh` covers the READ contract (24 jq-driven assertions across 7 scenarios — security, intake×2 formats, coder, reviewer, runs-jsonl, runs-files). |
| 5 | `notes.sh` + variants (rewrite, cli, …) | done (m24 — fourteen files deleted, six finalize-shim arms removed, `tekhton note` joins the visible CLI surface) | Subsystem ported in full to `internal/notes/` (state / parser / extract / cleanup / acceptance / triage / migrate / rollback / single / add). `tekhton note add/list/done/reopen/claim/unclaim/triage/migrate/rollback/resolve` (visible) plus `pick-next/find/count/claim-bulk/resolve-bulk/clear-completed/done-fuzzy/should-claim/extract` (hidden). Six finalize hooks ported to `internal/finalize/{baseline_cleanup,express_persist,note_acceptance,failure_context_reset,cleanup_resolved,resolve_notes}.go`; three keep a narrow bash-delegate for cross-subsystem residue that ports in later milestones. `lib/finalize_aux.sh` deleted alongside the 14 lib/notes*.sh files; bash residue for the `--human` mode loop consolidated in `lib/human_mode_notes.sh`. |
| 6 | `drift.sh` + drift_artifacts/cleanup    | done (m25 — drift subsystem + clarify ported; seven bash files deleted; m21 router fix landed) | Subsystem ported in full to `internal/drift/` (observe / artifacts / nonblocking / prune / router). The m21 closeout router-misclassification drift entry resolves as part of the Go port — `internal/drift/router.go::Route` rules an explicit `[FAIL]` header sentinel ahead of the heuristic chain, with `TestRouter_CIFailingTest_IsBlocking` exercising the captured case from `internal/drift/testdata/m21_router_misclassification/`. `tekhton drift {observe,resolve,resolve-all,list,prune,count,entries,reset-audit,audit-status,human-action {append,count}}` Cobra subcommands (Hidden — internal seams). `_hook_drift_artifacts` ported to `internal/finalize/drift_artifacts.go`; four `lib/drift*.sh` files deleted. |
| 7 | `clarify.sh`                            | done (m25 — drift subsystem + clarify ported; seven bash files deleted; m21 router fix landed) | Subsystem ported in full to `internal/clarify/` (detect / handle). The mid-pipeline integration in stages/coder.sh and lib/intake_verdict_handlers.sh now execs `tekhton clarify detect/handle`. A new `_hook_clarify_finalize` clears stale `CLARIFICATIONS.md` on pipeline success; registered in the orchestrator's hook chain just before `_hook_archive_reports`. `tekhton clarify {detect,handle,clear}` Cobra subcommands (Hidden). `lib/clarify.sh` + `lib/failure_context.sh` deleted; `internal/failure_context/` consumes the slot helper surface and is wired into `_hook_failure_context_reset` via `Input.FailureContext`. |
| 8 | `specialists.sh` + helpers              | port        | Per-specialist invocation lives behind run_agent (already Go). |
| 9 | `health.sh` + health_checks*            | port        | Standalone CLI today; clean port. |
| 10| `diagnose.sh` + diagnose_*              | port        | Largely dead code post-m17 since `tekhton diagnose` exists. |
| 11| `indexer.sh` + tools/repo_map.py        | port        | Python tool stays; bash glue ports. |
| 12| `mcp.sh`                                | port        | Lifecycle wrapper for Claude CLI MCP config. |
| 13| `init.sh` + crawler/detect_*            | detect done (m29.2 — ten bash files deleted); Crawler arc done (m30 — eight bash files retired across m30.1 + m30.2, ~1.7k LOC ported) | **Detect (m29.2):** `internal/detect/` ships the `Detector` interface, `Engine`, languages-first invariant, and nine detectors. `tekhton detect summary --json/--markdown/--project-dir` Cobra subcommand. Parity gate (`tests/test_detect_parity.sh`) asserts byte-identical markdown across four fixtures. **Crawler arc (m30):** `internal/crawler/` ships `Crawl(ctx, opts)` AND `Rescan(ctx, opts)` (m30.2). The crawler core (m30.1) ported the seven manifest parsers (npm / Cargo / pyproject / go.mod / Gemfile / Gradle / pom), the package-purpose annotation table, atomic-write emitters, and a read-only/write-only-to-IndexDir safety contract. The rescan port (m30.2) added the eight-branch incremental decision tree (`rescan.go`), the Trivial/Moderate/Major significance classifier (`significance.go`), git-diff + porcelain merge (`changes.go`), and structured meta.json + HTML-comment-fallback metadata extraction (`metadata.go`). `tekhton crawler {crawl,rescan,inventory,deps,content}` Cobra subcommand (Hidden). Parity gates: `tests/test_crawler_parity.sh` (21 assertions across three fixtures) + `tests/test_rescan_parity.sh` (17 assertions across four scenarios: no_changes / trivial / moderate_manifest / major_manifest). Eight bash files deleted across the arc — six `lib/crawler*.sh` at m30.1, `lib/rescan.sh` + `lib/rescan_helpers.sh` at m30.2. `lib/init.sh` execs `tekhton crawler crawl`; `tekhton-legacy.sh --rescan` execs `tekhton crawler rescan`. `scripts/wedge-audit.sh` guards against re-introduction of any deleted crawler/rescan symbol. `internal/crawler/readonly_test.go` enforces the write-only-to-IndexDir contract for every non-emit file. |
| 13a| `gates*.sh` (build/completion/ui)      | done (m31 — five files deleted, ported to internal/gates/) | **m31 arc complete (m31.1 + m31.2):** `internal/gates/` ships the `BuildGate`/`CompletionGate`/`UIPhase` types with the five-phase build pipeline (analyze / compile / constraints / ui_test / ui_validation). M54 remediation re-runs preserved; M126 hardened-rerun semantics ported with byte-identical diagnosis block; M27.2 stdin-nil hang guard preserved. `tekhton gate {build,completion,ui}` Cobra subcommand (Hidden) and `tekhton-legacy.sh::run_build_gate / ::run_completion_gate` execs replace the deleted `lib/gates.sh`, `lib/gates_phases.sh`, `lib/gates_completion.sh`, `lib/gates_ui.sh`, `lib/gates_ui_helpers.sh`. Parity gates: `tests/test_gates_parity.sh` (16 assertions across eleven build/completion scenarios) + `tests/test_gates_ui_parity.sh` (21 assertions across five UI scenarios). `tests/test_file_size_ceilings.sh` enforces the file-deletion invariant. |
| 14| `plan*.sh` (interview, browser, …)      | port        | Conversational mode wrapper around Claude CLI. |
| 15| `replan*.sh`                            | port        | Sister to plan; ports together. |
| 16| `rescan.sh`                             | done (m30.2 — rescan + helpers retired) | Ported as part of the m30 Crawler arc. See row 13. |
| 17| `draft_milestones.sh`                   | port        | Authoring flow; low-priority. |
| 18| `migrate.sh` + migrate_cli              | port        | V2→V3 migrator; small surface. |
| 19| `notes_cli.sh` (`tekhton note …`)       | port        | Small surface; clean Cobra subcommand. |
| 20| `rollback.sh` (via checkpoint)          | port        | Git-only operations; clean port. |
| 21| `report.sh`                             | port        | Reads run artifacts and prints; one-shot. |
| 22| `metrics.sh` + dashboard                | port        | JSONL reader + summary printer. |
| 23| `intake_helpers.sh` + verdict_handlers  | shimmed (m36.2 — Go helpers + verdict handlers; bash files become 113+35 LOC shims execing `tekhton intake helpers|verdict ...`; deleted in m36.3) | `internal/intake/{helpers,verdict}.go` ship `Helpers` (11 methods) + `VerdictHandler` (3 methods) with operator-vocabulary preserved byte-for-byte as Go consts. CLI shim hidden under `tekhton intake`; `tests/test_intake_bash_passthrough.sh` covers the four verdict fixtures end-to-end through the shim. |
| 24| `milestone_acceptance.sh` (+ lint)      | port        | Called from `RunCompleteLoop` via `AcceptanceChecker`. |
| 25| `milestone_split.sh` (+ dag/nullrun)    | port        | Pre-flight sizing logic. |
| 26| `run_memory.sh`                         | port        | JSONL append-only; tiny port. |
| 27| `timing.sh`                             | port        | Stage timing utilities; pure helpers. |
| 28| `safety_net.sh`                         | port        | Run safety + rollback; tiny. |
| 29| `pipeline_order.sh` + policy            | port        | Stage ordering; consumed by the runner. |
| 30| `project_version.sh` + bump             | port        | Detects + bumps target-project version files. |
| 31| `drift_prune.sh`                        | port        | Log pruning; tiny. |
| 32| `quota.sh` + quota_sleep / quota_probe  | port        | Pause-and-resume logic; pairs with TUI. |
| 33| `inbox.sh`                              | port        | Inbox management. |
| 34| `causality_query.sh` (`causality.sh` already Go-owned) | shim | Read-only queries on top of m02's Go writer. |
| 35| `validate_config.sh`                    | shim        | Should be `tekhton config validate` — m16 already covers most of it. |
| 36| `update_check.sh`                       | leave       | One-shot installer companion; never invoked from a pipeline run. |
| 37| `install.sh` (repo root)                | leave       | Installer; not part of the pipeline. |
| 38| `setup_indexer.sh` / `setup_serena.sh`  | leave       | One-shot Python-tool installers. |
| 39| `tools/setup_*.sh`                      | leave       | Same — installer scripts. |
| 40| `completions/*.{bash,zsh,fish}`         | leave       | Shell completion files; not bash logic. |

## Stage-Port Matrix

Per-stage status under the m34 stage-port pattern (`DefaultStageDefs[Stage].GoImpl`).
Each row's milestone closure flips the dispatcher from bash sourcing to Go-native
in-process dispatch. LOC delta counts bash deleted (stage + helpers + shim).

| Stage     | Status                                                | Milestone | LOC deleted |
|-----------|-------------------------------------------------------|-----------|-------------|
| docs      | done — Go-native via `internal/stages/docs/RunStage`  | m34.1     | (see m34.1) |
| cleanup   | done — Go-native via `internal/stages/cleanup/RunStage` | m34.2   | (see m34.2) |
| **security** | **done — Go-native via `internal/stages/security/RunStage`; helpers in `internal/security/`; m35.3 ban + parity gate live** | **m35**   | **407** |
| **architect** | **done — Go-native via `internal/stages/architect/RunStage`; plan parser + sr/jr router in package; m36.1 ban + parity gate live** | **m36.1**   | **414** |
| **intake**    | **done — Go-native via `internal/stages/intake/RunStage`; helpers in `internal/intake/`; m36.3 ban + 8-scenario parity gate live; M36.2 CLI shim retired** | **m36.3** | **725 (377 stage + 267 helpers + 35 verdict + 46 prompts/passthrough tests)** |
| **review**    | **done (m37 — review stage ported; 2 bash files deleted; cycle loop in-stage)** | **m37.2** | **463 (307 stage + 78 helpers + comments)** |
| **tester**    | **done (m38 — tester family ported; 13 bash files deleted: 6 stages/tester*.sh + 6 lib/test_audit*.sh + lib/test_baseline.sh; GoImpl dispatch; m38.6 ban + 10-fixture parity gate live)** | **m38.6** | **~2,082 (six tester stages + six test_audit helpers + test_baseline + ports)** |
| coder     | in flight                                             | m39       | TBD         |

### m47 — Envelope-over-error rule for every Go-impl stage

m47 added a cross-stage contract every future GoImpl stage MUST follow:

> Once the agent has produced a parseable verdict envelope, the stage MUST
> return that envelope. Any post-parse sub-call failures attach to the
> envelope as `Metadata["subprocess_warnings"]` JSON-list entries — they
> do NOT short-circuit with a Go-level error.

Two reserved Metadata keys on `proto.StageResultV1`:

- `subprocess_warnings`: JSON-encoded `[]string` of post-verdict sub-call
  failures (plural; multiple sub-calls can fail in one cycle — the build
  gate AND the specialist rework can both error and both warnings survive).
  Use `internal/stages/review.appendSubprocessWarning` as the canonical
  appender; copy the shape into new stage packages.
- `subprocess_warning`: single-string fallback the stagerunner adapter
  writes when a GoImpl returns both a non-nil result AND a non-nil error.
  This is defense-in-depth — Goal 1 stage-level classifications eliminate
  the offending paths; the adapter gate catches future regressions before
  they reach the operator.

**Classification rule for return-err sites.** When porting a stage to Go, audit
every `return nil, err` site. Each is either:

- **Pre-parse infrastructure failure** — agent dispatch, prompt render,
  report file read, replan dialog. These STAY as `return nil, err`. The
  stage has no parseable verdict and the runner needs the structural
  failure signal.
- **Post-parse subprocess failure** — build gate, specialist runner, rework
  build-fix escalation, post-rework reviewer cycle. These CONVERT to
  envelope warnings: append the error message via
  `appendSubprocessWarning(res, msg)` and return the originally-parsed
  verdict's result with `err == nil`.

Specific exception: when the post-parse verdict is itself CHANGES_REQUIRED
(i.e. the parsed verdict is already a fail), a subprocess failure in the
rework path remains a hard fail — the rule is "subprocess errors don't
override the parsed verdict," not "subprocess errors are always warnings."

**m38.6 (tester port) inherits this contract.** The tester stage MUST audit
its return-err sites the same way. Implementers: copy
`internal/stages/review/warnings.go` (44 lines, hermetic), classify each
site, document the classification inline next to the `return nil, err` with
an `// m47 classification: ...` comment.

The security row flipped to **done** at m35.3 close (v4.35.0). The architect
row flipped to **done** at m36.1 close (v4.43.0) — `stages/architect.sh`
deleted, `internal/stages/architect/` ported with `RunStage`, plan parser,
sr/jr remediation router, post-remediation build + expedited-review gates,
drift integration via `internal/drift/` (M25). Six `tekhton drift ...`
subprocess execs per audit replaced by in-process Go calls; the four
prompt templates (`prompts/architect*.prompt.md`) are unchanged. The
Phase 5 closeout retros and patch-bump tallies per milestone live in
`docs/go-migration.md`.

The intake stage rows are arriving in two halves. **m36.2 (helpers half —
in flight)** ships `internal/intake/helpers.go` (11 helper methods porting
`lib/intake_helpers.sh`) and `internal/intake/verdict.go` (3 verdict
handler methods porting `lib/intake_verdict_handlers.sh`). Operator-facing
strings — the rejection message, NEEDS_CLARITY status, `## Q:` clarifications
format, complete-mode halt reason — are preserved byte-for-byte as Go
constants and cross-checked against the bash files by
`TestBashTextParity`. The bash files become thin shims (113 + 35 LOC) that
exec into a Hidden `tekhton intake helpers|verdict ...` Cobra subcommand
tree; the verdict handlers preserve halt-with-state semantics via a
TSV sentinel file (`$TEKHTON_INTAKE_STATE_OUT`) the bash wrapper reads to
forward into `write_pipeline_state`. LOC budget for m36.2: **−471 bash**
(267 + 204 lines of logic ported out) **/ +1008 Go** (508 helpers + 500
verdict). **m36.3 (stage half — done)** consumed these helpers in-process
via `internal/stages/intake/RunStage`, deleted `stages/intake.sh` +
`lib/intake_helpers.sh` + `lib/intake_verdict_handlers.sh` +
`cmd/tekhton/intake.go` (the M36.2 transition CLI shim) +
`cmd/tekhton/intake_test.go` + `tests/test_intake_bash_passthrough.sh`,
landed `tests/test_intake_parity.sh` (8 scenarios — PASS / TWEAKED /
SPLIT_RECOMMENDED / NEEDS_CLARITY-complete-mode / cached-run /
human-mode-skip / disabled / no-content), and registered
`GoImpl: intake.RunStage` in `internal/stagerunner/helpers.go`.

## Phase 5 follow-up: --add-milestone port

The `run_intake_create` function (bash lines 244-377 of the deleted
`stages/intake.sh`) implemented the agent-driven create flow for
`--add-milestone <description>`. M36.3 deletes the host file; that
function disappears with it. The `--add-milestone` CLI entry currently
routes to `run_draft_milestones` (the user-driven interactive flow),
which is a working alternative — but the original agent-driven scope
(ID allocation, manifest append, milestone file creation, intake-agent
invocation in create mode) is gone.

Scope for a follow-up (m36.4 candidate or m37 sibling):

- Port `run_intake_create` to `cmd/tekhton/milestone.go add-milestone <description>`.
- Reuse `internal/intake/Helpers` (in-process — no subprocess shim).
- Reuse `internal/manifest` for ID allocation + manifest append.
- Keep the existing `--draft-milestones` flow as the user-driven path.

`tekhton-legacy.sh --add-milestone` was updated in m36.3 to emit a
clear "temporarily unavailable post-m36.3 in agent-driven create mode"
warning and route to `--draft-milestones` so operators have a working
fallback.

## Candidate ordering

Phase 5 should attack in this rough order (subject to the m21 author):

1. **m21 — finalize port.** Every run touches it; ports unlock dashboard + notes ports.
2. **m22 — preflight + tui_ops port.** Tightly coupled at the run boundary; dogfooding pain.
3. **m23 — dashboard emitters/parsers.** JSON-heavy; clean once finalize is Go.
4. **m24 — notes + drift + clarify.** Three closely-coupled subsystems share the human-action loop.
5. **m25 — diagnose + health + report shims.** Mostly already Go; finishes the user-facing CLI surface.
6. **m26 — init + plan + draft-milestones (greenfield CLI).** Lowest dogfooding priority since these are run-once.
7. **m27 — long-tail cleanup.** Migrate, rescan, replan, intake helpers, milestone-split, the leftover lib/*.sh files.
8. **m28 — `tekhton-legacy.sh` deletion + final tekhton.sh consolidation.** Cutover — the dispatcher collapses into a single Go binary entry point with `tekhton.sh` becoming a one-line shim or deleted entirely.

## Open questions

These need an answer before Phase 5 design freezes:

- **Acceptance check residency.** Does `check_milestone_acceptance` stay
  bash for one more milestone, or port early because `RunCompleteLoop`
  calls it on every successful attempt? Current vote: port early (m21
  candidate alongside finalize). Decision pending.
- **`tekhton-legacy.sh` lifetime.** As Phase 5 ports each subsystem, the
  legacy entry point shrinks. At what point is it light enough to delete
  outright vs. left in place as a thin compatibility shell? Current vote:
  delete when fewer than ~200 lines remain, even if a few uncommon flags
  still need a porting milestone.
- **Cross-platform reaper consolidation.** The m09 Windows reaper runs
  inside Go but the bash trap chain still has its own zombie cleanup in
  `lib/agent_monitor.sh`. Phase 5 should pick one or the other, not both.
- **Prompt templates.** Templates live in `prompts/*.prompt.md`. Once the
  bash legacy body is gone, do the templates live in `internal/prompt/templates/`
  (embed-friendly) or stay at the repo root (editable without rebuild)?
  Current vote: embed via `embed.FS` for production, allow filesystem
  override for local development.

## Bash LOC budget tracking

| Boundary               | Bash LOC (lib + stages + tekhton*.sh) |
|------------------------|---------------------------------------:|
| Start of Phase 4 (m11) |                                ~14000 |
| End of Phase 4 (m20)   |                                 ~9500 |
| End of Phase 5 m21     |                                 ~9100 |
| End of Phase 5 m22     |                                 ~7600 |
| End of Phase 5 m23     |                                 ~6800 |
| End of Phase 5 m24     |                                 ~4700 |
| End of Phase 5 m25     |                                 ~3300 |
| End of Phase 5 m29.1   |                                 ~3300 |
| End of Phase 5 m29.2   |                                 ~640 |
| End of Phase 5 m31.2   |                                 ~270 |
| Phase 5 target         |                                     0 |

m29.2 closing notes:

- **8** new Go detectors landed under `internal/detect/`: `commands.go`,
  `workspaces.go`, `services.go`, `ci.go`, `infrastructure.go`,
  `test_frameworks.go`, `doc_quality.go`, `ai_artifacts.go`. Plus
  `ui_framework.go` carrying the `detect_ui_framework` port. The
  registered detector order in `cmd/tekhton/detect.go::registeredDetectors`
  is load-bearing — `TestRegistrationOrder` and the parity gate both fail
  red on drift.
- **Ten** `lib/detect*.sh` files deleted in one atomic step alongside the
  bash caller migration: `detect.sh`, `detect_report.sh`,
  `detect_commands.sh`, `detect_workspaces.sh`, `detect_services.sh`,
  `detect_ci.sh`, `detect_infrastructure.sh`, `detect_test_frameworks.sh`,
  `detect_doc_quality.sh`, `detect_ai_artifacts.sh`. ~2,660 bash LOC out;
  ~2,700 Go LOC + ~190 bash LOC in `lib/common_detect.sh` in.
- Bash wrappers live in `lib/common_detect.sh` (sourced by `lib/common.sh`).
  Per-domain accessors (`_tk_detect_languages`, `_tk_detect_commands`,
  `_tk_detect_workspaces`, …) preserve the pipe-delimited shape the
  historical callers consumed; `_tk_format_detection_report` and
  `_tk_format_detection_summary` cover the report formatter surface.
  `_tk_detect_ui_framework` carries the env-var side effects
  (`UI_PROJECT_DETECTED`, `UI_FRAMEWORK`) the deleted bash function had,
  via `select(.kind == "ui")` over the Go engine's JSON output.
- Parity gate extended in `tests/test_detect_parity.sh`: no per-section
  extraction, byte-identical FULL markdown comparison across all four
  fixtures including the new `empty/` (m29.2-added) fixture. Baselines
  remain frozen — drift means the Go port diverged, not that the
  baseline is stale.
- `scripts/wedge-audit.sh` guards against any `lib/detect*.sh`
  re-introduction. `internal/stagerunner/helpers.go::DefaultLibHelpers`
  drops the ten detect entries to match the deleted files.
- One acceptance criterion (`empty/` fixture produces ≥ 8 `(none
  detected)` markers) cannot be literally met without modifying the
  bash report formatter, which would violate the no-feature-redesign
  rule. Captured behaviour: the bash formatter skips empty
  workspace/services/CI/infrastructure/test-frameworks sections, so
  the empty baseline contains 4 markers. The Go port matches this
  exactly. Documented in CODER_SUMMARY.md for reviewer awareness.
- VERSION bump: the milestone directive specifies `4.29.0`. The
  project's current `VERSION` is `4.33.28`, well past the milestone
  number — milestones have been merging out of order. Setting VERSION
  backward to `4.29.0` would regress; left at `4.33.28` and documented
  as a deliberate departure from the milestone's literal text.

m29.1 closing notes:

- **1** Go detector landed (`LanguagesDetector`) backing the engine's
  languages-first invariant. The `Detector` interface, `Engine`,
  `Input`/`Result`/`Summary` types, markdown report formatter, read-only
  contract test, and `tekhton detect summary` Cobra subcommand (Hidden)
  ship together — m29.1 lands the scaffolding m29.2 will implement
  against.
- **0** bash files modified or deleted at m29.1. Every existing caller
  (`lib/init.sh`, `lib/express.sh`, `lib/rescan.sh`,
  `lib/health_checks*.sh`, `tekhton-legacy.sh`) still sources the bash
  detect tree; tekhton-stable can rebuild safely after m29.1 with the
  bash subsystem intact as the rollback path. The bash LOC budget does
  not move until m29.2.
- Parity gate scaffolded under `tests/test_detect_parity.sh` plus three
  frozen fixtures (`monorepo-pnpm`, `polyglot-services`, `ai-heavy-mess`)
  + bash baselines captured by `scripts/capture-detect-baselines.sh`.
  m29.1 asserts only the `### Project Type / ### Languages / ###
  Frameworks` sections (the parts the Go engine populates); m29.2
  extends to every section once the remaining detectors land.
- The `Summary` struct carries fields for every m29.2 detector domain
  (`Commands`, `Workspaces`, `Services`, `CI`, `Infrastructure`,
  `TestFrameworks`, `DocQuality`, `AIArtifacts`); they are stub-empty
  through m29.1's close. m29.2 fills them by registering the eight
  remaining detectors in `cmd/tekhton/detect.go::runDetectSummary`.

m22 closing notes:

- **5** pure-Go check families landed under `internal/preflight/`
  (`foundation`, `ui_audit`, `env`, `services_infer`, `services`) driven
  by `preflight.Orchestrator`. The five `lib/preflight*.sh` files plus
  the parent `lib/preflight.sh` deleted outright — no per-check shim
  equivalent of m21's finalize dispatcher because preflight checks have
  flat dependencies (no notes/drift/dashboard cross-coupling).
- `BashHookRunner.Preflight` no longer execs `bash lib/preflight.sh`; it
  constructs `preflight.Orchestrator` and runs the chain in-process.
- `tekhton preflight` Cobra subcommand (`cmd/tekhton/preflight.go`) is
  the developer-facing entry point — Hidden, matching the m21
  `tekhton finalize` precedent.
- `tekhton-legacy.sh` lost the six `source lib/preflight*.sh` lines; the
  legacy `run_preflight_checks` function execs `tekhton preflight` so
  the bash V3 entry point still has a working name during the Phase 5
  transition.
- Goal 6 (`tests/test_self_host_dry_run_gate`) un-guarded: the m21
  skip-block at the top of the test was removed, the gate fix in
  `scripts/self-host-check.sh` moves the dry-run-skip check above the
  Go-toolchain pre-check so the gate's documented contract (skip with
  exit 0 when the flag is absent) holds even without Go installed. Side
  effect: `make self-host` / `make dogfood` become a no-op when
  `TEKHTON_SELF_HOST_DRY_RUN` is unset — invoking the matrix now
  requires setting the flag explicitly. Acceptable trade-off per the
  m22 spec.
- Five bash tests skip-stubbed (`test_preflight.sh`,
  `test_preflight_ui_config.sh`, `test_m118_preflight_deferred_emit.sh`,
  `test_preflight_infer_degenerate.sh`, `test_m131_coverage_gaps.sh`)
  with notes pointing at their Go replacements. Pass count unchanged.
- Parity gate (`tests/test_preflight_parity.sh`) asserts byte-identical
  PREFLIGHT_REPORT.md across green_path / env_only_fail /
  ui_config_autopatch scenarios after timestamp + backup-path
  normalisation. Dashboard parsers (still bash through m23) keep
  reading the report unchanged.

m21 closing notes:

- **8** pure-Go hooks landed in `internal/finalize/` (`clear_state`,
  `archive_reports`, `mark_done`, `cleanup_milestone` (formerly
  `archive_milestone`; retired the archive output, now removes the
  milestone file on completion), `emit_run_memory`, `emit_run_summary`,
  `emit_timing_report`, `causal_log_finalize`). The remaining **18** hooks
  dispatch through `lib/finalize_shim.sh` (one bash process per hook).
- `BashAdapter.Finalize` no longer execs `bash lib/finalize.sh`; it
  constructs `finalize.Orchestrator` and runs the chain in-process.
- `lib/finalize.sh` shrunk to 48 lines (was 280). A legacy compatibility
  `finalize_run` shim remains so the V3 entry point (`tekhton-legacy.sh`)
  still has a working `finalize_run` — it execs `tekhton finalize` so the
  Go orchestrator drives the chain in both paths.
- `tekhton finalize` Cobra subcommand (`cmd/tekhton/finalize.go`) is the
  developer-facing entry point — flagged `Hidden` so it doesn't appear in
  the standard help output.
- Bash files **deleted**: `finalize_summary.sh`,
  `finalize_summary_collectors.sh`, `run_memory.sh` (their Go ports —
  `emit_run_summary` and `emit_run_memory` — fully cover the bodies).
- Post-audit cleanup: `milestone_archival.sh`,
  `milestone_archival_helpers.sh`, and the entire archive pipeline were
  removed. Completed milestones now have their source files deleted on
  finalize (`cleanup_milestone` hook); git history is the canonical
  record. Inline-mode milestone splitting was retired alongside.
- Dogfooding artifacts: 17 patch bumps surfaced during the m21 cycling
  run (`4.21.1` → `4.21.17`), none reverting earlier work — all forward
  patches. Two findings recorded as drift observations: (a) non-blocking
  router misclassified a CI-failing test as non-blocking; (b) architect
  agent didn't discover the pre-existing `parity_test.go` before
  proposing a near-duplicate parity test.

Each Phase 5 milestone records the post-milestone LOC count in its CODER_SUMMARY.
A milestone that does *not* reduce the bash count is a code smell — Phase 5
exists to drive the count to zero.
