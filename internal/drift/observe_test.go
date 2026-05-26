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

// TestLog_ResetRunsSinceAudit_MissingFile verifies the early-return
// path: when the drift log does not exist, ResetRunsSinceAudit is a
// no-op (does not create the file and returns nil).
func TestLog_ResetRunsSinceAudit_MissingFile(t *testing.T) {
	l := tempLog(t)
	// File not created — do NOT call EnsureLog.
	if err := l.ResetRunsSinceAudit(); err != nil {
		t.Fatalf("ResetRunsSinceAudit on missing file: %v", err)
	}
	if _, err := os.Stat(l.Path); !os.IsNotExist(err) {
		t.Error("ResetRunsSinceAudit should not create the log file")
	}
}

// TestLog_ClearResolved_EmptyResolvedSection verifies the no-op early
// return when the Resolved section contains no bullet entries.
func TestLog_ClearResolved_EmptyResolvedSection(t *testing.T) {
	l := tempLog(t)
	if err := l.EnsureLog(); err != nil {
		t.Fatal(err)
	}
	// No observations added — Resolved is empty.
	n, err := l.ClearResolved()
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("ClearResolved on empty section = %d, want 0", n)
	}
}

// TestLog_GetResolved_MissingFile verifies the nil, nil early return
// when the drift log does not exist.
func TestLog_GetResolved_MissingFile(t *testing.T) {
	l := tempLog(t)
	got, err := l.GetResolved()
	if err != nil {
		t.Fatalf("GetResolved on missing file: %v", err)
	}
	if got != nil {
		t.Errorf("GetResolved missing file = %v, want nil", got)
	}
}

// TestLog_AppendEntries exercises the architect-audit path that appends
// entries verbatim (bypassing the reviewer bullet-parser). AppendEntries
// was at 0% coverage.
func TestLog_AppendEntries(t *testing.T) {
	l := tempLog(t)
	entries := []string{
		"design doc section 3 needs updating",
		"remove stale platform flag",
	}
	if err := l.AppendEntries(entries); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(l.Path)
	if err != nil {
		t.Fatal(err)
	}
	s := string(body)
	if !strings.Contains(s, "design doc section 3 needs updating") {
		t.Errorf("first entry missing:\n%s", s)
	}
	if !strings.Contains(s, "remove stale platform flag") {
		t.Errorf("second entry missing:\n%s", s)
	}
	// Entries should be tagged with the fixed "architect audit" label.
	if !strings.Contains(s, `"architect audit"`) {
		t.Errorf(`"architect audit" label missing:\n%s`, s)
	}
	// Both entries must appear in the Unresolved section.
	n, err := l.CountUnresolved()
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Errorf("unresolved count = %d, want 2", n)
	}
}

// TestLog_AppendEntries_Empty verifies that AppendEntries with an empty
// slice is a no-op that does not create the log file.
func TestLog_AppendEntries_Empty(t *testing.T) {
	l := tempLog(t)
	if err := l.AppendEntries(nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(l.Path); !os.IsNotExist(err) {
		t.Error("empty AppendEntries should not create the log file")
	}
}

// TestLog_ShouldTriggerAudit_ViaRunsThreshold covers the second branch
// of ShouldTriggerAudit: the runs-since-audit counter reaching the
// threshold without the observation count doing so.
func TestLog_ShouldTriggerAudit_ViaRunsThreshold(t *testing.T) {
	l := tempLog(t)
	if err := l.EnsureLog(); err != nil {
		t.Fatal(err)
	}
	// One observation well below the obs threshold (8).
	_ = l.AppendObservations("t", "- one obs")
	// Increment runs until we hit the threshold (5).
	for i := 0; i < 5; i++ {
		_ = l.IncrementRunsSinceAudit()
	}
	tr, err := l.ShouldTriggerAudit(8, 5)
	if err != nil {
		t.Fatal(err)
	}
	if !tr {
		t.Error("should trigger when runs-since-audit reaches threshold")
	}
}

// TestLog_ResolveObservations_NoDuplicates verifies that resolving an
// observation twice does not create duplicate entries in the Resolved
// section (dedup behavior).
func TestLog_ResolveObservations_NoDuplicates(t *testing.T) {
	l := tempLog(t)
	_ = l.AppendObservations("t", "- alpha drift concern")
	// First resolve: should move to Resolved.
	if err := l.ResolveObservations([]string{"alpha"}); err != nil {
		t.Fatal(err)
	}
	// Second resolve of same content: already resolved, should dedup.
	// Re-append the same text so there is something in Unresolved again.
	_ = l.AppendObservations("t", "- alpha drift concern")
	if err := l.ResolveObservations([]string{"alpha"}); err != nil {
		t.Fatal(err)
	}
	got, err := l.GetResolved()
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, line := range got {
		if strings.Contains(line, "alpha drift concern") {
			count++
		}
	}
	if count != 1 {
		t.Errorf("Resolved contains %d copies of 'alpha drift concern', want exactly 1 (dedup)", count)
	}
}
