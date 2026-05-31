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

// --- 15-baseline integration through BashRuleAdapter ------------------------

// TestBashAdapterIntegration_MaxTurnsCoder is the m32.1 acceptance test:
// load the captured max-turns-coder fixture, drive ReadContext + Run through
// the production BashRuleAdapter (which exec's the bash rule registry), and
// assert the verdict matches the v3 baseline.
//
// Skips when bash is unavailable, TEKHTON_HOME is unset, or the bash rule
// libraries are missing — the test is meant to fire on dev / CI hosts that
// have a checkout, not block contributors on minimal images.
func TestBashAdapterIntegration_MaxTurnsCoder(t *testing.T) {
	home := findTekhtonHome(t)
	if home == "" {
		t.Skip("TEKHTON_HOME not resolvable; skipping bash integration")
	}
	if _, err := os.Stat(filepath.Join(home, "lib", "diagnose_rules.sh")); err != nil {
		t.Skipf("bash diagnose libraries unavailable at %s: %v", home, err)
	}

	fx := filepath.Join("testdata", "fixtures_v3", "max-turns-coder")
	projectDir := materializeFixture(t, fx)

	adapter := &BashRuleAdapter{TekhtonHome: home}
	eng := NewEngine(adapter)
	var stderr bytes.Buffer
	eng.Logger = &stderr

	c, err := eng.ReadContext(context.Background(), &Input{ProjectDir: projectDir, TekhtonHome: home})
	if err != nil {
		t.Fatalf("ReadContext: %v", err)
	}
	if c == nil {
		t.Fatal("ReadContext returned nil; fixture inputs missing")
	}
	d := eng.Run(context.Background(), c)
	want := readExpected(t, fx, "verdict.txt")
	gotClass := want["classification"]
	if d.Classification != gotClass {
		t.Fatalf("classification: baseline=%q got=%q", gotClass, d.Classification)
	}
	if string(d.Confidence) != want["confidence"] {
		t.Errorf("confidence: baseline=%q got=%q", want["confidence"], string(d.Confidence))
	}
}

// --- helpers ----------------------------------------------------------------

type recordingRule struct {
	inner Rule
	hit   *bool
}

func (r *recordingRule) Name() string { return r.inner.Name() }
func (r *recordingRule) Match(c *Context) (Diagnosis, bool) {
	*r.hit = true
	return r.inner.Match(c)
}

// materializeFixture copies the fixture's `inputs/` tree into a per-test
// temp dir so the adapter sees a realistic ${PROJECT_DIR} layout.
func materializeFixture(t *testing.T, fixtureDir string) string {
	t.Helper()
	dst := t.TempDir()
	src := filepath.Join(fixtureDir, "inputs")
	// Mirror the bash conventions: PIPELINE_STATE.md and BUILD_ERRORS.md
	// live in .tekhton or .claude depending on the file.
	err := filepath.Walk(src, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, _ := filepath.Rel(src, path)
		if rel == "." {
			return nil
		}
		target := filepath.Join(dst, mapFixturePath(rel))
		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		return os.WriteFile(target, body, 0o644)
	})
	if err != nil {
		t.Fatalf("materialize: %v", err)
	}
	return dst
}

// mapFixturePath translates a fixture-relative input filename to its
// PROJECT_DIR-relative target so the engine's ReadContext finds it.
func mapFixturePath(rel string) string {
	switch {
	case rel == "PIPELINE_STATE.md":
		return filepath.Join(".claude", "PIPELINE_STATE.md")
	case rel == "RUN_SUMMARY.json":
		return filepath.Join(".claude", "logs", "RUN_SUMMARY.json")
	case rel == "CAUSAL_LOG.jsonl":
		return filepath.Join(".claude", "logs", "CAUSAL_LOG.jsonl")
	case rel == "LAST_FAILURE_CONTEXT.json":
		return filepath.Join(".claude", "LAST_FAILURE_CONTEXT.json")
	case rel == "BUILD_ERRORS.md":
		return filepath.Join(".tekhton", "BUILD_ERRORS.md")
	case rel == "BUILD_FIX_REPORT.md":
		return filepath.Join(".tekhton", "BUILD_FIX_REPORT.md")
	case rel == "REVIEWER_REPORT.md":
		return filepath.Join(".tekhton", "REVIEWER_REPORT.md")
	case rel == "SECURITY_REPORT.md":
		return filepath.Join(".tekhton", "SECURITY_REPORT.md")
	case rel == "CLARIFICATIONS.md":
		return filepath.Join(".tekhton", "CLARIFICATIONS.md")
	case strings.HasPrefix(rel, ".claude/"):
		return rel
	case strings.HasPrefix(rel, "agent_logs/"):
		name := strings.TrimPrefix(rel, "agent_logs/")
		return filepath.Join(".claude", "logs", name)
	}
	return rel
}

func readExpected(t *testing.T, fixtureDir, file string) map[string]string {
	t.Helper()
	body, err := os.ReadFile(filepath.Join(fixtureDir, "expected", file))
	if err != nil {
		t.Fatalf("read expected/%s: %v", file, err)
	}
	out := map[string]string{}
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		out[k] = v
	}
	return out
}

// findTekhtonHome locates the repository root for the bash-adapter test.
// Returns "" when running outside a checkout (e.g. cross-platform CI on a
// fresh image) so callers can t.Skip.
func findTekhtonHome(t *testing.T) string {
	t.Helper()
	if env := os.Getenv("TEKHTON_HOME"); env != "" {
		return env
	}
	// Walk up from cwd looking for tekhton.sh.
	cwd, err := os.Getwd()
	if err != nil {
		return ""
	}
	for cur := cwd; cur != "/" && cur != "."; cur = filepath.Dir(cur) {
		if _, err := os.Stat(filepath.Join(cur, "tekhton.sh")); err == nil {
			return cur
		}
	}
	return ""
}
