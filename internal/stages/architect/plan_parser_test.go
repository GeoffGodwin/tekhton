package architect

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParsePlan_BaselineFixture(t *testing.T) {
	t.Parallel()
	data, err := os.ReadFile(filepath.Join("testdata", "plan_baseline.md"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	p, err := parsePlan(strings.NewReader(string(data)))
	if err != nil {
		t.Fatalf("parsePlan: %v", err)
	}
	if !p.HasSimplification() {
		t.Errorf("HasSimplification: want true, got false")
	}
	if !p.HasJrWork() {
		t.Errorf("HasJrWork: want true, got false")
	}
	if got := len(p.OutOfScope()); got != 1 {
		t.Errorf("OutOfScope: want 1, got %d (%v)", got, p.OutOfScope())
	}
	dd := p.DesignDocObservations()
	if len(dd) != 2 {
		t.Errorf("DesignDocObservations: want 2 actionable, got %d (%v)", len(dd), dd)
	}
}

func TestParsePlan_NoActionFixture(t *testing.T) {
	t.Parallel()
	data, err := os.ReadFile(filepath.Join("testdata", "plan_no_action.md"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	p, err := parsePlan(strings.NewReader(string(data)))
	if err != nil {
		t.Fatalf("parsePlan: %v", err)
	}
	if p.HasSimplification() {
		t.Errorf("HasSimplification: want false, got true")
	}
	if p.HasJrWork() {
		t.Errorf("HasJrWork: want false, got true")
	}
	if got := len(p.OutOfScope()); got != 0 {
		t.Errorf("OutOfScope: want 0, got %d (%v)", got, p.OutOfScope())
	}
	if got := len(p.DesignDocObservations()); got != 0 {
		t.Errorf("DesignDocObservations: want 0, got %d (%v)", got, p.DesignDocObservations())
	}
}

func TestParsePlan_DesignDocOnlyFixture(t *testing.T) {
	t.Parallel()
	data, err := os.ReadFile(filepath.Join("testdata", "plan_design_doc_only.md"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	p, err := parsePlan(strings.NewReader(string(data)))
	if err != nil {
		t.Fatalf("parsePlan: %v", err)
	}
	if p.HasSimplification() {
		t.Errorf("HasSimplification: want false, got true")
	}
	if p.HasJrWork() {
		t.Errorf("HasJrWork: want false, got true")
	}
	dd := p.DesignDocObservations()
	if len(dd) != 2 {
		t.Fatalf("DesignDocObservations: want 2 actionable, got %d (%v)", len(dd), dd)
	}
}

func TestParsePlan_MultilineBullets(t *testing.T) {
	t.Parallel()
	src := `## Out of Scope
- first bullet
  continues on second line
  and a third
- second bullet
`
	p, err := parsePlan(strings.NewReader(src))
	if err != nil {
		t.Fatalf("parsePlan: %v", err)
	}
	got := p.OutOfScope()
	if len(got) != 2 {
		t.Fatalf("want 2 entries, got %d (%v)", len(got), got)
	}
	if !strings.Contains(got[0], "first bullet") || !strings.Contains(got[0], "second line") || !strings.Contains(got[0], "a third") {
		t.Errorf("multiline bullet not joined: %q", got[0])
	}
}

func TestHasActionableBullets_NoneIsNotActionable(t *testing.T) {
	t.Parallel()
	cases := []struct {
		body string
		want bool
	}{
		{"None", false},
		{"none", false},
		{"  None  ", false},
		{"- None", false},
		{"Refactor _foo()", true},
		{"None of the above is true", true},
	}
	for _, c := range cases {
		got := hasActionableBullets([]string{c.body})
		if got != c.want {
			t.Errorf("hasActionableBullets(%q): want %v, got %v", c.body, c.want, got)
		}
	}
}

func TestOOSFilter_Cases(t *testing.T) {
	t.Parallel()
	cases := []struct {
		input string
		kept  bool
	}{
		{"genuine OOS work", true},
		{"None", false},
		{"N/A", false},
		{"NA further investigation needed", false},
		{"No items left", false},
		{"No observations remaining", false},
		{"---", false},
		{"-----", false},
	}
	for _, c := range cases {
		out := filterEntries([]string{c.input}, oosFilters)
		gotKept := len(out) == 1
		if gotKept != c.kept {
			t.Errorf("OOS filter(%q): want kept=%v, got %v (out=%v)", c.input, c.kept, gotKept, out)
		}
	}
}

func TestDesignDocFilter_AllPatterns(t *testing.T) {
	t.Parallel()
	// Each entry triggers exactly one of the architect.sh:363-377 filter
	// regexes. The actionable case sits at the bottom and must survive.
	cases := []struct {
		input string
		kept  bool
	}{
		{"None of these caught fire", false},
		{"N/A — nothing to do here", false},
		{"No design observations from this audit", false},
		{"All observations are documented in CLAUDE.md", false},
		{"Nothing to flag", false},
		{"-----", false},
		{"(route to human review)", false},
		{"Updated HUMAN_ACTION_REQUIRED.md with the items", false},
		{"Items have been documented", false},
		{"Wrote new observations to the file", false},
		{"Implementation aligns with the design doc", false},
		{"See the GDD section on routing", false},
		// Survivors:
		{"DESIGN.md sec X says foo but code does bar — needs reconciliation", true},
		{"GDD specifies a contract that no longer holds — update needed", true},
	}
	for _, c := range cases {
		out := filterEntries([]string{c.input}, designDocFilters)
		gotKept := len(out) == 1
		if gotKept != c.kept {
			t.Errorf("DesignDoc filter(%q): want kept=%v, got %v (out=%v)", c.input, c.kept, gotKept, out)
		}
	}
}

func TestParsePlan_EmptyInput(t *testing.T) {
	t.Parallel()
	p, err := parsePlan(strings.NewReader(""))
	if err != nil {
		t.Fatalf("parsePlan: %v", err)
	}
	if p.HasSimplification() || p.HasJrWork() {
		t.Errorf("empty input must produce no work")
	}
}

func TestParsePlan_NilReader(t *testing.T) {
	t.Parallel()
	p, err := parsePlan(nil)
	if err != nil {
		t.Fatalf("parsePlan(nil): %v", err)
	}
	if p.HasSimplification() || p.HasJrWork() {
		t.Errorf("nil reader must produce no work")
	}
}
