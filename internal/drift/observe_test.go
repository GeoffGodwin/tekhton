package drift

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func tempLog(t *testing.T) *Log {
	t.Helper()
	dir := t.TempDir()
	l := NewLog(filepath.Join(dir, "DRIFT_LOG.md"))
	l.Now = func() time.Time { return time.Date(2026, 5, 26, 12, 0, 0, 0, time.UTC) }
	return l
}

func TestLog_EnsureLog_Idempotent(t *testing.T) {
	l := tempLog(t)
	if err := l.EnsureLog(); err != nil {
		t.Fatal(err)
	}
	first, _ := os.ReadFile(l.Path)
	if err := l.EnsureLog(); err != nil {
		t.Fatal(err)
	}
	second, _ := os.ReadFile(l.Path)
	if string(first) != string(second) {
		t.Error("EnsureLog should be idempotent")
	}
	if !strings.Contains(string(first), "## Unresolved Observations") {
		t.Error("preamble missing Unresolved Observations heading")
	}
}

func TestLog_AppendObservations(t *testing.T) {
	l := tempLog(t)
	raw := `- first observation
- second observation
  with a continuation
- None`
	if err := l.AppendObservations("test task", raw); err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(l.Path)
	s := string(body)
	if !strings.Contains(s, "first observation") {
		t.Error("first observation missing")
	}
	if !strings.Contains(s, "second observation with a continuation") {
		t.Errorf("continuation not joined:\n%s", s)
	}
	// "None" must NOT be appended.
	if strings.Contains(s, `"test task"] None`) {
		t.Errorf("None token leaked into log:\n%s", s)
	}
	if !strings.Contains(s, `[2026-05-26 | "test task"]`) {
		t.Errorf("date+task tag missing:\n%s", s)
	}
}

func TestLog_AppendObservations_EmptyInput(t *testing.T) {
	l := tempLog(t)
	// No EnsureLog yet — must not be created when there are zero entries.
	if err := l.AppendObservations("task", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(l.Path); !os.IsNotExist(err) {
		t.Error("empty input should not create the file")
	}
}

func TestLog_CountUnresolved(t *testing.T) {
	l := tempLog(t)
	_ = l.AppendObservations("t", "- a\n- b\n- c")
	n, err := l.CountUnresolved()
	if err != nil {
		t.Fatal(err)
	}
	if n != 3 {
		t.Errorf("count = %d, want 3", n)
	}
}

func TestLog_ResolveObservations(t *testing.T) {
	l := tempLog(t)
	_ = l.AppendObservations("t", "- alpha drift\n- beta concern\n- gamma issue")
	// Resolve any entry mentioning "beta".
	if err := l.ResolveObservations([]string{"beta"}); err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(l.Path)
	s := string(body)
	// beta should have moved to Resolved section.
	resolvedIdx := strings.Index(s, "## Resolved")
	if resolvedIdx == -1 {
		t.Fatal("Resolved section missing")
	}
	if !strings.Contains(s[resolvedIdx:], "beta concern") {
		t.Errorf("beta not in Resolved:\n%s", s)
	}
	if strings.Contains(s[:resolvedIdx], "beta concern") {
		t.Errorf("beta still in Unresolved:\n%s", s)
	}
}

func TestLog_ResolveAllObservations(t *testing.T) {
	l := tempLog(t)
	_ = l.AppendObservations("t", "- alpha\n- beta\n- gamma")
	if err := l.ResolveAllObservations(); err != nil {
		t.Fatal(err)
	}
	n, _ := l.CountUnresolved()
	if n != 0 {
		t.Errorf("unresolved after resolve-all = %d, want 0", n)
	}
}

func TestLog_RunsSinceAudit(t *testing.T) {
	l := tempLog(t)
	if err := l.EnsureLog(); err != nil {
		t.Fatal(err)
	}
	got, _ := l.GetRunsSinceAudit()
	if got != 0 {
		t.Errorf("initial = %d, want 0", got)
	}
	_ = l.IncrementRunsSinceAudit()
	_ = l.IncrementRunsSinceAudit()
	got, _ = l.GetRunsSinceAudit()
	if got != 2 {
		t.Errorf("after 2 increments = %d, want 2", got)
	}
	_ = l.ResetRunsSinceAudit()
	got, _ = l.GetRunsSinceAudit()
	if got != 0 {
		t.Errorf("after reset = %d, want 0", got)
	}
	// Confirm last audit got stamped.
	body, _ := os.ReadFile(l.Path)
	if !strings.Contains(string(body), "Last audit: 2026-05-26") {
		t.Errorf("last audit date not stamped:\n%s", body)
	}
}

func TestLog_ShouldTriggerAudit(t *testing.T) {
	l := tempLog(t)
	if err := l.EnsureLog(); err != nil {
		t.Fatal(err)
	}
	// No observations, no runs — false.
	tr, _ := l.ShouldTriggerAudit(8, 5)
	if tr {
		t.Error("should not trigger with no signal")
	}
	// Add 8 observations — should trigger on obs threshold.
	for i := 0; i < 8; i++ {
		_ = l.AppendObservations("t", "- obs")
	}
	tr, _ = l.ShouldTriggerAudit(8, 5)
	if !tr {
		t.Error("should trigger at obs threshold")
	}
}

func TestLog_ClearResolved(t *testing.T) {
	l := tempLog(t)
	_ = l.AppendObservations("t", "- alpha\n- beta")
	_ = l.ResolveAllObservations()
	n, err := l.ClearResolved()
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Errorf("cleared = %d, want 2", n)
	}
	got, _ := l.GetResolved()
	if len(got) != 0 {
		t.Errorf("Resolved still has %d entries", len(got))
	}
}

func TestLog_GetResolved(t *testing.T) {
	l := tempLog(t)
	_ = l.AppendObservations("t", "- alpha")
	_ = l.ResolveObservations([]string{"alpha"})
	got, err := l.GetResolved()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("Resolved entries = %d, want 1", len(got))
	}
	if !strings.Contains(got[0], "alpha") {
		t.Errorf("Resolved entry = %q, want alpha", got[0])
	}
}

func TestParseBulletList_JoinsContinuations(t *testing.T) {
	in := `- alpha
- beta
  continuation
  more text
- gamma`
	got := parseBulletList(in)
	if len(got) != 3 {
		t.Fatalf("entries = %d, want 3", len(got))
	}
	if got[1] != "beta continuation more text" {
		t.Errorf("entries[1] = %q, want %q", got[1], "beta continuation more text")
	}
}

func TestParseBulletList_DropsNoneAndDashes(t *testing.T) {
	in := `- None
- ---
- real`
	got := parseBulletList(in)
	if len(got) != 1 || got[0] != "real" {
		t.Errorf("entries = %v, want [real]", got)
	}
}
