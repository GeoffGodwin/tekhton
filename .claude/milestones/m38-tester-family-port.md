<!-- milestone-meta
id: "38"
status: "split"
-->

# m38 — Tester Family Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 Ship-of-Theseus port — fifth (and largest) stage-port milestone in the v4 sprint that turns the `stages/` bash directory into Go-native packages under `internal/stages/`. M34 established the pattern (intake), M35 ported reviewer, M36 ported security, M37 ported cleanup + docs. M38 takes on the most complex stage in tekhton: the tester family. The tester is not one file; it is six interlocking bash scripts (892 LOC) plus two lib subsystems (test_baseline 344 LOC, test_audit family 846 LOC) that together implement TDD pre-flight, primary-tester invocation, turn-exhaustion continuation, test failure auto-fix, post-run validation, baseline-aware acceptance gating, and a full test-integrity audit (orphan detection, weakening detection, M88 symbol-level stale-reference detection, M89 rolling freshness sampler, four-verdict routing). 2,082 LOC of bash collapsing into one Go package family. Without this port, the largest stage in the pipeline remains the largest bash island. |
| **Gap** | At m37 close: `stages/intake.sh`, `stages/reviewer.sh`, `stages/security.sh`, `stages/cleanup.sh`, `stages/docs.sh` are Go-native under `internal/stages/<name>/` (and their bash files deleted). `stages/tester*.sh` (six files, 892 LOC) and the two lib subsystems the tester depends on (`lib/test_baseline.sh` 344 LOC + `lib/test_audit*.sh` 6-file family 846 LOC) remain bash. The `DefaultStageDefs[StageTester]` entry in `internal/stagerunner/helpers.go:171-181` still names the bash entry script + six bash helpers. The `GoAdapter` cannot dispatch tester runs because no `StageDef.GoImpl` is wired for `StageTester`. The pipeline therefore continues to spawn a bash subprocess for the highest-LOC, longest-running stage in the system. The TDD pre-flight path, the test-audit verdict router (four outcomes), the M88 symbol detector, the M89 rolling sampler, the M92 baseline auto-pass, and the M64 inline fix loop are all bash. |
| **m38 fills** | The full tester family ports to Go across six sequenced child milestones, each independently dogfood-able. **M38.1 — Tester timing + validation helpers:** `internal/tester/timing.go` + `internal/tester/validation.go` (pure helpers, no agent calls — the fastest decimal). **M38.2 — TDD pre-flight stage:** `internal/tester/tdd/tdd.go` ports `tester_tdd.sh` and its pipeline_order gate; UPSTREAM error MUST propagate as a returned error (Go-equivalent of bash `exit 1` — regression hot-spot, see Watch For). **M38.3 — Fix + continuation orchestrators:** `internal/tester/fix.go` + `internal/tester/continuation.go` port the recursive depth-1 inline fix loop and the turn-exhaustion continuation loop. **M38.4 — Test audit family:** new `internal/test_audit/` package with `audit.go`, `detection.go`, `helpers.go`, `sampler.go`, `symbols.go`, `verdict.go` — ports the 6-file 846-LOC bash family in one decimal because the files cross-call each other heavily. **M38.5 — Test baseline port:** new `internal/test_baseline/` package — capture/has/compare API, plus the `TEST_BASELINE_PASS_ON_PREEXISTING` default-false gate the M92 milestone shipped. **M38.6 — Tester main stage port:** `internal/stages/tester/tester.go` consumes M38.1-M38.5; deletes all 6 `stages/tester*.sh` files; deletes `lib/test_baseline.sh` and the 6 `lib/test_audit*.sh` files; wires `StageDef.GoImpl` so `GoAdapter` dispatches `StageTester`. Parity tests use recorded `TESTER_REPORT.md` fixtures. |
| **Depends on** | m37 |
| **Files changed** | `internal/tester/timing.go`, `internal/tester/validation.go`, `internal/tester/tdd/tdd.go`, `internal/tester/fix.go`, `internal/tester/continuation.go`, `internal/test_audit/` (new package — 6 Go files), `internal/test_baseline/` (new package — 1 Go file), `internal/stages/tester/tester.go`, `internal/stagerunner/helpers.go` (modify — wire `GoImpl`), the 6 `stages/tester*.sh` files (delete in m38.6), `lib/test_baseline.sh` (delete in m38.5), 6 `lib/test_audit*.sh` files (delete in m38.4), parity test fixtures under `internal/stages/tester/testdata/`. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m34 | Intake port — established `internal/stages/<name>/` shape and `StageDef.GoImpl` dispatch path. |
| m35 | Reviewer port — refined the helpers-first / stage-second sequencing rule. |
| m36 | Security port — first stage with non-trivial helper port (security_helpers.sh). |
| m37 | Cleanup + docs ports — pair-ported because both are short and share the finalize sub-context. |
| **m38** | **Tester family — largest stage, six decimal children, two new shared subsystem packages (test_audit, test_baseline).** |

---

## Design

### Sequencing note

m38 is the largest decimal split in the Phase 5 batch (2,082 LOC of in-scope bash, 6 children — one more child than m32, which was the previous high-water mark). A six-child split is mandatory because the tester family has three logical sub-layers (helpers → orchestrators → main stage) and two adjacent subsystems (test_audit, test_baseline) that must port as standalone packages before the main stage can consume them. Collapsing any of the six into a sibling would either push the child over the m21/m22 retro's 25-patch-bump line or break the dependency chain.

The strict dependency order — M38.1 → M38.2 → M38.3 → M38.4 → M38.5 → M38.6 — means each child rebuilds the binary, runs its targeted unit tests, then dogfoods `tekhton run --milestone m38.X --complete`. Bash entry points stay live until M38.6 deletes them.

### Goal 1 — `internal/tester/` package shape

The Go-side layout mirrors the bash partition exactly so a reader who knows the bash can navigate the Go:

```
internal/tester/
├── timing.go              # M38.1 — _parse_tester_timing, _compute_tester_writing_time
├── timing_test.go         # M38.1
├── validation.go          # M38.1 — _validate_tester_output, REMAINING / compilation / failure routing
├── validation_test.go     # M38.1
├── tdd/                   # M38.2 — TDD write-failing sub-stage (own sub-package: it's gated by PIPELINE_ORDER)
│   ├── tdd.go
│   └── tdd_test.go
├── fix.go                 # M38.3 — _run_tester_inline_fix + _smart_truncate_test_output + _truncate_block
├── fix_test.go            # M38.3
├── continuation.go        # M38.3 — _tester_run_continuations + _run_and_record_test_audit
├── continuation_test.go   # M38.3
└── testdata/              # M38.6 — recorded TESTER_REPORT.md fixtures for parity replay

internal/test_audit/       # M38.4 — companion package (sourced by internal/tester via call, not import cycle)
├── audit.go               # run_test_audit + run_standalone_test_audit
├── detection.go           # _detect_orphaned_tests + _detect_test_weakening
├── helpers.go             # _collect_audit_context + _discover_all_test_files + _build_test_audit_context
├── sampler.go             # M89 rolling sampler — _ensure_test_audit_history_file + _record + _prune + _sample
├── symbols.go             # M88 symbol-level stale-ref detection (LSP gated on SERENA_ACTIVE)
├── verdict.go             # _parse_audit_verdict + _route_audit_verdict (PASS/CONCERNS/NEEDS_WORK)
└── audit_test.go          # M38.4

internal/test_baseline/    # M38.5
├── baseline.go            # capture_test_baseline + has_test_baseline + compare_test_with_baseline + stuck detection
└── baseline_test.go       # M38.5

internal/stages/tester/    # M38.6 — main stage entry, consumes the above
├── tester.go              # RunStage(ctx, req) — TDD branch + main flow + continuation + fix + audit
└── tester_test.go         # M38.6
```

### Goal 2 — `RunStage(ctx, req)` entry point (mirrors M34's intake pattern)

The tester's `RunStage` is the most complex stage entry in the codebase. The flow:

```go
// internal/stages/tester/tester.go
package tester

func RunStage(ctx context.Context, req *stagerunner.Request) (*stagerunner.Result, error) {
    // 1. TDD pre-flight branch — only when PIPELINE_ORDER=test_first AND TESTER_MODE=write_failing.
    //    Reads pipeline_order.sh state (M38.6 reads it via internal/pipeline package).
    if req.TesterMode == "write_failing" {
        return tdd.Run(ctx, req)
    }

    // 2. Build context + prompt (cached architecture, repo map slice, baseline summary, UI guidance).
    if err := buildTesterContext(ctx, req); err != nil { return nil, err }

    // 3. Invoke primary tester agent.
    agentResult, err := runner.InvokeAgent(ctx, req, agentToolsTester)
    if err != nil { return nil, err }

    // 4. UPSTREAM error short-circuit — write state, skip final checks.
    if agentResult.ErrorCategory == "UPSTREAM" {
        return saveUpstreamState(req, agentResult)
    }

    // 5. Null-run detection.
    if wasNullRun(agentResult) {
        return saveNullRunState(req, agentResult)
    }

    // 6. Parse self-reported timing into TesterTiming struct (M38.1).
    timing := tester.ParseTesterTiming(req.TesterReportFile, tester.ParseModeReplace)

    // 7. Validate tester output → route (M38.1 — _validate_tester_output).
    //    Returns one of: ValidationOK, CompilationErrors, TestFailures, PartialRun, NoReportButTestsCreated.
    decision := tester.ValidateOutput(ctx, req, agentResult)

    switch decision.Routing {
    case tester.RoutingTestFailures:
        if req.TesterFixEnabled && req.TesterFixMaxDepth > 0 {
            tester.RunInlineFix(ctx, req)              // M38.3
        }
    case tester.RoutingPartialRun:
        tester.RunContinuations(ctx, req)              // M38.3
    case tester.RoutingClean:
        test_audit.Run(ctx, req)                       // M38.4
    }

    // 8. Compute writing time, export timing fields onto the result envelope.
    return finalizeResult(req, agentResult, timing, decision), nil
}
```

`internal/tester` (lower-level helpers) is its own package; `internal/stages/tester` is the stage-entry package that calls into it. Same wrap pattern as M34's intake.

### Goal 3 — TDD pre-flight (M38.2) and the `exit 1` regression hot-spot

`stages/tester_tdd.sh:85` writes pipeline state and then `exit 1` on UPSTREAM error. An earlier version of this code path used `return` — that bug let the pipeline keep running after a TDD API failure, hitting unrelated downstream failures and confusing post-mortems. The fix was explicit: TDD UPSTREAM is fatal, halt the run.

When porting to Go, the equivalent is to **return a non-nil error from `tdd.Run`** so `stages/tester.RunStage` propagates it, the stage runner records it as a stage failure, and the pipeline halts. **Returning a `nil` error after writing state is the regression** — the bash `exit 1` does not translate to a Go `return` of a success-result struct.

```go
// internal/tester/tdd/tdd.go — UPSTREAM branch
if agentResult.ErrorCategory == "UPSTREAM" {
    saveState(req, "TDD pre-flight API error: "+agentResult.ErrorSubcategory)
    req.SkipFinalChecks = true
    return nil, fmt.Errorf("tdd pre-flight upstream error: %w", agentResult.Err)  // <-- non-nil error
}
```

`tdd_test.go` asserts this with a fake agent runner that returns `ErrorCategory=UPSTREAM`; the test asserts `err != nil` and the state file was written. A test that asserts `err == nil` is the regression-shaped bug.

### Goal 4 — Fix + continuation orchestrators (M38.3)

`tester_fix.sh` implements a depth-1 recursive inline-fix loop:

- Captures last N lines of failure output (`_smart_truncate_test_output` + `_truncate_block`).
- Baseline-aware short-circuit: if all failures are pre-existing per `compare_test_with_baseline`, skip fix entirely.
- Builds scoped context (TESTER_FIX_OUTPUT, TESTER_FIX_TEST_FILES, TESTER_FIX_SOURCE_FILES).
- Invokes a Tester agent (with build-fix tool set) on a `tester_fix` prompt.
- After agent returns, re-runs TEST_CMD (or skips via `test_dedup_can_skip`) and routes.

`tester_continuation.sh` implements turn-exhaustion continuation:

- Counts test files created via `git diff --stat HEAD`.
- Loops up to `MAX_CONTINUATION_ATTEMPTS` (default 3), each invocation rendering the `tester_resume` prompt with continuation context.
- Accumulates timing across continuations via `_parse_tester_timing` in accumulate mode.
- On clean finish (REMAINING==0), records audit history and runs the test audit.

The Go port preserves the depth-1 cap exactly via `TESTER_FIX_MAX_DEPTH` (default 1) and the MAX_CONTINUATION_ATTEMPTS default 3. Both are read from the config layer (`internal/config`).

```go
// internal/tester/fix.go
type FixOptions struct {
    MaxDepth     int     // TESTER_FIX_MAX_DEPTH=1
    OutputLimit  int     // TESTER_FIX_OUTPUT_LIMIT=4000
    MaxTurns     int     // TESTER_FIX_MAX_TURNS=26
}

func RunInlineFix(ctx context.Context, req *Request) (*FixResult, error)

// internal/tester/continuation.go
type ContinuationOptions struct {
    Enabled       bool   // CONTINUATION_ENABLED=true
    MaxAttempts   int    // MAX_CONTINUATION_ATTEMPTS=3
    NextTurnBudget int   // ADJUSTED_TESTER_TURNS or TESTER_MAX_TURNS
}

func RunContinuations(ctx context.Context, req *Request) (*ContinuationResult, error)
```

### Goal 5 — `internal/test_audit/` package (M38.4)

The audit family is six bash files (846 LOC) ported as one Go package because they cross-call:

- `helpers.go` — `_collect_audit_context`, `_discover_all_test_files`, `_build_test_audit_context`. Inputs: `TESTER_REPORT_FILE` (`- [x] \`path\``), `CODER_SUMMARY_FILE`, `git diff --name-status HEAD`. Output: `AuditContext{TestFiles, ImplFiles, DeletedFiles, SampleFiles, OrphanFindings, WeakeningFindings}`.
- `detection.go` — `_detect_orphaned_tests` (import-scanning Python/JS-TS/Go for deleted-module references), `_detect_test_weakening` (git diff scanning for net-loss of assertion lines, specific→broad assertion downgrades, and removed test functions).
- `sampler.go` — M89 rolling-K (default K=3) sampler. JSONL-based audit history at `cache_dir/test_audit_history.jsonl`, capped at `TEST_AUDIT_HISTORY_MAX_RECORDS` (default 500). Sample = least-recently-audited files NOT in this run's modified set.
- `symbols.go` — M88 symbol-level stale-reference detection. Cross-references `test_map.json` (test file → referenced symbols) against `tags.json` (source file → defined symbols). Currently shells out to `python3` for JSON manipulation; the Go port should NOT shell out — port the cross-reference to native Go (use `encoding/json`). **However, the underlying capability requires an LSP-populated test_map; `SERENA_ACTIVE` continues to gate the code path.**
- `verdict.go` — four-outcome router (PASS, CONCERNS, NEEDS_WORK, plus implicit GENERIC_FAIL when the report is missing entirely — treated as PASS by current bash, but flagged in WeakRoutingSpec). `_parse_audit_verdict` grep-extracts `Verdict:\s*(NEEDS_WORK|PASS|CONCERNS)`; `_route_audit_verdict` runs the side effects.
- `audit.go` — orchestrator. Runs context collection, sampler, three detectors (orphan/symbol/weakening), invokes the audit agent, parses verdict, optionally runs `TEST_AUDIT_MAX_REWORK_CYCLES` (default 1) rework cycles.

```go
// internal/test_audit/audit.go
type AuditResult struct {
    Verdict           string                // PASS | CONCERNS | NEEDS_WORK
    OrphanFindings    []string
    WeakeningFindings []string
    SymbolFindings    []string              // M88
    ReworkCycles      int
}

func Run(ctx context.Context, req *Request) (*AuditResult, error)
func RunStandalone(ctx context.Context, req *Request) (*AuditResult, error)  // --audit-tests CLI
```

### Goal 6 — `internal/test_baseline/` package (M38.5)

`lib/test_baseline.sh` is 344 LOC of M92 logic. The Go port preserves:

- `capture_test_baseline(milestone)` — runs `TEST_CMD`, writes `.claude/TEST_BASELINE.json` + `.claude/TEST_BASELINE_OUTPUT.txt`. Atomic via tmp+mv.
- `has_test_baseline(milestone)` — returns true iff a baseline exists for the named milestone (matches by exact milestone string in the JSON).
- `compare_test_with_baseline(output, exit)` — returns `pre_existing | new_failures | inconclusive`. Three branches: clean baseline → all new; matching failure hash → pre-existing; more failures than baseline → new; otherwise inconclusive.
- Output normalization: strip ANSI, strip timestamps, strip durations, strip hex addresses, strip PIDs (`_normalize_test_output`).
- Failure-line extraction: framework-agnostic grep for `FAIL`, `FAILED`, `ERROR`, `AssertionError`, `panic:`, etc. (`_extract_failure_lines`).
- Stuck detection (Tier 2): identical-hash run counter; on threshold, optionally auto-pass via `TEST_BASELINE_PASS_ON_STUCK`. **NOTE: `TEST_BASELINE_PASS_ON_PREEXISTING` is the older default-flipped-false flag — M92 flipped it to false to ensure auto-pass is opt-in. Preserve `false` as the Go default.**

```go
// internal/test_baseline/baseline.go
type Baseline struct {
    RunID        string
    Timestamp    time.Time
    Milestone    string
    ExitCode     int
    OutputHash   string
    FailureHash  string
    FailureCount int
}

func Capture(ctx context.Context, opts CaptureOptions) (*Baseline, error)
func Has(milestone string, projectDir string) bool
func Compare(output string, exitCode int, projectDir string) (Verdict, error)
// Verdict = PreExisting | NewFailures | Inconclusive
```

### Goal 7 — Main stage port and bash deletion (M38.6)

After M38.1-M38.5 land, M38.6 wires the stage:

1. Implement `internal/stages/tester/tester.go::RunStage` per Goal 2.
2. Add `GoImpl: tester.RunStage` to `DefaultStageDefs[StageTester]` in `internal/stagerunner/helpers.go`.
3. Trim the Helpers list for StageTester — only `lib/test_audit*.sh` files remain in the bash list, and those all delete in the same milestone, so the final Helpers list is `[]`.
4. Add parity tests using recorded TESTER_REPORT.md fixtures under `internal/stages/tester/testdata/` for:
   - clean-pass (verdict=PASS, REMAINING=0)
   - partial-run (REMAINING>0, exercises continuation)
   - compilation-errors (exercises the unchecked-flip reset)
   - test-failures (exercises inline fix, TESTER_FIX_ENABLED=true)
   - TDD write-failing (exercises tdd.Run branch)
5. Delete the bash files:
   ```
   git rm stages/tester.sh
   git rm stages/tester_continuation.sh
   git rm stages/tester_fix.sh
   git rm stages/tester_tdd.sh
   git rm stages/tester_timing.sh
   git rm stages/tester_validation.sh
   ```
6. Extend `scripts/wedge-audit.sh` to ban re-introduction of `stages/tester*.sh`.

### Goal 8 — `pipeline_order.sh` gate (TDD branch)

`tester.sh:50-54` reads `TESTER_MODE` and branches to `_run_tester_write_failing`. The TESTER_MODE value is set by `pipeline_order.sh` based on `PIPELINE_ORDER=test_first`. In the Go port, this gate moves into the stage runner: when `PIPELINE_ORDER=test_first` and this is the first tester invocation in the cycle, the runner sets `req.TesterMode="write_failing"` and `RunStage` dispatches into `tdd.Run`. **`pipeline_order.sh` continues to exist** at the M38 boundary — its port is a future arc (likely M39+ or a parallel pipeline-port milestone).

### Goal 9 — `TEST_DEDUP_ENABLED` preservation

`tester_fix.sh:162-176` calls `test_dedup_can_skip` / `test_dedup_record_pass` to skip redundant `TEST_CMD` invocations when no file fingerprint has changed since the last successful test run. **This optimization must be preserved in the Go fix path**: the M38.3 port consumes the `test_dedup` package (already Go-native from an earlier milestone — see `lib/test_dedup.sh` in `DefaultLibHelpers`; this remains bash through M38 and exposes its API via a shim during transition, or the Go port calls into the `internal/test_dedup` package if it exists). The acceptance criterion for M38.3 includes a test asserting that two consecutive `RunInlineFix` calls with no source change record exactly one `TEST_CMD` invocation.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `.claude/milestones/m38.1-tester-timing-and-validation.md` | Create | Decimal child — timing + validation helpers. |
| `.claude/milestones/m38.2-tester-tdd-pre-flight.md` | Create | Decimal child — TDD write-failing pre-flight, exit-1 regression-guarded. |
| `.claude/milestones/m38.3-tester-fix-and-continuation.md` | Create | Decimal child — fix loop + continuation loop. |
| `.claude/milestones/m38.4-test-audit-family.md` | Create | Decimal child — six audit bash files → internal/test_audit/. |
| `.claude/milestones/m38.5-test-baseline-port.md` | Create | Decimal child — baseline capture + compare + stuck detection. |
| `.claude/milestones/m38.6-tester-main-stage-port.md` | Create | Decimal child — main stage port + bash deletion + parity tests. |
| `.claude/milestones/MANIFEST.cfg` | Modify (by human at review pass) | Add seven rows for m38 / m38.1-m38.6. Not authored by this parent — human owns it. |

---

## Acceptance Criteria

- [ ] All six decimal child milestone files (`m38.1-tester-timing-and-validation.md`, `m38.2-tester-tdd-pre-flight.md`, `m38.3-tester-fix-and-continuation.md`, `m38.4-test-audit-family.md`, `m38.5-test-baseline-port.md`, `m38.6-tester-main-stage-port.md`) exist under `.claude/milestones/` and pass the m85 acceptance-criteria linter.
- [ ] Each child's `Depends on` row in `## Overview` matches the corresponding `depends_on` column in `MANIFEST.cfg` (m38.1 depends on m37.2, m38.2 depends on m38.1, m38.3 depends on m38.2, m38.4 depends on m38.3, m38.5 depends on m38.4, m38.6 depends on m38.5).
- [ ] No bash files under `stages/tester*.sh`, `lib/test_baseline.sh`, or `lib/test_audit*.sh` are deleted by this parent milestone — deletions live in M38.4 (test_audit), M38.5 (test_baseline), and M38.6 (stages/tester*.sh).
- [ ] No `internal/tester/`, `internal/test_audit/`, or `internal/test_baseline/` package directories exist on disk when this parent is filed (the children create them); the parent only authors the design.
- [ ] The parent's status in `MANIFEST.cfg` is `split` (not `todo` / `in_progress` / `done`); the runtime treats split-status parents as descriptive-only and does not schedule them for execution.
- [ ] The parent file H1 is `# m38 — Tester Family Port` (lowercase `m`, em dash `—`, title-case title).
- [ ] No `VERSION` bump at the parent level — bumps live in each decimal as it closes.

## Watch For

- **TDD UPSTREAM error MUST exit 1 (regression hot-spot — already caught once).** `stages/tester_tdd.sh:85` writes pipeline state and then `exit 1`. The Go-equivalent is to RETURN A NON-NIL ERROR from `tdd.Run`. Returning `nil` after writing state is the regression-shaped bug — the pipeline keeps running, hits unrelated downstream failures, and the post-mortem points at the wrong stage. M38.2 acceptance criteria explicitly asserts the error is non-nil; a test that fakes UPSTREAM and asserts `err != nil` is the regression-canary.
- **`TEST_BASELINE_PASS_ON_PREEXISTING` default flipped to false in M92 — preserve that default.** Earlier versions defaulted to true. M92 flipped to false to make auto-pass opt-in (operators have to explicitly opt into "ignore baseline failures"). The Go port at M38.5 must default the equivalent Go config to `false`. A test that asserts `DefaultPolicy().PassOnPreexisting == false` is the regression-canary.
- **Audit verdict routing has 4 outcomes, not 3.** `verdict.go` parses `PASS`, `CONCERNS`, `NEEDS_WORK`. There is an implicit fourth path: missing report → treated as PASS by current bash. M38.4 must port this exact behavior. If a future change wants the missing-report case to be a separate verdict (e.g. GENERIC_FAIL or ORPHAN_FAIL), that is a behavior change requiring a new milestone — do not slip it into M38.4.
- **The tester fix recursion is capped at `TESTER_FIX_MAX_DEPTH=1`.** The bash default in `tester_fix.sh:86` is 1, NOT 3 or some larger value. Going deeper than depth-1 was tried in V3 and led to runaway agent invocations that exhausted quota in seconds. **Preserve the default of 1.** A test in M38.3 that asserts `DefaultFixOptions().MaxDepth == 1` is the regression-canary.
- **`TEST_DEDUP_ENABLED` skips redundant TEST_CMD runs via fingerprint — don't break it.** `tester_fix.sh:162-176` only re-runs TEST_CMD when `test_dedup_can_skip` returns false. The Go fix-loop port at M38.3 must call into the same dedup API (via a shim until `lib/test_dedup.sh` itself ports). A test that runs two fix attempts with no source change and asserts exactly one `TEST_CMD` invocation guards this.
- **`pipeline_order.sh` decides whether TDD runs.** Only when `PIPELINE_ORDER=test_first` does `TESTER_MODE=write_failing` get set, which causes M38.2's `tdd.Run` to fire. `pipeline_order.sh` itself stays bash through M38; the gate moves into the stage runner at M38.6. Do NOT port `pipeline_order.sh` as part of M38 — it's a separate concern. If the M38.6 implementer is tempted to refactor pipeline_order at the same time, decline.
- **Symbol-level stale-reference detection (M88) needs an LSP. `SERENA_ACTIVE` gates this code path.** `test_audit_symbols.sh:17` returns early when `TEST_AUDIT_SYMBOL_MAP_ENABLED=false`; in practice the only useful caller is when Serena is running and produces `test_map.json` and `tags.json`. The Go port at M38.4 preserves the `SERENA_ACTIVE` / `TEST_AUDIT_SYMBOL_MAP_ENABLED` gates. **The current bash shells out to `python3` for JSON cross-reference — the Go port MUST NOT shell out**; use `encoding/json` directly. This is a small implementation-improvement that's safe to do as part of the port (it removes a runtime python dependency).
- **`test_audit.sh` cross-calls all five companion files — port them as one package, not six.** The bash files are split for the 300-line-per-file ceiling, NOT for logical isolation. The Go port at M38.4 ports them as a single `internal/test_audit/` package with six `.go` files; trying to put them in sub-packages creates import cycles (e.g. `audit.go` calls `helpers.go` calls `sampler.go` calls back into `helpers.go`).
- **`stages/` directory empties at M38.6 close + M39 close.** M38.6 leaves only `stages/coder*.sh`, `stages/architect.sh`, `stages/init_synthesize.sh`, `stages/plan_*.sh` bash. M39 (the coder family) is the final port. After M39, the directory is fully empty.

## Seeds Forward

- **M38.1 — Tester timing + validation helpers:** Lands the pure helpers — no agent calls, fastest decimal. Defines the `TesterTiming` struct (accumulator semantics for continuations) and the `ValidationDecision` enum (Clean / CompilationErrors / TestFailures / PartialRun / NoReportButTestsCreated) the orchestrators consume.
- **M38.2 — TDD pre-flight stage:** Ships the `internal/tester/tdd/` sub-package. UPSTREAM-error-returns-non-nil-error is the regression-canary. After M38.2, `pipeline_order.sh:test_first` users get the Go TDD path.
- **M38.3 — Fix + continuation orchestrators:** Lands the depth-1 inline fix loop (TESTER_FIX_ENABLED=true gates it; default depth=1) and the turn-exhaustion continuation loop (default max 3). Consumes M38.1 timing + validation. test_dedup shim continues to bridge.
- **M38.4 — Test audit family:** Lands `internal/test_audit/` as a standalone package. Six bash files delete in this decimal. M88 symbol detector ports to native Go (no python shell-out). M89 rolling sampler ports with the JSONL history file intact (operators can still cat it).
- **M38.5 — Test baseline port:** Lands `internal/test_baseline/` as a standalone package. M92 default (`PassOnPreexisting=false`) is preserved. `lib/test_baseline.sh` deletes in this decimal. The Tier 2 stuck-detection lives here too.
- **M38.6 — Tester main stage port:** Closes the arc. `internal/stages/tester/` consumes M38.1-M38.5. `StageDef.GoImpl` wires for `StageTester`. All six `stages/tester*.sh` files delete. Parity tests use recorded TESTER_REPORT.md fixtures. After M38.6, the tester is fully Go-native.
- **M39 — Coder family port (next and final stage-port milestone):** After M39, the `stages/` directory is fully empty and `tekhton-legacy.sh` can be re-examined for dismantling — probably its own M40+ initiative. M39 inherits the same six-decimal split pattern but operates on the coder family (coder.sh, coder_buildfix.sh, coder_buildfix_helpers.sh, coder_prerun.sh, architect.sh, init_synthesize.sh, the plan_* family).
- **`lib/test_dedup.sh` port:** Deferred. M38 calls into it via a shim. A future milestone (likely the build-fix-loop port, M39-adjacent) ports test_dedup. M38 acceptance preserves the optimization byte-for-byte by routing through the shim.
`
