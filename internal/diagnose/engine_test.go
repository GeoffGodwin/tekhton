package diagnose

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// --- Fixture enumeration AC -------------------------------------------------

// TestFixturesV3_HasFifteenScenarios enforces the m32.1 acceptance criterion
// that internal/diagnose/testdata/fixtures_v3/ contains exactly 15 scenario
// directories. A test that fires red on add/remove makes the baseline set
// load-bearing rather than aspirational.
func TestFixturesV3_HasFifteenScenarios(t *testing.T) {
	t.Parallel()
	entries, err := os.ReadDir("testdata/fixtures_v3")
	if err != nil {
		t.Fatalf("read fixtures_v3: %v", err)
	}
	var dirs []string
	for _, e := range entries {
		if e.IsDir() {
			dirs = append(dirs, e.Name())
		}
	}
	if len(dirs) != 15 {
		t.Fatalf("want exactly 15 scenarios, got %d: %v", len(dirs), dirs)
	}
	// Each scenario must have inputs/ + expected/ + README.md.
	for _, d := range dirs {
		base := filepath.Join("testdata", "fixtures_v3", d)
		for _, sub := range []string{"inputs", "expected", "README.md"} {
			p := filepath.Join(base, sub)
			if _, err := os.Stat(p); err != nil {
				t.Errorf("scenario %s missing %s: %v", d, sub, err)
			}
		}
	}
}

// --- Engine orchestration ---------------------------------------------------

// fakeRule is a Rule that always returns the supplied Diagnosis when
// match is true.
type fakeRule struct {
	name  string
	match bool
	out   Diagnosis
}

func (r *fakeRule) Name() string { return r.name }
func (r *fakeRule) Match(*Context) (Diagnosis, bool) {
	if !r.match {
		return Diagnosis{}, false
	}
	return r.out, true
}

type fakeProvider struct{ rules []Rule }

func (p *fakeProvider) Rules() []Rule { return p.rules }

func TestEngine_Run_SuccessShortCircuit(t *testing.T) {
	t.Parallel()
	called := false
	eng := NewEngine(&fakeProvider{rules: []Rule{
		&fakeRule{name: "_rule_x", match: true, out: Diagnosis{Classification: "X"}},
	}})
	// Wrap the provider so we observe whether it was queried.
	eng.Provider = &fakeProvider{rules: []Rule{
		&recordingRule{inner: &fakeRule{name: "_rule_x", match: true, out: Diagnosis{Classification: "X"}}, hit: &called},
	}}
	d := eng.Run(context.Background(), &Context{Outcome: "success"})
	if d.Classification != "SUCCESS" {
		t.Fatalf("want SUCCESS, got %q", d.Classification)
	}
	if called {
		t.Fatalf("success short-circuit must not invoke rules")
	}
}

func TestEngine_Run_FirstMatchWins(t *testing.T) {
	t.Parallel()
	var stderr bytes.Buffer
	eng := NewEngine(&fakeProvider{rules: []Rule{
		&fakeRule{name: "_rule_a", match: false},
		&fakeRule{name: "_rule_b", match: true, out: Diagnosis{Classification: "B", Confidence: ConfidenceHigh, Stage: "coder"}},
		&fakeRule{name: "_rule_c", match: true, out: Diagnosis{Classification: "C"}},
	}})
	eng.Logger = &stderr
	d := eng.Run(context.Background(), &Context{Outcome: "failure"})
	if d.Classification != "B" {
		t.Fatalf("first match wins; want B got %q", d.Classification)
	}
	want := "[diag] rule=_rule_b confidence=high classification=B stage=coder\n"
	if got := stderr.String(); got != want {
		t.Fatalf("emit line drifted:\nwant %q\n got %q", want, got)
	}
}

func TestEngine_Run_NoMatchFallsThroughToUnknown(t *testing.T) {
	t.Parallel()
	eng := NewEngine(&fakeProvider{rules: []Rule{
		&fakeRule{name: "_rule_a", match: false},
	}})
	d := eng.Run(context.Background(), &Context{Outcome: "failure"})
	if d.Classification != "UNKNOWN" {
		t.Fatalf("fall-through must produce UNKNOWN, got %q", d.Classification)
	}
}

func TestEngine_Run_NilContextSafe(t *testing.T) {
	t.Parallel()
	eng := NewEngine(&fakeProvider{rules: []Rule{}})
	d := eng.Run(context.Background(), nil)
	if d.Classification != "UNKNOWN" {
		t.Fatalf("nil ctx must produce UNKNOWN, got %q", d.Classification)
	}
}

// --- ReadContext ------------------------------------------------------------

func TestReadContext_NoStateReturnsNil(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PIPELINE_STATE_FILE", "")
	t.Setenv("CAUSAL_LOG_FILE", "")
	t.Setenv("MIGRATION_BACKUP_DIR", "")
	eng := NewEngine(nil)
	got, err := eng.ReadContext(context.Background(), &Input{ProjectDir: dir})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != nil {
		t.Fatalf("no-state must return nil Context, got %+v", got)
	}
}

func TestReadContext_FailureContextPopulatesClassification(t *testing.T) {
	dir := t.TempDir()
	mustMkdir(t, filepath.Join(dir, ".claude"))
	mustWrite(t, filepath.Join(dir, ".claude", "LAST_FAILURE_CONTEXT.json"), `{
  "schema_version": 2,
  "classification": "BUILD_FAILURE",
  "stage": "coder",
  "outcome": "failure",
  "primary_cause": {
    "category": "CODE",
    "subcategory": "compile",
    "signal": "ts2304",
    "source": "compile_phase"
  }
}`)
	eng := NewEngine(nil)
	t.Setenv("PIPELINE_STATE_FILE", "")
	t.Setenv("CAUSAL_LOG_FILE", "")
	t.Setenv("MIGRATION_BACKUP_DIR", "")
	c, err := eng.ReadContext(context.Background(), &Input{ProjectDir: dir})
	if err != nil || c == nil {
		t.Fatalf("ctx, err: %+v, %v", c, err)
	}
	if c.Classification != "BUILD_FAILURE" {
		t.Errorf("classification: want BUILD_FAILURE got %q", c.Classification)
	}
	if c.SchemaVersion != 2 {
		t.Errorf("schema_version: want 2 got %d", c.SchemaVersion)
	}
	if c.PrimaryCategory != "CODE" {
		t.Errorf("primary category: want CODE got %q", c.PrimaryCategory)
	}
	if c.PrimarySubcategory != "compile" {
		t.Errorf("primary subcategory: want compile got %q", c.PrimarySubcategory)
	}
	if c.PrimarySignal != "ts2304" {
		t.Errorf("primary signal: want ts2304 got %q", c.PrimarySignal)
	}
}

func TestReadContext_CausalLogPopulatesAggregates(t *testing.T) {
	dir := t.TempDir()
	mustMkdir(t, filepath.Join(dir, ".claude", "logs"))
	mustWrite(t, filepath.Join(dir, ".claude", "logs", "CAUSAL_LOG.jsonl"),
		`{"id":"e1","type":"stage_start","stage":"coder"}
{"id":"e2","type":"verdict","stage":"reviewer","verdict":"CHANGES_REQUIRED"}
{"id":"e3","type":"verdict","stage":"reviewer","verdict":"CHANGES_REQUIRED"}
{"id":"e4","type":"error","error":"compile_failed"}
`)
	eng := NewEngine(nil)
	eng.Helpers = DefaultHelpers()
	t.Setenv("PIPELINE_STATE_FILE", "")
	t.Setenv("CAUSAL_LOG_FILE", filepath.Join(dir, ".claude", "logs", "CAUSAL_LOG.jsonl"))
	t.Setenv("MIGRATION_BACKUP_DIR", "")
	c, err := eng.ReadContext(context.Background(), &Input{ProjectDir: dir})
	if err != nil || c == nil {
		t.Fatalf("ctx, err: %+v, %v", c, err)
	}
	if c.ReviewCycles != 2 {
		t.Errorf("review_cycles: want 2 got %d", c.ReviewCycles)
	}
	if !strings.Contains(c.ErrorEvents, "compile_failed") {
		t.Errorf("error_events missing compile_failed: %q", c.ErrorEvents)
	}
	if !strings.Contains(c.TerminalEvent, "compile_failed") {
		t.Errorf("terminal_event must be the last line: %q", c.TerminalEvent)
	}
}

// --- helpers ----------------------------------------------------------------

// Note: the m32.1 BashRuleAdapter integration test was deleted in m32.2.
// The 15-baseline parity test now lives in internal/diagnose/rules/rules_test.go,
// which drives the Go-native registry — no bash subprocess required.

type recordingRule struct {
	inner Rule
	hit   *bool
}

func (r *recordingRule) Name() string { return r.inner.Name() }
func (r *recordingRule) Match(c *Context) (Diagnosis, bool) {
	*r.hit = true
	return r.inner.Match(c)
}
