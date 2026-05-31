package diagnose

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCollapseCauseChain_Table(t *testing.T) {
	t.Parallel()
	h := DefaultHelpers()
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"empty", "", ""},
		{"single id no type", "evt001", "event"},
		{"single id.type", "evt001.error", "error"},
		{"two distinct types", "evt001.start <- evt002.error", "start -> error"},
		{"consecutive same type collapses", "a.error <- b.error <- c.error", "3x error"},
		{
			"mixed collapse + distinct",
			"a.start <- b.error <- c.error <- d.error <- e.build_fix",
			"start -> 3x error -> build_fix",
		},
		{
			"truncates to max links with total annotation",
			"a.x1 <- b.x2 <- c.x3 <- d.x4 <- e.x5 <- f.x6",
			"x1 -> x2 -> x3 -> x4 -> x5 -> ... (6 total)",
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := h.CollapseCauseChain(tc.in)
			if got != tc.want {
				t.Errorf("input %q: want %q got %q", tc.in, tc.want, got)
			}
		})
	}
}

func TestCollapseCauseChain_NonDefaultMax(t *testing.T) {
	t.Parallel()
	h := &Helpers{MaxChainLinks: 2, RecurringThreshold: 3}
	in := "a.x1 <- b.x2 <- c.x3"
	got := h.CollapseCauseChain(in)
	want := "x1 -> x2 -> ... (3 total)"
	if got != want {
		t.Fatalf("want %q got %q", want, got)
	}
}

func TestCollapseCauseChain_ZeroMaxFallsBackToFive(t *testing.T) {
	t.Parallel()
	h := &Helpers{MaxChainLinks: 0, RecurringThreshold: 0}
	in := "a.x1 <- b.x2 <- c.x3"
	got := h.CollapseCauseChain(in)
	// All three fit; no truncation.
	if got != "x1 -> x2 -> x3" {
		t.Fatalf("want full chain, got %q", got)
	}
}

func TestDetectRecurring_NoFileReturnsEmpty(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	c := &Context{ProjectDir: dir}
	h := DefaultHelpers()
	got := h.DetectRecurring(c, "BUILD_FAILURE")
	if got.Count != 0 || got.Note != "" {
		t.Fatalf("expected empty RecurringInfo, got %+v", got)
	}
}

func TestDetectRecurring_DifferentClassification(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	mustMkdir(t, filepath.Join(dir, ".claude"))
	mustWrite(t, filepath.Join(dir, ".claude", "LAST_FAILURE_CONTEXT.json"),
		`{"classification":"MAX_TURNS_EXHAUSTED","consecutive_count":4}`)
	h := DefaultHelpers()
	got := h.DetectRecurring(&Context{ProjectDir: dir}, "BUILD_FAILURE")
	if got.Count != 0 {
		t.Fatalf("classification mismatch should yield Count=0, got %d", got.Count)
	}
}

func TestDetectRecurring_SameClassificationIncrements(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	mustMkdir(t, filepath.Join(dir, ".claude"))
	mustWrite(t, filepath.Join(dir, ".claude", "LAST_FAILURE_CONTEXT.json"),
		`{"classification":"BUILD_FAILURE","consecutive_count":2}`)
	h := DefaultHelpers()
	got := h.DetectRecurring(&Context{ProjectDir: dir}, "BUILD_FAILURE")
	if got.Count != 3 {
		t.Errorf("expected Count=3 (2+1), got %d", got.Count)
	}
	if !strings.Contains(got.Note, "3th consecutive BUILD_FAILURE") {
		t.Errorf("note missing escalation text: %q", got.Note)
	}
}

func TestDetectRecurring_BelowThresholdLeavesNoteEmpty(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	mustMkdir(t, filepath.Join(dir, ".claude"))
	mustWrite(t, filepath.Join(dir, ".claude", "LAST_FAILURE_CONTEXT.json"),
		`{"classification":"BUILD_FAILURE","consecutive_count":1}`)
	h := DefaultHelpers()
	got := h.DetectRecurring(&Context{ProjectDir: dir}, "BUILD_FAILURE")
	if got.Count != 2 {
		t.Errorf("expected Count=2, got %d", got.Count)
	}
	if got.Note != "" {
		t.Errorf("note should be empty below threshold, got %q", got.Note)
	}
}

func TestDetectRecurring_EmptyClassificationReturnsEmpty(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	h := DefaultHelpers()
	got := h.DetectRecurring(&Context{ProjectDir: dir}, "")
	if got.Count != 0 || got.Note != "" {
		t.Fatalf("empty classification should short-circuit, got %+v", got)
	}
}

func TestCollectAgentLogTails_EmptyWhenLogDirMissing(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	h := DefaultHelpers()
	got := h.CollectAgentLogTails(&Context{ProjectDir: dir})
	if len(got) != 0 {
		t.Fatalf("expected empty map, got %+v", got)
	}
}

func TestCollectAgentLogTails_ReadsLastTwentyLines(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	logDir := filepath.Join(dir, ".claude", "logs")
	mustMkdir(t, logDir)
	var b strings.Builder
	for i := 1; i <= 25; i++ {
		b.WriteString("line ")
		b.WriteString(itoa(i))
		b.WriteString("\n")
	}
	mustWrite(t, filepath.Join(logDir, "coder.log"), b.String())
	h := DefaultHelpers()
	got := h.CollectAgentLogTails(&Context{ProjectDir: dir})
	tail, ok := got["coder.log"]
	if !ok {
		t.Fatalf("missing entry for coder.log: %+v", got)
	}
	lines := strings.Split(tail, "\n")
	if len(lines) != 20 {
		t.Fatalf("expected 20 lines, got %d", len(lines))
	}
	if lines[0] != "line 6" {
		t.Errorf("first kept line should be line 6, got %q", lines[0])
	}
	if lines[19] != "line 25" {
		t.Errorf("last kept line should be line 25, got %q", lines[19])
	}
}

func TestCollectAgentLogTails_CapsAtFiveFiles(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	logDir := filepath.Join(dir, ".claude", "logs")
	mustMkdir(t, logDir)
	for _, name := range []string{"a.log", "b.log", "c.log", "d.log", "e.log", "f.log", "g.log"} {
		mustWrite(t, filepath.Join(logDir, name), "hello\n")
	}
	// Add a non-log file that should be ignored.
	mustWrite(t, filepath.Join(logDir, "ignore.txt"), "not a log\n")
	h := DefaultHelpers()
	got := h.CollectAgentLogTails(&Context{ProjectDir: dir})
	if len(got) != 5 {
		t.Fatalf("expected cap at 5, got %d entries: %+v", len(got), got)
	}
}

// ---- helpers ----

func mustMkdir(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(p, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", p, err)
	}
}

func mustWrite(t *testing.T, p, body string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", p, err)
	}
}

// itoa avoids importing strconv at the top of helpers_test.go.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var digits []byte
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}
