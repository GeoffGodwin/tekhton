package security

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/proto"
	sec "github.com/geoffgodwin/tekhton/internal/security"
)

// fakeProvider is a recording provider.Provider that can vary its behavior
// across successive invocations. The Behaviors slice is consumed one entry per
// RunAgent() call; once exhausted, RunAgent returns the default success result
// with TurnsUsed=5 so a test that doesn't explicitly script every call still
// makes forward progress.
type fakeProvider struct {
	Calls     []*provider.Request
	Behaviors []func(*provider.Request) (*provider.Result, error)
	idx       int
}

func (f *fakeProvider) Name() string { return "fake-security" }

func (f *fakeProvider) RunAgent(_ context.Context, req *provider.Request) (*provider.Result, error) {
	f.Calls = append(f.Calls, req)
	if f.idx < len(f.Behaviors) {
		b := f.Behaviors[f.idx]
		f.idx++
		return b(req)
	}
	return &provider.Result{
		Outcome:   provider.OutcomeSuccess,
		ExitCode:  0,
		TurnsUsed: 5,
	}, nil
}

// fakeBuildGate is a recording BuildGateRunner. By default Run returns nil
// (pass); tests override Err to drive the failure branch.
type fakeBuildGate struct {
	Err   error
	Calls int
}

func (f *fakeBuildGate) Run(_ context.Context, _, _ string) error {
	f.Calls++
	return f.Err
}

// installSeams wires fakes for both seams and returns a restore func.
func installSeams(t *testing.T, ag *fakeProvider, gate BuildGateRunner) func() {
	t.Helper()
	prevA := SetProvider(ag)
	prevG := SetBuildGateRunner(gate)
	return func() {
		SetProvider(prevA)
		SetBuildGateRunner(prevG)
	}
}

// repoRoot walks up to the tekhton repo root (the directory containing
// go.mod) so the prompt loader can resolve prompts/security_scan.prompt.md.
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, _ := os.Getwd()
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("repo root not found")
		}
		dir = parent
	}
}

// setupProject creates a temp project dir with a sensible default env that
// keeps every code path off process state. Tests then layer in fixture
// content (CODER_SUMMARY.md, SECURITY_REPORT.md, …) and override env vars
// as needed via t.Setenv.
func setupProject(t *testing.T) (string, *proto.StageRequestV1) {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".tekhton"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	// Default toggle/state — individual tests override.
	t.Setenv("TEKHTON_DIR", ".tekhton")
	t.Setenv("SECURITY_AGENT_ENABLED", "true")
	t.Setenv("SKIP_SECURITY", "false")
	t.Setenv("MILESTONE_MODE", "false")
	t.Setenv("SECURITY_FINDINGS_BLOCK", "")
	t.Setenv("SECURITY_FIXES_BLOCK", "")
	t.Setenv("SECURITY_REWORK_CYCLES_DONE", "0")

	req := &proto.StageRequestV1{
		Proto: proto.StageRequestProtoV1,
		Stage: proto.StageSecurity,
		Task:  "test task",
		EnvOverrides: map[string]string{
			"PROJECT_DIR":          dir,
			"TEKHTON_HOME":         repoRoot(t),
			"PIPELINE_STAGE_POS":   "2",
			"PIPELINE_STAGE_COUNT": "4",
		},
		ResultFile: filepath.Join(dir, "result.json"),
	}
	return dir, req
}

// writeReport drops content at .tekhton/SECURITY_REPORT.md.
func writeReport(t *testing.T, dir, content string) {
	t.Helper()
	p := filepath.Join(dir, ".tekhton", "SECURITY_REPORT.md")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatalf("write SECURITY_REPORT.md: %v", err)
	}
}

// writeCoderSummary drops content at .tekhton/CODER_SUMMARY.md so the
// IsDocsOnly check can resolve.
func writeCoderSummary(t *testing.T, dir, content string) {
	t.Helper()
	p := filepath.Join(dir, ".tekhton", "CODER_SUMMARY.md")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatalf("write CODER_SUMMARY.md: %v", err)
	}
}

// fixture-01: SECURITY_AGENT_ENABLED=false → verdict=skip / agent_disabled.
func TestRunStage_AgentDisabled(t *testing.T) {
	_, req := setupProject(t)
	t.Setenv("SECURITY_AGENT_ENABLED", "false")
	restore := installSeams(t, &fakeProvider{}, &fakeBuildGate{})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictSkip {
		t.Errorf("verdict=%q want skip", res.Verdict)
	}
	if res.ExitReason != "agent_disabled" {
		t.Errorf("exit_reason=%q want agent_disabled", res.ExitReason)
	}
}

// fixture-02: SKIP_SECURITY=true → verdict=skip / skip_flag.
func TestRunStage_SkipFlag(t *testing.T) {
	_, req := setupProject(t)
	t.Setenv("SKIP_SECURITY", "true")
	restore := installSeams(t, &fakeProvider{}, &fakeBuildGate{})
	defer restore()

	res, _ := RunStage(context.Background(), req)
	if res.Verdict != proto.VerdictSkip || res.ExitReason != "skip_flag" {
		t.Errorf("got verdict=%q reason=%q want skip/skip_flag", res.Verdict, res.ExitReason)
	}
}

// fixture-03: CODER_SUMMARY lists only .md files → verdict=skip / docs_only.
func TestRunStage_DocsOnly(t *testing.T) {
	dir, req := setupProject(t)
	writeCoderSummary(t, dir, `# Coder Summary
## Files Modified
- README.md
- docs/index.md
- CHANGELOG.md
`)
	restore := installSeams(t, &fakeProvider{}, &fakeBuildGate{})
	defer restore()

	res, _ := RunStage(context.Background(), req)
	if res.Verdict != proto.VerdictSkip || res.ExitReason != "docs_only" {
		t.Errorf("got verdict=%q reason=%q want skip/docs_only", res.Verdict, res.ExitReason)
	}
}

// fixture-04: agent writes empty report → verdict=pass / no_findings,
// agentCalls=1.
func TestRunStage_PassNoFindings(t *testing.T) {
	dir, req := setupProject(t)
	writeCoderSummary(t, dir, `# Coder Summary
## Files Modified
- src/auth.go
`)
	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			func(r *provider.Request) (*provider.Result, error) {
				// Simulate the agent: write an empty SECURITY_REPORT.md.
				writeReport(t, dir, `## Summary
No issues.

## Findings
None

## Verdict
CLEAN
`)
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 3}, nil
			},
		},
	}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate)
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict=%q want pass", res.Verdict)
	}
	if res.ExitReason != "no_findings" {
		t.Errorf("exit_reason=%q want no_findings", res.ExitReason)
	}
	if res.AgentCalls != 1 {
		t.Errorf("agent_calls=%d want 1", res.AgentCalls)
	}
	if gate.Calls != 0 {
		t.Errorf("build gate called %d times, want 0", gate.Calls)
	}
}

// fixture-05: scan→rework→scan loop completes (3 agent calls, cycle=1).
func TestRunStage_FixableReworkPass(t *testing.T) {
	dir, req := setupProject(t)
	writeCoderSummary(t, dir, `# Coder Summary
## Files Modified
- src/auth.go
`)

	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			// scan 1: 1 CRITICAL fixable finding
			func(*provider.Request) (*provider.Result, error) {
				writeReport(t, dir, `## Summary
Issue found.

## Findings
- [CRITICAL] [category:A03] [auth.go:42] fixable:yes — SQL injection in login query

## Verdict
FINDINGS_PRESENT
`)
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 8}, nil
			},
			// rework: pretend the fix was applied
			func(*provider.Request) (*provider.Result, error) {
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 10}, nil
			},
			// scan 2: empty report
			func(*provider.Request) (*provider.Result, error) {
				writeReport(t, dir, `## Summary
Clean.

## Findings
None

## Verdict
CLEAN
`)
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 3}, nil
			},
		},
	}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate)
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict=%q want pass", res.Verdict)
	}
	if res.ExitReason != "complete" {
		t.Errorf("exit_reason=%q want complete", res.ExitReason)
	}
	if res.AgentCalls != 3 {
		t.Errorf("agent_calls=%d want 3 (scan+rework+scan)", res.AgentCalls)
	}
	if gate.Calls != 1 {
		t.Errorf("build gate called %d times, want 1", gate.Calls)
	}
	if os.Getenv("SECURITY_REWORK_CYCLES_DONE") != "1" {
		t.Errorf("SECURITY_REWORK_CYCLES_DONE=%q want 1", os.Getenv("SECURITY_REWORK_CYCLES_DONE"))
	}
	if fb := os.Getenv("SECURITY_FIXES_BLOCK"); !strings.Contains(fb, "1 cycle") {
		t.Errorf("SECURITY_FIXES_BLOCK=%q want to mention '1 cycle'", fb)
	}
}

// fixture-06: HIGH unfixable + halt policy → verdict=block / security_halt,
// HumanAction=true.
func TestRunStage_UnfixableHalt(t *testing.T) {
	dir, req := setupProject(t)
	writeCoderSummary(t, dir, `# Coder Summary
## Files Modified
- src/auth.go
`)
	t.Setenv("SECURITY_UNFIXABLE_POLICY", "halt")
	t.Setenv("PIPELINE_STATE_FILE", filepath.Join(dir, ".tekhton", "PIPELINE_STATE.json"))

	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			func(*provider.Request) (*provider.Result, error) {
				writeReport(t, dir, `## Summary
Issue found.

## Findings
- [HIGH] [category:A07] [auth.go:10] fixable:no — Hardcoded secret requires infra rotation

## Verdict
FINDINGS_PRESENT
`)
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 5}, nil
			},
		},
	}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate)
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictBlock {
		t.Errorf("verdict=%q want block", res.Verdict)
	}
	if res.ExitReason != "security_halt" {
		t.Errorf("exit_reason=%q want security_halt", res.ExitReason)
	}
	if !res.HumanAction {
		t.Error("HumanAction=false want true")
	}
	if gate.Calls != 0 {
		t.Errorf("build gate called %d times, want 0", gate.Calls)
	}
	// PIPELINE_STATE.json should now contain the halt context.
	state, err := os.ReadFile(filepath.Join(dir, ".tekhton", "PIPELINE_STATE.json"))
	if err != nil {
		t.Fatalf("read PIPELINE_STATE.json: %v", err)
	}
	s := string(state)
	for _, want := range []string{`"exit_stage": "security"`, `"exit_reason": "security_halt"`, "--start-at security"} {
		if !strings.Contains(s, want) {
			t.Errorf("PIPELINE_STATE.json missing %q\n%s", want, s)
		}
	}
}

// fixture-07: HIGH unfixable + escalate policy → verdict=pass /
// HumanAction=true, HUMAN_ACTION_REQUIRED.md row with source=security.
func TestRunStage_UnfixableEscalate(t *testing.T) {
	dir, req := setupProject(t)
	writeCoderSummary(t, dir, `# Coder Summary
## Files Modified
- src/auth.go
`)
	t.Setenv("SECURITY_UNFIXABLE_POLICY", "escalate")
	haPath := filepath.Join(dir, ".tekhton", "HUMAN_ACTION_REQUIRED.md")
	t.Setenv("HUMAN_ACTION_FILE", haPath)

	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			func(*provider.Request) (*provider.Result, error) {
				writeReport(t, dir, `## Summary
Issue found.

## Findings
- [HIGH] [category:A07] [auth.go:10] fixable:no — Hardcoded secret requires infra rotation

## Verdict
FINDINGS_PRESENT
`)
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 5}, nil
			},
		},
	}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate)
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict=%q want pass", res.Verdict)
	}
	if !res.HumanAction {
		t.Error("HumanAction=false want true")
	}
	ha, err := os.ReadFile(haPath)
	if err != nil {
		t.Fatalf("read HUMAN_ACTION_REQUIRED.md: %v", err)
	}
	s := string(ha)
	if !strings.Contains(s, "security") {
		t.Errorf("HUMAN_ACTION_REQUIRED.md missing 'security' source row:\n%s", s)
	}
	if !strings.Contains(s, "Unfixable security findings require human review:") {
		t.Errorf("HUMAN_ACTION_REQUIRED.md missing escalate description prefix:\n%s", s)
	}
}

// TestRunStage_BuildGateFailureBreaksLoop verifies the post-rework build
// gate's break semantics (Watch For #5): a gate failure logs a warn and
// breaks the loop, but the stage returns verdict=pass with the cycle
// count reflected — not verdict=fail.
func TestRunStage_BuildGateFailureBreaksLoop(t *testing.T) {
	dir, req := setupProject(t)
	writeCoderSummary(t, dir, `# Coder Summary
## Files Modified
- src/auth.go
`)
	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			func(*provider.Request) (*provider.Result, error) {
				writeReport(t, dir, `## Findings
- [CRITICAL] [auth.go:42] fixable:yes — SQL injection

## Verdict
FINDINGS_PRESENT
`)
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 5}, nil
			},
			func(*provider.Request) (*provider.Result, error) {
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 5}, nil
			},
		},
	}
	gate := &fakeBuildGate{Err: errors.New("build broken")}
	restore := installSeams(t, ag, gate)
	defer restore()

	res, _ := RunStage(context.Background(), req)
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict=%q want pass (build-gate failure breaks loop, not stage)", res.Verdict)
	}
	if gate.Calls != 1 {
		t.Errorf("gate.Calls=%d want 1", gate.Calls)
	}
	if res.AgentCalls != 2 {
		t.Errorf("agent_calls=%d want 2 (scan + rework, no second scan)", res.AgentCalls)
	}
}

// TestClampTurns_MilestoneModeDoubles asserts the doubly-defaulting
// MILESTONE_SECURITY_MAX_TURNS branch (Watch For #6).
func TestClampTurns_MilestoneModeDoubles(t *testing.T) {
	cases := []struct {
		name string
		cfg  config
		want int
	}{
		{"base", config{MaxTurns: 15, MinTurns: 8, MaxTurnsCap: 30}, 15},
		{"milestone-no-override", config{MaxTurns: 15, MinTurns: 8, MaxTurnsCap: 30, MilestoneMode: true}, 30},
		{"milestone-with-override", config{MaxTurns: 15, MinTurns: 8, MaxTurnsCap: 30, MilestoneMode: true, MilestoneSecurityTurns: "20"}, 20},
		{"clamp-min", config{MaxTurns: 3, MinTurns: 8, MaxTurnsCap: 30}, 8},
		{"clamp-max", config{MaxTurns: 50, MinTurns: 8, MaxTurnsCap: 30}, 30},
		{"milestone-doubled-exceeds-cap", config{MaxTurns: 20, MinTurns: 8, MaxTurnsCap: 30, MilestoneMode: true}, 30},
		{"milestone-bad-override-falls-back", config{MaxTurns: 15, MinTurns: 8, MaxTurnsCap: 30, MilestoneMode: true, MilestoneSecurityTurns: "not-a-number"}, 30},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := clampTurns(tc.cfg)
			if got != tc.want {
				t.Errorf("clampTurns = %d, want %d", got, tc.want)
			}
		})
	}
}

// TestWriteNotesFile_GoldenLayout exercises every branch of WriteNotesFile:
// empty path no-op, notes-only, notes+waiver, notes+non-waiver (waiver
// section suppressed).
func TestWriteNotesFile_GoldenLayout(t *testing.T) {
	frozen := time.Date(2026, 3, 23, 14, 30, 5, 0, time.UTC)

	t.Run("empty-path-noop", func(t *testing.T) {
		if err := WriteNotesFile("", "anything", "anything", "waiver", frozen); err != nil {
			t.Errorf("empty path should be a no-op: %v", err)
		}
	})

	t.Run("notes-only", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "notes.md")
		if err := WriteNotesFile(p, "- [MEDIUM] something\n", "", "escalate", frozen); err != nil {
			t.Fatalf("write: %v", err)
		}
		got, _ := os.ReadFile(p)
		want := "# Security Notes\n\nGenerated: 2026-03-23 14:30:05\n\n## Non-Blocking Findings (MEDIUM/LOW)\n- [MEDIUM] something\n\n"
		if string(got) != want {
			t.Errorf("layout mismatch:\nwant:\n%s\ngot:\n%s", want, string(got))
		}
	})

	t.Run("notes-plus-waiver", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "notes.md")
		err := WriteNotesFile(p, "- [LOW] minor\n", "- [HIGH] waived\n", "waiver", frozen)
		if err != nil {
			t.Fatalf("write: %v", err)
		}
		got, _ := os.ReadFile(p)
		want := "# Security Notes\n\nGenerated: 2026-03-23 14:30:05\n\n## Non-Blocking Findings (MEDIUM/LOW)\n- [LOW] minor\n\n## Waivered Findings\n- [HIGH] waived\n\n"
		if string(got) != want {
			t.Errorf("layout mismatch:\nwant:\n%s\ngot:\n%s", want, string(got))
		}
	})

	t.Run("non-waiver-policy-suppresses-waiver-section", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "notes.md")
		if err := WriteNotesFile(p, "", "- [HIGH] unfixable\n", "escalate", frozen); err != nil {
			t.Fatalf("write: %v", err)
		}
		got, _ := os.ReadFile(p)
		if strings.Contains(string(got), "Waivered") {
			t.Errorf("escalate policy should suppress Waivered section:\n%s", string(got))
		}
	})
}

// TestFirstLine asserts the bash `${var%%$'\n'*}` parity.
func TestFirstLine(t *testing.T) {
	cases := []struct{ in, want string }{
		{"only-one-line", "only-one-line"},
		{"first\nsecond", "first"},
		{"\nempty-first", ""},
		{"", ""},
	}
	for _, tc := range cases {
		if got := firstLine(tc.in); got != tc.want {
			t.Errorf("firstLine(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// TestExportEnvBlocks asserts the env-export shape downstream stages
// consume. Mirrors stages/security.sh:149-164.
func TestExportEnvBlocks(t *testing.T) {
	// Reset to known state.
	_ = os.Unsetenv("SECURITY_FINDINGS_BLOCK")
	_ = os.Unsetenv("SECURITY_FIXES_BLOCK")
	_ = os.Unsetenv("SECURITY_REWORK_CYCLES_DONE")

	t.Run("no-findings-no-cycles", func(t *testing.T) {
		exportEnvBlocks(nil, 0, ".tekhton/SECURITY_REPORT.md")
		if v := os.Getenv("SECURITY_FINDINGS_BLOCK"); v != "" {
			t.Errorf("SECURITY_FINDINGS_BLOCK=%q want empty", v)
		}
		if v := os.Getenv("SECURITY_FIXES_BLOCK"); v != "" {
			t.Errorf("SECURITY_FIXES_BLOCK=%q want empty", v)
		}
		if v := os.Getenv("SECURITY_REWORK_CYCLES_DONE"); v != "0" {
			t.Errorf("SECURITY_REWORK_CYCLES_DONE=%q want 0", v)
		}
	})

	t.Run("with-findings-and-cycles", func(t *testing.T) {
		findings := []sec.Finding{{Severity: sec.SeverityHigh, Description: "hardcoded secret"}}
		exportEnvBlocks(findings, 2, ".tekhton/SECURITY_REPORT.md")
		fb := os.Getenv("SECURITY_FINDINGS_BLOCK")
		if !strings.HasPrefix(fb, "- [HIGH] hardcoded secret") {
			t.Errorf("SECURITY_FINDINGS_BLOCK=%q want row prefix", fb)
		}
		fx := os.Getenv("SECURITY_FIXES_BLOCK")
		if !strings.Contains(fx, "2 cycle") {
			t.Errorf("SECURITY_FIXES_BLOCK=%q want '2 cycle' substring", fx)
		}
		if v := os.Getenv("SECURITY_REWORK_CYCLES_DONE"); v != "2" {
			t.Errorf("SECURITY_REWORK_CYCLES_DONE=%q want 2", v)
		}
	})
}

// TestRunStage_NeverFailsAfterScanSucceeds asserts that downstream errors
// after the agent succeeds (notes-file write failure, escalation write
// failure) do not flip the verdict to fail — they log a warn and proceed,
// matching the bash `|| warn` semantics throughout the stage body.
func TestRunStage_LogsWarnButProceedsOnNotesWriteFail(t *testing.T) {
	dir, req := setupProject(t)
	writeCoderSummary(t, dir, `# Coder Summary
## Files Modified
- src/auth.go
`)
	// Point SECURITY_NOTES_FILE at an unwritable path.
	t.Setenv("SECURITY_NOTES_FILE", "/dev/full/cannot-write.md")

	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			func(*provider.Request) (*provider.Result, error) {
				writeReport(t, dir, `## Findings
- [LOW] [auth.go] fixable:unknown — Informational

## Verdict
FINDINGS_PRESENT
`)
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 3}, nil
			},
		},
	}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate)
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict=%q want pass (notes-write failure must not flip the stage)", res.Verdict)
	}
}

// keep time import in use even if no test below refers to it
var _ = time.Time{}
