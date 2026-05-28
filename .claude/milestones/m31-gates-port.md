<!-- milestone-meta
id: "31"
status: "split"
-->

# m31 — Gates Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — the gates subsystem is the next-highest-leverage bash port after preflight (m22) and the env-contract closeout (m26/m27). Gates are load-bearing for the coder stage: `run_build_gate` runs after every coder turn, `run_completion_gate` decides whether to advance to review, and the build-fix loop (`stages/coder_buildfix.sh`) is the most-iterated control surface in any real pipeline run. Today `BashHookRunner` indirectly invokes these gates by sourcing `lib/gates*.sh` into the per-stage subprocess; the Go runner has no awareness of phase boundaries, no structured failure capture, and no way to time-bound a specific phase except through the omnibus `BUILD_GATE_TIMEOUT`. Until gates are Go, the supervisor still hands control to bash for the inner loop of the coder→review transition — mirroring the situation m22 just fixed at the front of the pipeline. |
| **Gap** | `lib/gates.sh` (217 lines, build-gate orchestration), `lib/gates_phases.sh` (205 lines, analyze + compile phase split with M54 remediation loops), `lib/gates_completion.sh` (134 lines, completion gate + M63 test enforcement + M92 baseline comparison), `lib/gates_ui.sh` (183 lines, M126 hardened UI rerun + signature classification), and `lib/gates_ui_helpers.sh` (190 lines, framework detection + deterministic env profile) total 929 lines of bash that run on every coder turn. Eight call sites in `stages/` invoke `run_build_gate`; one call site in `stages/coder.sh:1126` invokes `run_completion_gate`. The build-fix loop in `stages/coder_buildfix.sh` reads `${BUILD_ERRORS_FILE}` and `${BUILD_RAW_ERRORS_FILE}` via `_bf_read_raw_errors` and classifies failures through the Go `internal/errors` taxonomy from m17. The classifier is already Go; the *producer* of its input is still bash. |
| **m31 fills** | This is a split-status parent arc. The work is too large for a single milestone (929 LOC across two semantically distinct sub-systems, plus a parity-gate fixture set, plus the M127/M128 routing-compat surface, plus VERSION + dogfood cutover). Splitting along the natural seam — load-bearing build/completion gates vs. bounded UI gate — gives each piece an independently dogfood-able close state. **m31.1** ports `lib/gates.sh` + `lib/gates_phases.sh` + `lib/gates_completion.sh` to `internal/gates/{build.go, phases.go, completion.go}`. **m31.2** ports `lib/gates_ui.sh` + `lib/gates_ui_helpers.sh` to `internal/gates/ui.go`. Cross-cutting design is captured below: package shape, CLI surface, build-fix-loop interaction contract. `VERSION` bumps to `4.31.0` only on m31.2 close (m31.1 ships a Go subsystem behind a thin bash shim and does not require a VERSION bump). |
| **Depends on** | m27 |
| **Files changed** | `internal/gates/` (new package), `cmd/tekhton/gate.go` (new subcommand tree), `internal/runner/runner.go` (BashHookRunner build-gate seam), `tekhton-legacy.sh` (drop the five `source lib/gates*.sh` lines), five deletions under `lib/gates*.sh`, parity tests under `tests/test_gates_parity*.sh` and fixtures under `tests/testdata/gates/`. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m17 | Error taxonomy Go package (`internal/errors`). Classifies BUILD_ERRORS.md content; consumed by the build-fix loop after every gate failure. |
| m21 | Finalize chain port. Established the `internal/<subsystem>/` package layout pattern m31 reuses for `internal/gates/`. |
| m22 | Preflight port. Established the "delete the bash files outright, rewire `tekhton-legacy.sh` to exec `tekhton <subcommand>`" cutover pattern m31 reuses. |
| m26 | Stage env contract. The Go gate runs inside the same StageEnvV1 surface every other stage subprocess gets — no special-cased env propagation. |
| m27 | Bash subprocess hardening. Closed the consumer-side env-contract gap; m31 can safely assume `BUILD_GATE_TIMEOUT`, `ANALYZE_CMD`, `BUILD_CHECK_CMD`, `TEST_CMD`, and friends are populated when the Go gate reads them. |
| **m31** | **Gates subsystem ported to Go. Build/completion gates land in m31.1; UI gate lands in m31.2.** |

---

## Design

### Sequencing note

m31.1 must land before m31.2 because the UI gate emits its errors into `${BUILD_ERRORS_FILE}` — the same file the build gate writes. The Go UI gate (m31.2) appends to a file the Go build gate (m31.1) creates, and both must agree on the markdown shape `_bf_read_raw_errors` parses. Landing them in the other order leaves a window where the Go UI gate is appending to a bash-produced file, which is exactly the kind of straddle state that produced m23's partial cascade.

Both children depend on m27 transitively (through m26). No new env-contract work is needed in m31; the gates subsystem reads only contract-defined globals that m27 already hardened.

### Goal 1 — Package shape: `internal/gates/`

The Go subsystem mirrors the bash file split:

```go
package gates

// BuildGate orchestrates the multi-phase build gate (analyze + compile +
// constraints + ui_test + ui_validation). Ports lib/gates.sh:run_build_gate.
type BuildGate struct {
    Env        *proto.StageEnvV1
    Phases     []Phase
    Timeout    time.Duration  // BUILD_GATE_TIMEOUT
    Errors     ErrorsWriter   // owns BUILD_ERRORS_FILE + BUILD_RAW_ERRORS_FILE
    Remediator Remediator     // M54 auto-remediation interface
    Clock      func() time.Time
}

// CompletionGate runs after coder, before build gate. Ports
// lib/gates_completion.sh:run_completion_gate.
type CompletionGate struct {
    Env         *proto.StageEnvV1
    SummaryFile string                  // CODER_SUMMARY_FILE
    TestCmd     string                  // TEST_CMD
    Baseline    TestBaselineComparer    // M92 baseline comparison interface
    Dedup       TestDedup               // M63 dedup interface
}

// UIGate runs UI_TEST_CMD as build-gate phase 4. Ports lib/gates_ui.sh.
type UIGate struct {
    Env           *proto.StageEnvV1
    Framework     Framework             // playwright | none (M130)
    HardenedRetry bool                  // UI_GATE_ENV_RETRY_ENABLED
    Errors        ErrorsWriter          // shared with BuildGate
}
```

Each gate exposes a single `Run(ctx context.Context) error` entry point. Errors implement `errors.Is/As` against `internal/errors` sentinels so the build-fix classifier (m17) keeps working unchanged.

### Goal 2 — CLI surface: `tekhton gate <subcommand>`

Match m22's hidden-subcommand pattern. Three subcommands under `tekhton gate`:

```text
tekhton gate build      --stage-label <label>     # post-coder / post-jr-coder / etc.
tekhton gate completion                            # no args; reads CODER_SUMMARY_FILE
tekhton gate ui         --stage-label <label>     # standalone UI gate
```

All three are `Hidden: true` Cobra subcommands. End users never invoke them directly — they run transitively via the per-stage subprocess that previously sourced `lib/gates*.sh`. The CLI exists for: (a) the bash shim from `tekhton-legacy.sh`, (b) standalone dogfood/debug invocations, (c) the parity gate harness.

The bash shim in `tekhton-legacy.sh` becomes:

```bash
# m31: gates subsystem ported to Go. The bash entry points still need
# the functions `run_build_gate`, `run_completion_gate`, and the
# internal `_run_ui_test_phase` for legacy compatibility; they now exec
# `tekhton gate <subcommand>` so the Go orchestrator drives both paths.
run_build_gate() {
    local tekhton_bin="${TEKHTON_BIN:-${TEKHTON_HOME:-.}/bin/tekhton}"
    "$tekhton_bin" gate build --stage-label "${1:-unknown}"
}
run_completion_gate() {
    local tekhton_bin="${TEKHTON_BIN:-${TEKHTON_HOME:-.}/bin/tekhton}"
    "$tekhton_bin" gate completion
}
```

Both shims exit with the gate's exit code so the eight callers in `stages/` keep working without source-level changes.

### Goal 3 — Build-fix-loop interaction contract

`stages/coder_buildfix.sh:run_build_fix_loop` is the most behaviorally-sensitive consumer of gate output. It does three things the Go port MUST preserve:

1. **Reads `${BUILD_RAW_ERRORS_FILE}` first, falls back to `${BUILD_ERRORS_FILE}`** (`_bf_read_raw_errors`, line 32). The raw file is the unadorned grep output of `ANALYZE_ERROR_PATTERN` or `BUILD_ERROR_PATTERN` matches. The annotated file (`.md`) contains markdown headers that confuse the m17 classifier — `_bf_read_raw_errors` prefers the raw stream specifically to avoid that.
2. **Greps `## Stage` and `## Errors` headers** from `BUILD_ERRORS.md` to extract the stage label for routing. The Go port writes exactly those headers in exactly that order (analyze before compile, compile after analyze; UI test failures appended in a separate `## UI Test Failures` section after compile).
3. **Re-runs `run_build_gate` after the build-fix agent returns** (`coder_buildfix.sh:216`). The Go gate must be safely re-entrant from the same process tree — no static state in `internal/gates/`, all state on the `BuildGate` receiver.

The classifier itself (`internal/errors`) is already Go and consumes the raw stream byte-identically; m31 changes only the producer side.

### Goal 4 — M127/M128 routing compatibility

M127 and M128 added build-fix routing classifications (`env_setup`, `hard_fault`, `interactive_report`, etc.) that key off specific substrings in `${BUILD_RAW_ERRORS_FILE}`. The Go gate writes byte-identical raw streams for each phase:

- **Analyze raw stream:** `printf '%s\n' "$analyze_errors"` from `_gate_write_analyze_errors` (`gates_phases.sh:20`). Go equivalent: `phase_analyze.go` writes the same bytes via `os.WriteFile` with a trailing newline.
- **Compile raw stream:** `printf '%s\n' "$compile_errors" >> ...` from `_gate_write_compile_errors` (`gates_phases.sh:116`). Append mode preserved — the Go port appends to the raw file when both phases run.
- **UI raw stream:** `printf '%s\n' "$_ui_output" > ...` from `_run_ui_test_phase` (`gates_ui.sh:129`). Note the `>` (truncate), not `>>` — UI failures overwrite the raw file because they fire only after analyze + compile pass.

The byte-identical guarantee is what the parity gate enforces; M127/M128 routing keeps working transparently.

### Goal 5 — Timeout surface preservation

`BUILD_GATE_TIMEOUT` (default 600s) is the omnibus gate timeout. `BUILD_GATE_ANALYZE_TIMEOUT` (300s), `BUILD_GATE_COMPILE_TIMEOUT` (120s), `BUILD_GATE_CONSTRAINT_TIMEOUT` (60s), `UI_TEST_TIMEOUT` (120s) are per-phase. The Go port preserves the bash semantics:

- Per-phase timeout is the *minimum* of the configured per-phase timeout and remaining gate time (`_gate_effective_timeout`).
- When remaining gate time hits zero, `_gate_check_timeout` writes a synthetic `BUILD_ERRORS.md` with the H1 `# Build Errors — <YYYY-MM-DD HH:MM:SS>` and a `## Gate Timeout` section. The Go port emits the *exact* same H1 timestamp format (Go: `time.Now().Format("2006-01-02 15:04:05")`) so `test_audit`'s grep patterns still match.
- Phase exit code 124 (the bash `timeout` utility's timeout exit) is treated as a pass with a warning — preserved verbatim. Go equivalent: `context.DeadlineExceeded` from `exec.CommandContext` is mapped to the same outcome.

### Goal 6 — Parity gate

`tests/test_gates_parity.sh` (m31.1) + `tests/test_gates_ui_parity.sh` (m31.2) drive each gate against captured fixtures and diff output + exit codes against frozen bash baselines. Fixtures under `tests/testdata/gates/`:

| Scenario | Fixture | Expected outcome |
|----------|---------|------------------|
| analyze-pass | `analyze_clean/` | exit 0, no BUILD_ERRORS.md |
| analyze-fail | `analyze_dirty/` | exit 1, BUILD_ERRORS.md with `## Analyze Errors` section |
| compile-pass | `compile_clean/` | exit 0, no BUILD_ERRORS.md |
| compile-fail | `compile_dirty/` | exit 1, BUILD_ERRORS.md with `## Compile Errors` section |
| completion-pass | `completion_pass/` | exit 0, TEST_CMD ran |
| completion-fail-tests | `completion_test_fail/` | exit 1, TEST_CMD output captured |
| completion-fail-status | `completion_no_status/` | exit 1, "no clear Status field" warning |
| timeout | `gate_timeout/` | exit 1, synthetic `# Build Errors — <ts>` H1 |
| ui-pass | `ui_clean/` | exit 0 (m31.2 only) |
| ui-fail-interactive | `ui_interactive_report/` | exit 1, hardened rerun attempted, `## UI Gate Diagnosis` section emitted (m31.2 only) |

Each scenario asserts byte-identical raw stream + report (after timestamp normalization) between the captured bash baseline and the m31 Go gate.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/gates/` | Create | New Go package — build/completion gates (m31.1) and UI gate (m31.2). |
| `cmd/tekhton/gate.go` | Create | `tekhton gate build|completion|ui` Hidden Cobra subcommand tree. |
| `internal/runner/runner.go` | Modify | Phase 5 cutover: the BashHookRunner gate seam goes away in favor of in-process Go invocation. |
| `tekhton-legacy.sh` | Modify | Drop the five `source lib/gates*.sh` lines; rewrite `run_build_gate` / `run_completion_gate` shims to exec `tekhton gate <subcommand>`. |
| `lib/gates.sh` | Delete | Ported to `internal/gates/build.go` (m31.1). |
| `lib/gates_phases.sh` | Delete | Ported to `internal/gates/phases.go` (m31.1). |
| `lib/gates_completion.sh` | Delete | Ported to `internal/gates/completion.go` (m31.1). |
| `lib/gates_ui.sh` | Delete | Ported to `internal/gates/ui.go` (m31.2). |
| `lib/gates_ui_helpers.sh` | Delete | Ported to `internal/gates/ui_helpers.go` (m31.2). |
| `tests/test_gates_parity.sh` | Create | Build + completion parity gate (m31.1). |
| `tests/test_gates_ui_parity.sh` | Create | UI gate parity gate (m31.2). |
| `tests/testdata/gates/` | Create | Per-scenario fixture projects (m31.1 owns the build/completion fixtures; m31.2 adds the UI fixtures). |
| `docs/v4-phase5-stub.md` | Modify | Update the gates subsystem row from "port pending" to "done (m31)" with the post-m31 LOC count. |
| `VERSION` | Modify | Bumps to `4.31.0` only on m31.2 close (parent arc completion). |

---

## Acceptance Criteria

- [ ] m31.1 closes with status `done` in `.claude/milestones/MANIFEST.cfg`.
- [ ] m31.2 closes with status `done` in `.claude/milestones/MANIFEST.cfg` (depends on m31.1 done).
- [ ] `internal/gates/` package exists and exports `BuildGate`, `CompletionGate`, `UIGate` types.
- [ ] `cmd/tekhton/gate.go` registers `tekhton gate build`, `tekhton gate completion`, `tekhton gate ui` as Hidden Cobra subcommands; `tekhton gate --help` lists all three.
- [ ] `tekhton-legacy.sh` no longer sources any `lib/gates*.sh`; the eight `run_build_gate` call sites and the single `run_completion_gate` call site keep working unchanged through the shim.
- [ ] The five `lib/gates*.sh` files are deleted; `find lib -name 'gates*.sh'` returns nothing.
- [ ] `tests/test_gates_parity.sh` and `tests/test_gates_ui_parity.sh` both exit 0.
- [ ] `stages/coder_buildfix.sh:_bf_read_raw_errors` reads the Go-written `${BUILD_RAW_ERRORS_FILE}` and `${BUILD_ERRORS_FILE}` without modification (verified by an end-to-end fixture test that runs the build-fix loop against a Go-gate failure).
- [ ] `go test ./internal/gates/... ./cmd/tekhton/...` passes.
- [ ] `bash tests/run_tests.sh` reports zero new failures at m31.2 close.
- [ ] `VERSION` reads `4.31.0` after m31.2 close.
- [ ] `docs/v4-phase5-stub.md` gates row reads "done (m31 — five files deleted, ported to internal/gates/)".

## Watch For

- **m31.1 changes load-bearing code.** Every coder turn invokes `run_build_gate`. Run the parity gate (`tests/test_gates_parity.sh`) and at least one dogfooded `tekhton run --milestone <small-fixture>` before rebuilding tekhton-stable. A regression here surfaces as every pipeline run advancing to review with broken builds.
- **m31.2 is bounded but not free.** UI gates fire only when `UI_TEST_CMD` is set, which most milestones don't exercise. But projects that DO set it (anything Playwright-based) hit the M126 hardened-rerun path on every transient failure — getting the rerun's deterministic env profile byte-identical matters even if the gate is bounded in invocation frequency.
- **The `## Stage` / `## Errors` markdown shape is a public ABI.** `stages/coder_buildfix.sh` greps these headers. Whitespace or section-header changes in the Go port ripple into the build-fix routing layer and surface as classifier misses (the failure looks like "build-fix loop did nothing" rather than "gate produced wrong output"). The parity gate exists specifically to catch this.
- **Synthetic timeout BUILD_ERRORS.md format must stay byte-identical.** `_gate_check_timeout` writes a `# Build Errors — <YYYY-MM-DD HH:MM:SS>` H1 when the gate times out. `test_audit`'s grep patterns key off this exact format. The Go port uses `time.Now().Format("2006-01-02 15:04:05")` to match.
- **The completion gate's TEST_CMD invocation is where the M27.2 cascade hit (read < /dev/tty hang).** Now fixed at the prompt level by m27, but the gate itself must not regress that behavior. Test the Go completion gate with stdin=/dev/null — the gate must complete without blocking on a controlling terminal.
- **UI gates depend on m26 + m27 env-contract guarantees.** The Go port must respect `MILESTONE_MODE`, `TEKHTON_DIR`, `PROJECT_DIR`, `UI_FRAMEWORK`, `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE`, `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED` so fixture isolation under `tests/test_stage_env_setu.sh`-style tests keeps working.
- **Build-fix routing classification (m17) is already Go (`internal/errors`).** The Go gate's BUILD_ERRORS.md output feeds straight into the classifier — no change needed there. Resist the temptation to "co-locate" the classifier inside `internal/gates/`; it's a deliberate separation.

## Seeds Forward

- **m32 — Milestone DAG runtime port:** Will replace `lib/milestones.sh` + `lib/milestone_acceptance.sh` + `lib/milestone_ops.sh`. Those files import `run_build_gate` (see `lib/milestone_acceptance.sh:104` and `lib/milestones.sh:4`); after m31 they import through the shim. m32 can either keep the shim or in-process Go-call `gates.BuildGate.Run` directly.
- **m33 — Stages port:** Will retire the bash `stages/*.sh` files entirely. The eight `run_build_gate` call sites and the single `run_completion_gate` call site go away in m33; m31's CLI surface (`tekhton gate <subcommand>`) becomes the only invocation path, then deletes when no bash caller remains.
- **Parity-gate framework reuse:** `tests/test_gates_parity.sh` should be parameterized along the same lines as `tests/test_preflight_parity.sh` from m22. If `tests/lib/parity.sh` exists by m31 land, reuse it; otherwise extract it as part of m31.1's deliverable.
- **Dogfooding feedback loop:** Track every bug surfaced during the m31.1 implementation run as a patch bump (`4.30.1`, `4.30.2`, …) and roll the parent-arc VERSION bump to `4.31.0` only on m31.2 close. m22 set the precedent (~17 patch bumps over ~1500 LOC); m31 has roughly 60% of that LOC surface and should land in a similar per-LOC bump rate.
- **Remediation interface generalization:** The `Remediator` interface on `BuildGate` is the seam for the future M54 auto-remediation port. Today the bash gate calls `_gate_try_remediation` directly; the Go port treats the remediator as a pluggable dependency. Whichever later milestone ports `lib/remediation*.sh` inherits a ready-shaped Go interface.
