<!-- milestone-meta
id: "16"
status: "todo"
-->

# m16 (V5) — Milestone Acceptance Verification Scripts (Format + Tester Integration)

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V5 Phase 1 reliability fix. Across m09, m12, m13 (and likely earlier milestones we haven't audited) we've observed a structural failure mode: the milestone gets marked done despite the coder agent skipping core deliverables. The five pipeline gates (intake, coder, security, review, tester) collectively miss this because: intake runs before code exists; coder is the agent's own self-report; security only scans files that DO exist; review reads the agent's narrative without independent verification; **the tester runs `go test ./...` which trivially passes when there are no tests for the missing code**. The result: a passing run with the manifest flipped to done, the operator believing the milestone is complete, only to discover hours later that the Chain is dead code, the tool translator was never built, the `--require-tier` flag doesn't exist, etc. The fix is structural: every milestone MUST ship with an executable acceptance verification script. The tester runs the script as a mandatory gate. Non-zero exit = milestone INCOMPLETE regardless of `go test` output. m16 lands the format, the tester integration, and backfills scripts for m14 + m15 so those milestones get the protection when they run. |
| **Gap** | Today acceptance criteria in milestone files are prose checkboxes (`- [ ] X happens when Y`). They're aspirational, not executable. The tester stage doesn't know about them. There's no automation that says "you claimed X exists — let me verify." When the coder skips a deliverable, no gate catches it. The "Verification command for the coder before reporting COMPLETE" sections I added to m07/m09/m14/m15 milestone files are guidance for the agent to self-check — but nothing forces the agent to actually run them, and the tester doesn't run them either. The acceptance criteria are completely advisory. |
| **m16 fills** | (1) New convention: every milestone file `.claude/milestones/m<N>-<slug>.md` has a sibling `.claude/milestones/m<N>-acceptance.sh` containing an executable bash script that verifies the milestone's deliverables. Script authored by the milestone author at draft time (not by the coder during the run). (2) `internal/tester/acceptance.go` — `RunAcceptanceScript(projectDir, milestoneID string) (passed bool, output string, err error)` that locates the script via the milestone ID, runs it with `set -euo pipefail`, captures stdout/stderr, and returns the verdict. (3) `internal/stages/tester/<existing file>.go` modification — after the existing TEST_CMD invocation passes, also run the acceptance script. Failure routes the stage to FAIL with `ErrorSubcategory = "ACCEPTANCE_FAILED"`. (4) Finalize-time gate: if `_CURRENT_MILESTONE` is set and the acceptance script exists but exited non-zero in the tester stage, `_hook_mark_done` refuses to flip the manifest. (5) Backfill: `.claude/milestones/m14-acceptance.sh` + `.claude/milestones/m15-acceptance.sh` so those in-flight milestones gain protection when they run. (6) `.tekhton/MILESTONE_TEMPLATE.md` updated to require the acceptance script as part of milestone authoring. (7) `docs/v5-milestone-acceptance.md` — author guidance, examples, escape hatch (a milestone genuinely without verifiable deliverables can document why and skip — but the default is "every milestone has a script"). |
| **Depends on** | none (independent reliability fix; m14/m15 don't depend on m16 but BENEFIT from it via the backfilled scripts) |
| **Files changed** | `internal/tester/acceptance.go` (~140 LOC, CREATE), `internal/tester/acceptance_test.go` (~160 LOC, CREATE), `internal/stages/tester/<tester file>.go` (~30 LOC modify — find the existing test-runner site and add the acceptance call after), `internal/finalize/<mark_done file>.go` (~30 LOC modify — gate manifest flip on acceptance script result), `.claude/milestones/m14-acceptance.sh` (~50 LOC, CREATE — backfill), `.claude/milestones/m15-acceptance.sh` (~60 LOC, CREATE — backfill), `.tekhton/MILESTONE_TEMPLATE.md` (modify — require acceptance script), `docs/v5-milestone-acceptance.md` (~120 LOC, CREATE — author guidance), `tests/test_acceptance_runner.sh` (~100 LOC, CREATE — shim-boundary), `VERSION` |

---

## Design

### HARD SCOPE BOUNDARY (m16 ONLY)

**Eating our own dog food: m16's verification script MUST be in this
commit alongside its design doc. If `.claude/milestones/m16-acceptance.sh`
doesn't exist at the end of the coder phase, m16 is INCOMPLETE.**

CREATE (9 files):
1. `internal/tester/acceptance.go` — `RunAcceptanceScript` function
2. `internal/tester/acceptance_test.go` — tests
3. `.claude/milestones/m14-acceptance.sh` — backfill (executable bash)
4. `.claude/milestones/m15-acceptance.sh` — backfill
5. `.claude/milestones/m16-acceptance.sh` — m16's own script (this milestone)
6. `docs/v5-milestone-acceptance.md` — author guidance
7. `tests/test_acceptance_runner.sh` — shim-boundary integration test
8. `internal/finalize/acceptance_gate.go` — finalize-time check (or fold into existing mark_done file)
9. `internal/finalize/acceptance_gate_test.go`

MODIFY (3 files):
10. `internal/stages/tester/<file>.go` — wire `RunAcceptanceScript` after TEST_CMD
11. `internal/finalize/orchestrator.go` (or the mark_done file) — gate manifest flip on acceptance result
12. `.tekhton/MILESTONE_TEMPLATE.md` — require acceptance script section

PLUS `VERSION` bump.

**Verification command:**

```bash
test -f internal/tester/acceptance.go && \
test -f .claude/milestones/m14-acceptance.sh && \
test -f .claude/milestones/m15-acceptance.sh && \
test -f .claude/milestones/m16-acceptance.sh && \
test -x .claude/milestones/m16-acceptance.sh && \
test -f docs/v5-milestone-acceptance.md && \
grep -q 'func RunAcceptanceScript' internal/tester/acceptance.go && \
grep -q 'RunAcceptanceScript' internal/stages/tester/ -r && \
echo "m16 deliverables present"
```

### Goal 1 — `RunAcceptanceScript`

**File:** `internal/tester/acceptance.go`.

```go
package tester

import (
    "fmt"
    "os"
    "os/exec"
    "path/filepath"
    "time"
)

// AcceptanceResult captures the outcome of running a milestone's
// acceptance verification script.
type AcceptanceResult struct {
    ScriptPath string
    Found      bool   // True if the script existed at the expected path
    Passed     bool   // True if the script exited 0
    ExitCode   int
    Stdout     string
    Stderr     string
    Duration   time.Duration
}

// RunAcceptanceScript looks for `.claude/milestones/m<id>-acceptance.sh`
// under projectDir. If found, executes it with `bash -euo pipefail`
// and a 5-minute timeout. Returns a typed result.
//
// Convention: missing script means "no acceptance check defined" (not
// a failure). This lets existing milestones land without scripts
// during the m16 backfill window. NEW milestones MUST ship with a
// script — enforced by the milestone-authoring template, not by
// this runner.
func RunAcceptanceScript(projectDir, milestoneID string) (*AcceptanceResult, error) {
    if projectDir == "" {
        return nil, fmt.Errorf("acceptance: empty projectDir")
    }
    if milestoneID == "" {
        return nil, fmt.Errorf("acceptance: empty milestoneID")
    }
    // Normalize: strip leading "m" if present.
    id := milestoneID
    if len(id) > 1 && id[0] == 'm' {
        id = id[1:]
    }
    scriptPath := filepath.Join(projectDir, ".claude", "milestones", fmt.Sprintf("m%s-acceptance.sh", id))

    if _, err := os.Stat(scriptPath); os.IsNotExist(err) {
        return &AcceptanceResult{ScriptPath: scriptPath, Found: false}, nil
    } else if err != nil {
        return nil, fmt.Errorf("acceptance: stat %s: %w", scriptPath, err)
    }

    cmd := exec.Command("bash", "-c", fmt.Sprintf("set -euo pipefail; %q", scriptPath))
    cmd.Dir = projectDir
    var stdout, stderr []byte
    start := time.Now()
    stdout, err := cmd.Output()
    duration := time.Since(start)
    if exitErr, ok := err.(*exec.ExitError); ok {
        stderr = exitErr.Stderr
        return &AcceptanceResult{
            ScriptPath: scriptPath,
            Found:      true,
            Passed:     false,
            ExitCode:   exitErr.ExitCode(),
            Stdout:     string(stdout),
            Stderr:     string(stderr),
            Duration:   duration,
        }, nil
    }
    if err != nil {
        return nil, fmt.Errorf("acceptance: run %s: %w", scriptPath, err)
    }
    return &AcceptanceResult{
        ScriptPath: scriptPath,
        Found:      true,
        Passed:     true,
        ExitCode:   0,
        Stdout:     string(stdout),
        Duration:   duration,
    }, nil
}
```

### Goal 2 — Tester stage integration

**File:** `internal/stages/tester/<existing file>.go` (find the tester
runner that invokes TEST_CMD; likely `run.go` or `tester.go` per the
m38.6 port).

After TEST_CMD passes successfully, run the acceptance script:

```go
// In the tester stage's main flow, after TEST_CMD succeeds:
if milestoneID := os.Getenv("_CURRENT_MILESTONE"); milestoneID != "" {
    res, err := tester.RunAcceptanceScript(cfg.ProjectDir, milestoneID)
    if err != nil {
        log.Warn(fmt.Sprintf("acceptance script error: %v", err))
    } else if res.Found && !res.Passed {
        log.Error(fmt.Sprintf("ACCEPTANCE FAILED for %s (exit %d):\n%s\n%s",
            milestoneID, res.ExitCode, res.Stdout, res.Stderr))
        // Return failResult with ErrorSubcategory = "ACCEPTANCE_FAILED"
        return failResult(req, "acceptance_failed", agentCalls, map[string]string{
            "milestone_id":    milestoneID,
            "script_path":     res.ScriptPath,
            "script_exit":     fmt.Sprintf("%d", res.ExitCode),
            "script_stdout":   res.Stdout,
            "script_stderr":   res.Stderr,
        }), nil
    } else if res.Found && res.Passed {
        log.Info(fmt.Sprintf("acceptance script PASSED for %s in %s",
            milestoneID, res.Duration))
    } else {
        log.Info(fmt.Sprintf("no acceptance script at %s — skipping check",
            res.ScriptPath))
    }
}
```

### Goal 3 — Finalize-time gate

**File:** `internal/finalize/acceptance_gate.go` (new) or fold into
the existing `mark_done.go` or `orchestrator.go`.

The finalize chain SHOULD already see ACCEPTANCE_FAILED via the
tester stage's verdict. But add a belt-and-suspenders check at
`_hook_mark_done`: if the tester recorded an acceptance failure
in stage metadata, refuse to flip the manifest even if the chain
somehow reached this point.

### Goal 4 — Backfill scripts for m14 + m15

**File:** `.claude/milestones/m14-acceptance.sh`.

```bash
#!/usr/bin/env bash
# m14 acceptance verification: cost telemetry + budget caps.
set -euo pipefail

# Production files
for f in \
    internal/provider/cost.go \
    internal/provider/cost_aggregator.go \
    internal/provider/costrates.json \
    cmd/tekhton/forecast.go \
    docs/v5-cost-banner-example.md; do
    [[ -f "$f" ]] || { echo "FAIL: $f missing"; exit 1; }
done

# Type + function presence
grep -q 'type CostEstimator' internal/provider/cost.go      || { echo "FAIL: CostEstimator type missing"; exit 1; }
grep -q 'RunCostAggregator' internal/provider/cost_aggregator.go || { echo "FAIL: RunCostAggregator missing"; exit 1; }

# CLI flags
grep -q 'max-cost-usd' cmd/tekhton/run.go || { echo "FAIL: --max-cost-usd flag missing"; exit 1; }
grep -q 'forecast' cmd/tekhton/run.go     || { echo "FAIL: --forecast subcommand missing"; exit 1; }

# pipeline.conf
grep -q 'STAGE_BUDGET_USD' templates/pipeline.conf.example || { echo "FAIL: STAGE_BUDGET_USD block missing"; exit 1; }

# RUN_SUMMARY cost banner
grep -q 'Cost Summary' internal/finalize/emit_run_summary.go || { echo "FAIL: Cost Summary banner missing"; exit 1; }

# Tests pass for the new code
go test ./internal/provider/... -count=1 -run 'Cost|Budget|Estimator|Aggregator' || { echo "FAIL: cost tests failing"; exit 1; }

echo "PASS: m14 acceptance"
```

**File:** `.claude/milestones/m15-acceptance.sh`.

```bash
#!/usr/bin/env bash
# m15 acceptance verification: chain wiring + CLI + docs.
set -euo pipefail

# Files
test -f internal/runner/provider_select.go        || { echo "FAIL: provider_select.go missing"; exit 1; }
test -f internal/runner/provider_select_test.go   || { echo "FAIL: provider_select_test.go missing"; exit 1; }
test -f docs/v5-polyglot.md                       || { echo "FAIL: v5-polyglot.md missing"; exit 1; }
test -f docs/v5-tier-model.md                     || { echo "FAIL: v5-tier-model.md missing"; exit 1; }

# Function presence
grep -q 'func ResolveProvider' internal/runner/provider_select.go    || { echo "FAIL: ResolveProvider missing"; exit 1; }
grep -q 'func constructProvider' internal/runner/provider_select.go  || { echo "FAIL: constructProvider missing"; exit 1; }

# CLI flags
grep -q -- '"provider"' cmd/tekhton/run.go        || { echo "FAIL: --provider flag missing"; exit 1; }
grep -q -- '"provider-chain"' cmd/tekhton/run.go  || { echo "FAIL: --provider-chain flag missing"; exit 1; }
grep -q -- '"require-tier"' cmd/tekhton/run.go    || { echo "FAIL: --require-tier flag missing"; exit 1; }

# pipeline.conf
grep -q 'PROVIDER=' templates/pipeline.conf.example || { echo "FAIL: PROVIDER block missing"; exit 1; }

# init_config
grep -q 'PROVIDER' lib/init_config_sections.sh || { echo "FAIL: init_config PROVIDER emitter missing"; exit 1; }

# Runner no longer hardcodes claude singleton
if grep -q 'Provider:[[:space:]]*claude\.New' internal/runner/runner.go; then
    echo "FAIL: runner.go still has hardcoded claude.New() — should use providerForStage"
    exit 1
fi

# Tests pass for the new code
go test -run TestResolveProvider ./internal/runner/... -count=1 || { echo "FAIL: ResolveProvider tests failing"; exit 1; }

echo "PASS: m15 acceptance"
```

### Goal 5 — Template update

**File:** `.tekhton/MILESTONE_TEMPLATE.md`.

Add a section near the top:

```markdown
## Acceptance Script (REQUIRED)

Every milestone MUST ship with an executable acceptance verification
script at `.claude/milestones/m<N>-acceptance.sh`. The script:

- Uses `#!/usr/bin/env bash` shebang + `set -euo pipefail`
- Verifies each declared "Files Modified" entry exists
- Verifies key functions/types/flags by grep
- Runs the targeted Go tests for the new code
- Echoes `PASS: m<N> acceptance` on success
- Exits non-zero with a clear `FAIL:` message on any check failure

The tester stage runs this script as a mandatory gate. A milestone
whose script doesn't exist OR doesn't pass is INCOMPLETE.

Authors WITHOUT verifiable deliverables (rare — pure documentation
milestones, for example) MAY ship a script that just echoes the
exemption rationale. The empty-script escape hatch is intentionally
small.
```

### Goal 6 — Docs

**File:** `docs/v5-milestone-acceptance.md` (~120 LOC).

Sections:
1. Why acceptance scripts (the m09/m12/m13 failure mode).
2. Format conventions.
3. What to verify (deliverable presence, function/type signatures, behavior).
4. What NOT to verify (don't re-run the full suite — keep the script fast).
5. Examples (the m14 and m15 backfills as case studies).
6. The exemption escape hatch + when it's appropriate.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/tester/acceptance.go` | Create | `RunAcceptanceScript` function + typed result. ~140 LOC. |
| `internal/tester/acceptance_test.go` | Create | Tests for the runner: script-missing, pass, fail, timeout. ~160 LOC. |
| `internal/stages/tester/<runner file>.go` | Modify | Wire `RunAcceptanceScript` after TEST_CMD. |
| `internal/finalize/acceptance_gate.go` | Create | Belt-and-suspenders mark_done gate. |
| `internal/finalize/acceptance_gate_test.go` | Create | Tests. |
| `.claude/milestones/m14-acceptance.sh` | Create | Backfill for m14. |
| `.claude/milestones/m15-acceptance.sh` | Create | Backfill for m15. |
| `.claude/milestones/m16-acceptance.sh` | Create | m16's own script. |
| `.tekhton/MILESTONE_TEMPLATE.md` | Modify | Require acceptance script in milestone authoring. |
| `docs/v5-milestone-acceptance.md` | Create | Author guide. |
| `tests/test_acceptance_runner.sh` | Create | Shim-boundary integration. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

(These get verified by `.claude/milestones/m16-acceptance.sh` — the
self-referential test. The criteria are written here for human review.)

- [ ] `internal/tester/acceptance.go::RunAcceptanceScript` exists and returns `(*AcceptanceResult, error)`.
- [ ] `AcceptanceResult.Found` is false when the script doesn't exist at the expected path.
- [ ] `AcceptanceResult.Passed` is true when the script exits 0.
- [ ] `AcceptanceResult.Passed` is false when the script exits non-zero; `ExitCode`, `Stdout`, `Stderr` are populated.
- [ ] The tester stage calls `RunAcceptanceScript` after TEST_CMD succeeds.
- [ ] A milestone with a failing acceptance script results in `ErrorSubcategory = "ACCEPTANCE_FAILED"` and the manifest does NOT flip done.
- [ ] `.claude/milestones/m14-acceptance.sh` and `m15-acceptance.sh` exist and are executable.
- [ ] `.claude/milestones/m16-acceptance.sh` exists and verifies m16's own deliverables.
- [ ] `.tekhton/MILESTONE_TEMPLATE.md` instructs future milestone authors to include an acceptance script.
- [ ] `docs/v5-milestone-acceptance.md` exists with the documented sections.
- [ ] No regression in m07-m13 tests, V5 m04-m06, m41-m50.
- [ ] `golangci-lint run` and `go vet` clean.
- [ ] Full suite passes.

## Watch For

- **The backfill scripts for m14/m15 must use `set -euo pipefail`**
  AND check exit codes explicitly. Bash's exit-on-fail semantics
  catch unset vars and pipe failures, but specific grep results
  need an explicit `|| exit 1`.
- **Don't run the full suite from the acceptance script.** The
  tester already runs `bash tests/run_tests.sh`. The acceptance
  script should run only the milestone-relevant subset (e.g.,
  `go test -run 'TestResolveProvider' ./internal/runner/...`).
  Keeps verification fast.
- **The script's PASS/FAIL output is the contract.** Echo
  `PASS: m<N> acceptance` on success, `FAIL: <specific gap>` on
  failure. The tester captures both and surfaces to operators.
- **Don't make the script's exit gate too strict for "draft"
  milestones.** During milestone-author iteration, the script
  may not yet match the design. That's fine — the milestone
  isn't being run yet. The gate fires only when the milestone
  is actually executed.
- **The 5-minute timeout in `RunAcceptanceScript` is intentional.**
  Acceptance scripts should be FAST (file existence + grep
  + targeted tests). If a script takes 5 minutes, it's doing too
  much — refactor.
- **Empty/exemption scripts must STILL echo PASS.** The format
  `echo "PASS: m<N> acceptance (exempt — pure documentation)"`
  with exit 0 is acceptable for rare cases. Don't let exemptions
  spread to deliverable-heavy milestones.

## Seeds Forward

- **Backfill scripts for closed milestones.** Existing done
  milestones (m07-m13) could get retroactive acceptance scripts
  for regression-prevention. Not strictly necessary — those
  milestones are done — but worth as a polish pass.
- **Auto-generate acceptance script skeletons.** A future
  `tekhton --new-milestone <id>` subcommand could create the
  milestone file + a starter acceptance script from a template.
- **Per-criterion test attribution.** Currently each criterion
  in the milestone file points to "see acceptance script" — a
  future enhancement could embed the specific bash command per
  criterion line, parsed by tooling to generate the script.
- **Acceptance script in causal log.** Record per-milestone
  acceptance results in `.claude/logs/causal/` for historical
  audit ("when did m12's acceptance start passing? what changed?").
