<!-- milestone-meta
id: "22"
status: "done"
-->

# m22 — Preflight Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — second dogfooded V4 milestone. M20 routed pipeline runs through `tekhton run`; M21 ported the post-run finalize chain to Go. The pre-run boundary is still bash: `BashHookRunner.Preflight` execs `lib/preflight.sh` and waits for it to write `.tekhton/PREFLIGHT_REPORT.md`. That makes preflight the next-highest-leverage Phase 5 port — every run touches it, the report drives early-exit gates, and the M131 UI config audit it owns (Playwright/Cypress/Jest/Vitest reporter patching) is one of the most behaviorally-loaded checks in the system. Until preflight is Go, the supervisor still hands control to bash for the most-touched stage of the *front* of the pipeline, mirroring the situation M21 just fixed for the back. |
| **Gap** | `lib/preflight.sh` and its five satellites (`preflight_checks.sh`, `preflight_checks_env.sh`, `preflight_checks_ui.sh`, `preflight_services.sh`, `preflight_services_infer.sh`) total 1501 lines of bash that run on every `tekhton run` invocation. The Go runner has no awareness of which check failed or how — it just execs bash, waits, and parses `PREFLIGHT_REPORT.md`. There is no per-check timing, structured failure capture, or way to substitute a Go implementation for one check while leaving the rest as bash. The `BashHookRunner.Preflight` body in `internal/runner/runner.go:207-209` is the canonical exec-into-bash seam that has to go away to close this gap. |
| **m22 fills** | (1) `internal/preflight/` becomes the Go-side preflight subsystem. The orchestrator, check registry, and report writer move from bash to Go. (2) Six Go check bodies land natively, one per existing bash check family: env (binaries, versions, PATH), UI config audit (M131 reporter patching for Playwright/Cypress/Jest/Vitest), services detection, services inference, foundation checks, the orchestrator itself. (3) `BashHookRunner.Preflight` rewires to build `preflight.Orchestrator` and runs in-process — no more `exec bash lib/preflight.sh`. (4) `tekhton preflight` Cobra subcommand becomes the standalone developer-facing entry point (Hidden, matching `tekhton finalize`). (5) The six `lib/preflight*.sh` files delete; `tekhton-legacy.sh:870-875` sourcing block and the `run_preflight_checks` call at `tekhton-legacy.sh:2968` route through `tekhton preflight` instead. (6) The `test_self_host_dry_run_gate` failure (drift-logged at m21 close) resolves as part of porting the gate semantics: `TEKHTON_SELF_HOST_DRY_RUN=1` now skips with exit 0 when prerequisites are missing, matching the test's longstanding expectation. (7) A parity gate diffs `PREFLIGHT_REPORT.md` between a captured bash baseline and the m22 Go orchestrator across three scenarios: green-path, env-only-fail, UI-config-auto-patch. (8) `VERSION` bumps to `4.22.0` on close. |
| **Depends on** | m21 |
| **Files changed** | `internal/preflight/`, `cmd/tekhton/preflight.go`, `internal/runner/runner.go`, `tekhton-legacy.sh`, `scripts/self-host-check.sh`, `docs/v4-phase5-stub.md`, six deletions under `lib/preflight*.sh`, parity test `tests/test_preflight_parity.sh`. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m20 | `tekhton run` (Go) owns dispatch; bash entry becomes a 76-line shim. |
| m21 | Finalize chain orchestrator + 8 of 26 hooks ported to Go; per-hook bash dispatcher introduced for the remaining 18. |
| **m22** | **Preflight orchestrator + all 6 check families ported to Go; bash preflight subsystem deletes.** |

---

## Design

### Sequencing note

Unlike m21, m22 does not introduce a per-check bash shim. Reason: m21 needed the shim because the 18 unported hooks depended on bash subsystems (notes, drift, dashboard, etc.) that m22-m25 still own. Preflight's checks have flat dependencies (env binaries, file detection, shell commands) — every check ports cleanly in one milestone, no shim needed. The whole subsystem ports in one shot, files delete, end of story. This is the *better* shape; m21's shim was a transition tax, not a target pattern.

### Goal 1 — Orchestrator + check registry

`internal/preflight/orchestrator.go` registers checks in the same order the bash version executes them. Mirror m21's hook-order test pattern (`internal/finalize/orchestrator_test.go:TestHookOrder_MatchesBashRegistration`) so reordering is caught red.

```go
type Orchestrator struct {
    Checks   []Check
    Project  string
    Home     string
    Reporter Reporter
}

type Check interface {
    Name() string
    Run(ctx context.Context, in *Input) Result
}

type Result struct {
    Status   Status // Pass | Warn | Fail | Skip
    Message  string
    Findings []Finding
    AutoFix  *AutoFix
}
```

Check registration order (matches `lib/preflight.sh:run_preflight_checks` body):

```go
checks := []Check{
    &EnvCheck{},                    // ports lib/preflight_checks_env.sh
    &FoundationCheck{},             // ports lib/preflight_checks.sh
    &ServicesCheck{},               // ports lib/preflight_services.sh
    &ServicesInferCheck{},          // ports lib/preflight_services_infer.sh
    &UIConfigCheck{},               // ports lib/preflight_checks_ui.sh
}
```

The orchestrator writes `.tekhton/PREFLIGHT_REPORT.md` with the same structure the bash version produced (markdown table, per-check section, autofix log). Format-preserving so dashboard parsers (`lib/dashboard_parsers.sh` until m23 ports them) keep working.

### Goal 2 — Six pure-Go check bodies

Each check is a standalone Go file under `internal/preflight/`:

| File | Ports | Notes |
|------|-------|-------|
| `env.go` | `preflight_checks_env.sh` | Binary presence (`go`, `claude`, `git`, `python3`), version parsing, PATH sanity. Uses `os/exec.LookPath` and version regexes; no shell-out beyond version detection. |
| `foundation.go` | `preflight_checks.sh` | `.claude/` layout, `pipeline.conf` presence, `CLAUDE.md` parseability, repo-map cache freshness. |
| `services.go` | `preflight_services.sh` | Reads `services:` block in `pipeline.conf`, validates per-service `port`/`healthcheck`/`startup_cmd`. |
| `services_infer.go` | `preflight_services_infer.sh` | Auto-detects services from `docker-compose.yml`, `Procfile`, language-specific config (`pubspec.yaml`, `package.json`). |
| `ui_audit.go` | `preflight_checks_ui.sh` | **The behavior-heaviest port.** Reads Playwright/Cypress/Jest/Vitest config files, parses for `reporter: 'html'` or `reporter: ['html']`, patches to file-based reporters when `PREFLIGHT_UI_CONFIG_AUTO_FIX=true`, backs up the original to `PREFLIGHT_BAK_DIR` with retention. |
| `orchestrator.go` | `preflight.sh` | The registry + run loop + report writer; the shape above. |

Each check file has a sibling `_test.go` with table-driven scenarios covering pass / warn / fail / skip / autofix paths. The fixture set lives in `internal/preflight/testdata/` (per-scenario directories with synthetic project layouts).

### Goal 3 — `BashHookRunner.Preflight` rewires

Today (`internal/runner/runner.go:207-209`):

```go
func (b *BashHookRunner) Preflight(ctx context.Context, req *proto.RunRequestV1) error {
    return b.execBash(ctx, "lib/preflight.sh", ...)
}
```

After m22:

```go
func (b *BashHookRunner) Preflight(ctx context.Context, req *proto.RunRequestV1) error {
    o := preflight.NewOrchestrator(b.TekhtonHome, req.ProjectDir, b.reporter())
    if err := o.Run(ctx); err != nil {
        return fmt.Errorf("preflight: %w", err)
    }
    if o.HasBlockers() {
        return errors.New("preflight: blockers present — see .tekhton/PREFLIGHT_REPORT.md")
    }
    return nil
}
```

Drop the `Preflight` constructor option that pointed at a bash script; the only configuration the runner needs is project dir + home, both already on the receiver.

### Goal 4 — `tekhton preflight` Cobra subcommand

Mirror m21's `tekhton finalize` shape exactly. `cmd/tekhton/preflight.go`:

```go
var preflightCmd = &cobra.Command{
    Use:    "preflight",
    Short:  "Run pre-flight environment checks and emit PREFLIGHT_REPORT.md",
    Hidden: true,
    RunE: func(cmd *cobra.Command, _ []string) error {
        // Same orchestrator the BashHookRunner uses.
        o := preflight.NewOrchestrator(...)
        return o.Run(cmd.Context())
    },
}
```

Hidden because the standalone invocation is a developer/debug lever — end users always run preflight transitively via `tekhton run`.

### Goal 5 — Bash callers migrate to `tekhton preflight`

`tekhton-legacy.sh:870-875` currently sources six files. After m22:

```bash
# m22: preflight subsystem ported to Go. The bash entry point still needs
# the function `run_preflight_checks` for legacy compatibility; it now
# execs `tekhton preflight` so the Go orchestrator drives both paths.
run_preflight_checks() {
    local tekhton_bin="${TEKHTON_BIN:-${TEKHTON_HOME:-.}/bin/tekhton}"
    "$tekhton_bin" preflight --project-dir "${PROJECT_DIR:-$(pwd)}"
}
```

The six `lib/preflight*.sh` files delete outright. No transition shim — preflight has no equivalent of m21's `milestone_split.sh` cross-dependency.

### Goal 6 — Self-host dry-run gate fix

Drift entry from m21 closeout flagged `test_self_host_dry_run_gate` as failing because the gate's top-of-script Go-toolchain check fires before the `TEKHTON_SELF_HOST_DRY_RUN=1` evaluation. The fix lives in `scripts/self-host-check.sh`:

```bash
# Move the dry-run-skip check ABOVE the toolchain pre-check so the gate's
# documented contract ("skip with exit 0 when dry-run flag absent") holds
# even on machines without a Go toolchain installed.
if [[ "${TEKHTON_SELF_HOST_DRY_RUN:-0}" != "1" ]]; then
    printf 'SKIP self-host-check: TEKHTON_SELF_HOST_DRY_RUN not set\n'
    exit 0
fi
```

This brings `test_self_host_dry_run_gate.sh` back to green (was the second pre-existing failure flagged at m21 close).

**Skip-guard removal is part of the deliverable.** At m21 close the test was wrapped in a skip-guard block at the top of `tests/test_self_host_dry_run_gate.sh` so tekhton's test-baseline subsystem would not burn cycles on it before m22's gate fix lands. Goal 6's *proof of work* is removing that guard block and showing the un-guarded test passes against the gate fix. This is also Acceptance Criterion #8 — silently leaving the guard in place means Goal 6 was never verified.

### Goal 7 — Parity gate

`tests/test_preflight_parity.sh` runs three scenarios against a captured pre-m22 baseline:

1. **Green-path:** fixture project with `.claude/pipeline.conf`, all binaries present, no UI config. Expected: zero findings, exit 0, report has "All checks passed" banner.
2. **Env-only-fail:** fixture project missing `claude` CLI. Expected: one HIGH finding in env section, exit 1, report names the missing binary.
3. **UI-config-auto-patch:** fixture project with a Playwright config that uses the interactive HTML reporter. With `PREFLIGHT_UI_CONFIG_AUTO_FIX=true`, expected: config gets patched to `[ ['html', { open: 'never' }], ['list'] ]`, backup file created, report records the autofix.

Each scenario asserts byte-identical `PREFLIGHT_REPORT.md` (after timestamp normalization) between the captured bash baseline and the m22 Go orchestrator.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/preflight/orchestrator.go` | Create | Hook registry + run loop + report writer. |
| `internal/preflight/env.go` | Create | Binary/version/PATH checks (ports `preflight_checks_env.sh`). |
| `internal/preflight/foundation.go` | Create | `.claude/` layout + `pipeline.conf` parseability (ports `preflight_checks.sh`). |
| `internal/preflight/services.go` | Create | Configured-services validation (ports `preflight_services.sh`). |
| `internal/preflight/services_infer.go` | Create | Auto-detected services (ports `preflight_services_infer.sh`). |
| `internal/preflight/ui_audit.go` | Create | M131 UI test framework config audit + auto-patch (ports `preflight_checks_ui.sh`). |
| `internal/preflight/*_test.go` | Create | Per-check unit tests + fixtures. |
| `internal/preflight/testdata/` | Create | Synthetic project fixtures for the unit + parity tests. |
| `cmd/tekhton/preflight.go` | Create | `tekhton preflight` Cobra subcommand (Hidden). |
| `cmd/tekhton/preflight_test.go` | Create | CLI smoke + flag wiring. |
| `internal/runner/runner.go` | Modify | `BashHookRunner.Preflight` builds `preflight.Orchestrator` instead of execing bash. |
| `internal/runner/hooks_test.go` | Modify | Replace the three `BashHookRunner.Preflight` tests with Go-orchestrator equivalents. |
| `tekhton-legacy.sh` | Modify | Drop the six `source lib/preflight*.sh` lines; rewrite `run_preflight_checks` to exec `tekhton preflight`. |
| `scripts/self-host-check.sh` | Modify | Move dry-run skip-check above the Go-toolchain pre-check (fixes `test_self_host_dry_run_gate`). |
| `tests/test_preflight_parity.sh` | Create | Three-scenario byte-identical parity gate. |
| `lib/preflight.sh` | Delete | Ported to `internal/preflight/orchestrator.go`. |
| `lib/preflight_checks.sh` | Delete | Ported to `internal/preflight/foundation.go`. |
| `lib/preflight_checks_env.sh` | Delete | Ported to `internal/preflight/env.go`. |
| `lib/preflight_checks_ui.sh` | Delete | Ported to `internal/preflight/ui_audit.go`. |
| `lib/preflight_services.sh` | Delete | Ported to `internal/preflight/services.go`. |
| `lib/preflight_services_infer.sh` | Delete | Ported to `internal/preflight/services_infer.go`. |
| `docs/v4-phase5-stub.md` | Modify | Update Hook 2 (`preflight + checks/services`) status from "port" to "done (m22)"; update LOC budget table with the new post-m22 count. |

---

## Acceptance Criteria

- [ ] `internal/preflight/orchestrator.go` exists and registers 5 checks (`env`, `foundation`, `services`, `services_infer`, `ui_audit`) in a `checkOrder` slice; an order-mismatch test in `internal/preflight/orchestrator_test.go` fails red if the order drifts.
- [ ] All 5 check bodies (`env.go`, `foundation.go`, `services.go`, `services_infer.go`, `ui_audit.go`) each have a passing unit test in `internal/preflight/<name>_test.go` with at least one pass / one fail / one skip / one autofix scenario apiece.
- [ ] `BashHookRunner.Preflight` no longer execs `bash lib/preflight.sh` — verified by `grep -nE '(exec|bash).*preflight\.sh' internal/runner/runner.go` returning zero matches.
- [ ] The six `lib/preflight*.sh` files are deleted from the repo; `find lib -name 'preflight*.sh'` returns nothing.
- [ ] `tekhton preflight` is registered as a Hidden Cobra subcommand in `cmd/tekhton/main.go`; `tekhton preflight --help` exits 0 with usage text.
- [ ] `tekhton-legacy.sh` no longer sources any `lib/preflight*.sh`; the `run_preflight_checks` function execs `tekhton preflight`.
- [ ] `tests/test_preflight_parity.sh` exits 0 across the three documented scenarios (green-path, env-only-fail, UI-config-auto-patch).
- [ ] Goal 6 verification: the skip-guard block at the top of `tests/test_self_host_dry_run_gate.sh` (inserted at m21 closeout) is **removed**, and the un-guarded test exits 0 against the m22 gate fix in `scripts/self-host-check.sh`. The skip-guard exists specifically so m22's loop does not burn cycles on this test before the gate fix lands; un-guarding is the close-out proof that Goal 6 actually worked. Removing the guard but leaving the test failing means the gate fix is wrong — fix the gate, do not weaken the test.
- [ ] `make dogfood` exits 0 (self-host parity matrix still green).
- [ ] `bash scripts/wedge-audit.sh` exits 0 (audit extended to forbid re-introduction of `run_preflight_checks` as a bash function with a body other than `exec tekhton preflight`).
- [ ] `go test ./internal/preflight/... ./cmd/tekhton/...` passes.
- [ ] `bash tests/run_tests.sh` reports zero failures at m22 close. Starting state is 506 pass / 0 fail (after m21-close skip-guards on `test_plan_browser` and `test_self_host_dry_run_gate`). m22 work must preserve that count: the gate test is un-guarded as part of Goal 6 (see the criterion above) and must pass against the gate fix. `test_plan_browser` stays skip-guarded — un-guarding that one is m26's job, not m22's.
- [ ] `docs/v4-phase5-stub.md` LOC budget table shows the new post-m22 count and Hook 2 marked "done (m22 — preflight subsystem ported in full, six files deleted)".
- [ ] `VERSION` reads `4.22.0` on milestone close.
- [ ] `.claude/milestones/MANIFEST.cfg` has the row `m22|Preflight Port|done|m21|m22-preflight-port.md|phase5`.
- [ ] The implementation run is itself driven by `tekhton run --milestone m22 --complete` — i.e. m22 is the second dogfooded V4 milestone, continuing the m21 precedent.

## Watch For

- **UI config audit is the largest behavioral surface.** `preflight_checks_ui.sh` is 297 lines that read external config files (Playwright `playwright.config.ts`, Cypress `cypress.config.js`, Jest `jest.config.js`, Vitest `vitest.config.ts`), regex-parse them for reporter declarations, and patch in-place when auto-fix is enabled. The Go port must preserve byte-for-byte autofix output so existing project workflows don't see a churn diff on first m22 run. Land `ui_audit.go` last among the five checks; its tests own the most fixture surface.
- **Don't expand to TUI in this milestone.** The original phase5-stub.md candidate ordering grouped preflight + tui_ops. Splitting was deliberate after m21's dogfooded run produced 17 patch bumps for ~1500 LOC of port work — combined preflight + TUI is ~2600 LOC, too thrashy. TUI ports in m23. Resist the temptation to port `lib/tui_liveness.sh` opportunistically — it has runtime invariants (atomic-rename + sampled liveness probe) that deserve their own focused milestone.
- **`PREFLIGHT_REPORT.md` format must stay byte-identical.** Dashboard parsers (`lib/dashboard_parsers.sh`, still bash through m23) read the report. A whitespace or section-header change here ripples into dashboard diffs and surfaces as a downstream m23 problem. The parity gate exists specifically to catch this.
- **The `run_preflight_checks` rewrite has a circular-dependency landmine.** Today `tekhton-legacy.sh` sources `lib/preflight.sh` early (line 870) — *before* the `tekhton-legacy.sh:2968` call site. After m22, the function body just execs `tekhton preflight`. But `tekhton preflight` is provided by the same Go binary the legacy script falls back to. Make sure the `TEKHTON_BIN` resolution in `run_preflight_checks` handles the case where the binary doesn't exist (developer machine without `make build`) — emit the same warning shape as `finalize_run` in `lib/finalize.sh` so the failure mode is consistent between the two boundary hooks.
- **The `test_self_host_dry_run_gate` fix changes script ordering, not logic.** Be careful not to *also* skip the toolchain pre-check during a real `TEKHTON_SELF_HOST_DRY_RUN=1` run — the skip path is only when the flag is unset. Existing test `test_m20_dispatcher.sh` exercises the real-CI path and will catch a regression there.
- **Non-blocking router fix is NOT in m22 scope.** A drift entry from m21 closeout asked to fix the router that misclassified a CI-failing test. That router lives in `lib/drift_artifacts.sh` / `lib/test_baseline.sh` — m24 (notes/drift/clarify port) territory. Leave it.

## Seeds Forward

- **m23 — TUI ops port:** Will replace the two finalize-shim hooks currently in `lib/finalize_shim.sh` case arms (`_hook_tui_complete` and the TUI side of `_hook_final_dashboard_status`). The Python sidecar (`tools/tui.py`) stays; only the bash glue (`lib/tui_liveness.sh`, `lib/tui_ops*.sh`, `lib/tui.sh`, `lib/tui_helpers.sh`) ports. After m23 the `finalize_shim.sh` case for those two hooks deletes.
- **m24 — Notes/drift/clarify port:** Inherits the non-blocking router misclassification drift from m21 closeout. The router's `[fail|FAIL]` sentinel goes into the Go port; the question becomes whether the bash `lib/drift_artifacts.sh` even needs to ship the fix or just gets retired wholesale when the Go port lands.
- **m25 — Dashboard emitters port:** After m22, the bash `lib/dashboard_parsers.sh` is the only remaining consumer of preflight report format. The parity gate's "byte-identical PREFLIGHT_REPORT.md" requirement is what keeps dashboard parsers working through m23 and m24 until m25 retires them.
- **Parity-gate framework reuse:** `tests/test_preflight_parity.sh` should be parameterized along the same lines as `tests/test_finalize_parity.sh` from m21. Consider extracting a shared `tests/lib/parity.sh` driver — m23, m24, and m25 each add two or three new scenarios, and a shared driver avoids re-implementing the diff/normalize/compare scaffolding three more times.
- **Dogfooding feedback loop:** Track every bug surfaced during the m22 implementation run as a patch bump (`4.22.1`, `4.22.2`, …) with one-line postmortems in `docs/go-migration.md`. M21's 17 patch bumps over a ~1500-LOC port set the expected rate; m22 has roughly the same LOC surface and should land in a similar range. A bump count significantly higher than M21's is a signal to pause and audit, not just power through.
