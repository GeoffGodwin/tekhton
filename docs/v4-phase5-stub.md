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
| 1 | `finalize.sh` + 26 finalize hooks       | port        | Highest dogfooding pain — every run touches it. Phase 5 m21 candidate. |
| 2 | `preflight.sh` + checks/services       | port        | UI config audit (m131) is the riskiest sub-piece. |
| 3 | `tui_ops.sh` mid-run writers            | port        | Status writer needs atomic-rename per `lib/tui_liveness.sh`. |
| 4 | `dashboard.sh` + emitters/parsers       | port        | Currently emits JSON envelopes the Go side already speaks. |
| 5 | `notes.sh` + variants (rewrite, cli, …) | port        | Three-state state machine; pure bash today. |
| 6 | `drift.sh` + drift_artifacts/cleanup    | port        | Pairs with notes; depends on causal log already in Go. |
| 7 | `clarify.sh`                            | port        | Small surface; depends on prompt engine (already Go). |
| 8 | `specialists.sh` + helpers              | port        | Per-specialist invocation lives behind run_agent (already Go). |
| 9 | `health.sh` + health_checks*            | port        | Standalone CLI today; clean port. |
| 10| `diagnose.sh` + diagnose_*              | port        | Largely dead code post-m17 since `tekhton diagnose` exists. |
| 11| `indexer.sh` + tools/repo_map.py        | port        | Python tool stays; bash glue ports. |
| 12| `mcp.sh`                                | port        | Lifecycle wrapper for Claude CLI MCP config. |
| 13| `init.sh` + crawler/detect_*            | port        | Big surface; lowest dogfooding priority (run-once). |
| 14| `plan*.sh` (interview, browser, …)      | port        | Conversational mode wrapper around Claude CLI. |
| 15| `replan*.sh`                            | port        | Sister to plan; ports together. |
| 16| `rescan.sh`                             | port        | Companion to crawler; ports together. |
| 17| `draft_milestones.sh`                   | port        | Authoring flow; low-priority. |
| 18| `migrate.sh` + migrate_cli              | port        | V2→V3 migrator; small surface. |
| 19| `notes_cli.sh` (`tekhton note …`)       | port        | Small surface; clean Cobra subcommand. |
| 20| `rollback.sh` (via checkpoint)          | port        | Git-only operations; clean port. |
| 21| `report.sh`                             | port        | Reads run artifacts and prints; one-shot. |
| 22| `metrics.sh` + dashboard                | port        | JSONL reader + summary printer. |
| 23| `intake_helpers.sh` + verdict_handlers  | port        | Stage helpers; bundle with stage port. |
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
| Phase 5 target         |                                     0 |

Each Phase 5 milestone records the post-milestone LOC count in its CODER_SUMMARY.
A milestone that does *not* reduce the bash count is a code smell — Phase 5
exists to drive the count to zero.
