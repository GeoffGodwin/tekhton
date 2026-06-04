package architect

// drift_integration_test.go — m36.1 full-audit-path assertions.
//
// The reviewer parity-gate note (REVIEWER_REPORT.md) identified that
// tests/test_architect_parity.sh only checks verdict strings because the
// TEKHTON_AGENT_BINARY=/bin/false approach causes RunStage to return early
// (agent_error) before plan-parse code runs. The Go unit tests here exercise
// the same three milestone scenarios using the fakeAgent seam so the full
// audit path actually executes, and assert the four mandatory properties:
//
//   1. sr / jr dispatch count
//   2. post-resolve drift count (drift log file state)
//   3. HUMAN_ACTION_REQUIRED.md item count
//   4. audit counter reset (runs_since_audit → 0)
//
// These tests complement — not replace — the existing architect_test.go
// branch-level tests.

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/drift"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// jrWorkOnlyPlan has Staleness Fixes only (no Simplification, no OOS, no
// Design Doc Observations). This exercises the "jr-only" dispatch branch.
const jrWorkOnlyPlan = `# Architect Plan

## Simplification

- None

## Staleness Fixes

- lib/foo.sh:55 references old_fn renamed in m23.

## Dead Code Removal

- None

## Naming Normalization

- None

## Out of Scope

- None

## Design Doc Observations

- None
`

// writeDriftLogWithCounter writes a DRIFT_LOG.md in the canonical format that
// drift.Log.GetRunsSinceAudit / ResetRunsSinceAudit can read. Uses title-case
// "Runs since audit" (not the underscore form) to match the regex in
// drift.Log.GetRunsSinceAudit.
func writeDriftLogWithCounter(t *testing.T, path string, nEntries, runsSinceAudit int) {
	t.Helper()
	var sb strings.Builder
	sb.WriteString("# Drift Log\n\n## Metadata\n")
	sb.WriteString(fmt.Sprintf("- Last audit: never\n- Runs since audit: %d\n", runsSinceAudit))
	sb.WriteString("\n## Unresolved Observations\n\n")
	for i := 0; i < nEntries; i++ {
		sb.WriteString(fmt.Sprintf("- [ ] [2026-06-04 | \"review-cycle\"] drift item %s\n",
			string(rune('A'+i))))
	}
	sb.WriteString("\n## Resolved\n")
	if err := os.WriteFile(path, []byte(sb.String()), 0o644); err != nil {
		t.Fatalf("writeDriftLogWithCounter: %v", err)
	}
}

// setupDriftFixture creates a temp project dir with a canonical drift log and
// architect plan, configures the test environment, and returns paths to the
// key artifacts. The drift log uses the title-case counter format so
// GetRunsSinceAudit / ResetRunsSinceAudit work correctly.
func setupDriftFixture(t *testing.T, planContent string, nDrift, runsSinceAudit int) (dir, driftPath, haPath string) {
	t.Helper()
	dir = t.TempDir()
	tekhtonDir := filepath.Join(dir, ".tekhton")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatalf("setupDriftFixture mkdir: %v", err)
	}

	driftPath = filepath.Join(dir, "DRIFT_LOG.md")
	writeDriftLogWithCounter(t, driftPath, nDrift, runsSinceAudit)

	haPath = filepath.Join(tekhtonDir, "HUMAN_ACTION_REQUIRED.md")
	planPath := filepath.Join(tekhtonDir, "ARCHITECT_PLAN.md")
	if err := os.WriteFile(planPath, []byte(planContent), 0o644); err != nil {
		t.Fatalf("setupDriftFixture write plan: %v", err)
	}

	// Configure env so loadConfig() picks up the right file paths.
	// PROJECT_DIR / TEKHTON_HOME come from makeReq's EnvOverrides (those
	// take priority in envOrFromReq), so we only need to set file-specific
	// overrides here.
	t.Setenv("DRIFT_LOG_FILE", driftPath)
	t.Setenv("HUMAN_ACTION_FILE", haPath)
	t.Setenv("ARCHITECT_PLAN_FILE", planPath)
	return dir, driftPath, haPath
}

// assertDriftCount reads the drift log and fails the test if the unresolved
// count is not want.
func assertDriftCount(t *testing.T, driftPath string, want int) {
	t.Helper()
	l := drift.NewLog(driftPath)
	got, err := l.CountUnresolved()
	if err != nil {
		t.Fatalf("CountUnresolved(%s): %v", driftPath, err)
	}
	if got != want {
		t.Errorf("drift count after audit: want %d, got %d", want, got)
	}
}

// assertAuditCounterReset reads the drift log and fails the test if
// runs_since_audit is not 0.
func assertAuditCounterReset(t *testing.T, driftPath string) {
	t.Helper()
	l := drift.NewLog(driftPath)
	runs, err := l.GetRunsSinceAudit()
	if err != nil {
		t.Fatalf("GetRunsSinceAudit(%s): %v", driftPath, err)
	}
	if runs != 0 {
		t.Errorf("runs_since_audit after audit: want 0, got %d", runs)
	}
}

// assertHAItemCount reads the HA file and checks the number of unchecked items.
func assertHAItemCount(t *testing.T, haPath string, want int) {
	t.Helper()
	content, err := os.ReadFile(haPath)
	if os.IsNotExist(err) {
		if want == 0 {
			return // absent == 0 items: correct
		}
		t.Fatalf("HUMAN_ACTION_REQUIRED.md absent but want %d item(s)", want)
	}
	if err != nil {
		t.Fatalf("read HUMAN_ACTION_REQUIRED.md: %v", err)
	}
	got := strings.Count(string(content), "- [ ]")
	if got != want {
		t.Errorf("HUMAN_ACTION_REQUIRED.md: want %d items, got %d\n%s", want, got, content)
	}
}

// --------------------------------------------------------------------------
// Scenario 1 — audit-with-simplification
// --------------------------------------------------------------------------

// TestRunStage_FullAuditPath_SimplificationScenario verifies the complete
// state mutations for the "audit-with-simplification" milestone scenario:
//
//   - sr (Simplification) AND jr (Staleness + DeadCode + Naming) dispatched
//   - drift 5 → 1 (1 OOS item re-added after resolve-all)
//   - HUMAN_ACTION_REQUIRED.md gains 2 actionable design-doc entries
//   - runs_since_audit reset to 0
//
// Uses testdata/plan_baseline.md which has all sections populated.
func TestRunStage_FullAuditPath_SimplificationScenario(t *testing.T) {
	planBytes, err := os.ReadFile(filepath.Join("testdata", "plan_baseline.md"))
	if err != nil {
		t.Fatalf("read baseline plan: %v", err)
	}
	dir, driftPath, haPath := setupDriftFixture(t, string(planBytes), 5, 6)
	a, _, _ := withStubs(t)
	req := makeReq(dir)

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("Verdict: want pass, got %s", res.Verdict)
	}
	if res.ExitReason != "audit_complete" {
		t.Errorf("ExitReason: want audit_complete, got %s", res.ExitReason)
	}

	// sr dispatched exactly once (Simplification section populated).
	srCount := 0
	jrCount := 0
	for _, c := range a.calls {
		switch c.Label {
		case "Coder (architect remediation)":
			srCount++
		case "Jr Coder (architect remediation)":
			jrCount++
		}
	}
	if srCount != 1 {
		t.Errorf("sr dispatch count: want 1, got %d", srCount)
	}
	// jr dispatched exactly once (Staleness + Dead Code + Naming populated).
	if jrCount != 1 {
		t.Errorf("jr dispatch count: want 1, got %d", jrCount)
	}

	// Drift: baseline plan has 1 OOS item that survives the filter
	// ("Refactor the orchestrate retry loop..."). After resolve-all (5 → 0)
	// + AppendEntries (re-add 1 OOS) the unresolved count is 1.
	assertDriftCount(t, driftPath, 1)

	// HA: baseline plan has 2 actionable design-doc items; boilerplate
	// ("All observations documented", "route to human review", etc.) filtered.
	assertHAItemCount(t, haPath, 2)

	// Audit counter reset.
	assertAuditCounterReset(t, driftPath)
}

// --------------------------------------------------------------------------
// Scenario 2 — audit-with-jr-work-only
// --------------------------------------------------------------------------

// TestRunStage_FullAuditPath_JrWorkOnlyScenario verifies state mutations for
// the "audit-with-jr-work-only" milestone scenario:
//
//   - sr NOT dispatched, jr dispatched exactly once
//   - drift 3 → 0 (no OOS items to re-add)
//   - HUMAN_ACTION_REQUIRED.md unchanged (no design-doc observations)
//   - runs_since_audit reset to 0
func TestRunStage_FullAuditPath_JrWorkOnlyScenario(t *testing.T) {
	dir, driftPath, haPath := setupDriftFixture(t, jrWorkOnlyPlan, 3, 6)
	a, _, _ := withStubs(t)
	req := makeReq(dir)

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("Verdict: want pass, got %s", res.Verdict)
	}

	// sr MUST NOT run — Simplification is empty.
	srCount := 0
	jrCount := 0
	for _, c := range a.calls {
		switch c.Label {
		case "Coder (architect remediation)":
			srCount++
		case "Jr Coder (architect remediation)":
			jrCount++
		}
	}
	if srCount != 0 {
		t.Errorf("sr dispatch count: want 0 (no Simplification), got %d", srCount)
	}
	if jrCount != 1 {
		t.Errorf("jr dispatch count: want 1, got %d", jrCount)
	}

	// Drift: all 3 entries resolved, no OOS → 0 unresolved.
	assertDriftCount(t, driftPath, 0)

	// HA: no design-doc observations → file absent or has 0 unchecked items.
	assertHAItemCount(t, haPath, 0)

	// Audit counter reset.
	assertAuditCounterReset(t, driftPath)
}

// --------------------------------------------------------------------------
// Scenario 3 — audit-with-design-doc-observations
// --------------------------------------------------------------------------

// TestRunStage_FullAuditPath_DesignDocOnlyScenario verifies state mutations
// for the "audit-with-design-doc-observations" milestone scenario:
//
//   - no sr / jr dispatched (Simplification and jr sections all "None")
//   - drift 2 → 0 (no OOS items)
//   - HUMAN_ACTION_REQUIRED.md gains exactly 2 actionable entries
//     (boilerplate bullets filtered by the designDocFilters chain)
//   - runs_since_audit reset to 0
//
// Uses testdata/plan_design_doc_only.md.
func TestRunStage_FullAuditPath_DesignDocOnlyScenario(t *testing.T) {
	planBytes, err := os.ReadFile(filepath.Join("testdata", "plan_design_doc_only.md"))
	if err != nil {
		t.Fatalf("read design_doc_only plan: %v", err)
	}
	dir, driftPath, haPath := setupDriftFixture(t, string(planBytes), 2, 6)
	a, g, _ := withStubs(t)
	req := makeReq(dir)

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("Verdict: want pass, got %s", res.Verdict)
	}

	// Only architect agent should have run — no remediation dispatched.
	if len(a.calls) != 1 {
		t.Errorf("agent calls: want 1 (architect only), got %d (%v)", len(a.calls), labels(a.calls))
	}
	// Build gate must not have run (no remediation).
	if len(g.calls) != 0 {
		t.Errorf("build gate calls: want 0, got %v", g.calls)
	}

	// Drift: 2 entries resolved, no OOS → 0 unresolved.
	assertDriftCount(t, driftPath, 0)

	// HA: 2 actionable items survive the filter. plan_design_doc_only.md has:
	//   - "DESIGN.md Stage map..." → kept
	//   - "ARCHITECTURE.md File Ownership..." → kept
	//   - "All observations are documented in CLAUDE.md" → filtered
	//   - "(route to human review)" → filtered
	assertHAItemCount(t, haPath, 2)

	// Audit counter reset.
	assertAuditCounterReset(t, driftPath)
}

// --------------------------------------------------------------------------
// Edge case — build_broken preserves drift, resets counter
// --------------------------------------------------------------------------

// TestRunStage_BuildBroken_DriftUnchangedCounterReset verifies that when both
// build gate attempts fail after architect remediation, the drift log entries
// are NOT resolved (the bash code path: "Drift observations NOT resolved"),
// but the audit counter IS reset (resetAuditCounter fires before the early
// return at architect.go:182-185).
func TestRunStage_BuildBroken_DriftUnchangedCounterReset(t *testing.T) {
	plan := `# Architect Plan

## Simplification

- Inline a one-shot helper at lib/helpers.sh.

## Staleness Fixes

- None

## Dead Code Removal

- None

## Naming Normalization

- None

## Out of Scope

- None

## Design Doc Observations

- None
`
	dir, driftPath, haPath := setupDriftFixture(t, plan, 2, 6)
	_, g, _ := withStubs(t)
	// Both build gate attempts fail.
	g.errs = []error{errors.New("compile failed"), errors.New("still broken")}
	req := makeReq(dir)

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("Verdict: want pass (build_broken does not fail the stage), got %s", res.Verdict)
	}
	if res.ExitReason != "build_broken" {
		t.Errorf("ExitReason: want build_broken, got %s", res.ExitReason)
	}

	// Drift entries NOT resolved — resolve-all is skipped on build_broken path.
	assertDriftCount(t, driftPath, 2)

	// HA: no design-doc observations in this plan.
	assertHAItemCount(t, haPath, 0)

	// Audit counter IS reset even on build_broken (architect.go:182 behavior).
	assertAuditCounterReset(t, driftPath)
}
