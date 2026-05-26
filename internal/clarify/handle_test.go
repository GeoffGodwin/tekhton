package clarify

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func tempPath(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	return filepath.Join(dir, "CLARIFICATIONS.md")
}

func TestHandleInteractive_NoItems(t *testing.T) {
	out := &bytes.Buffer{}
	err := HandleInteractive(&Items{}, HandleOptions{
		Output:             out,
		ClarificationsPath: tempPath(t),
	})
	if err != nil {
		t.Errorf("no items should not error, got %v", err)
	}
}

func TestHandleInteractive_NonBlockingOnly(t *testing.T) {
	out := &bytes.Buffer{}
	items := &Items{
		NonBlocking: []Item{{Question: "[NON_BLOCKING] minor q", Blocking: false}},
	}
	err := HandleInteractive(items, HandleOptions{Output: out, ClarificationsPath: tempPath(t)})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "minor q") {
		t.Errorf("non-blocking should be logged: %q", out.String())
	}
}

func TestHandleInteractive_AnswersAndWritesFile(t *testing.T) {
	path := tempPath(t)
	input := strings.NewReader("my answer\n")
	items := &Items{
		Blocking: []Item{{Question: "[BLOCKING] which library?", Blocking: true}},
	}
	err := HandleInteractive(items, HandleOptions{
		Input:              input,
		Output:             &bytes.Buffer{},
		ClarificationsPath: path,
		Now:                func() time.Time { return time.Date(2026, 5, 26, 12, 0, 0, 0, time.UTC) },
	})
	if err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(path)
	s := string(body)
	if !strings.Contains(s, "## Q: [BLOCKING] which library?") {
		t.Errorf("question header missing:\n%s", s)
	}
	if !strings.Contains(s, "**A:** my answer") {
		t.Errorf("answer missing:\n%s", s)
	}
	if !strings.Contains(s, "# Clarifications — 2026-05-26 12:00:00") {
		t.Errorf("section header missing:\n%s", s)
	}
}

func TestHandleInteractive_Abort(t *testing.T) {
	input := strings.NewReader("abort\n")
	items := &Items{Blocking: []Item{{Question: "q", Blocking: true}}}
	err := HandleInteractive(items, HandleOptions{
		Input:              input,
		Output:             &bytes.Buffer{},
		ClarificationsPath: tempPath(t),
	})
	if !errors.Is(err, ErrAborted) {
		t.Errorf("expected ErrAborted, got %v", err)
	}
}

func TestHandleInteractive_Skip(t *testing.T) {
	path := tempPath(t)
	input := strings.NewReader("skip\nactual answer\n")
	items := &Items{Blocking: []Item{
		{Question: "first", Blocking: true},
		{Question: "second", Blocking: true},
	}}
	err := HandleInteractive(items, HandleOptions{
		Input:              input,
		Output:             &bytes.Buffer{},
		ClarificationsPath: path,
		Now:                func() time.Time { return time.Date(2026, 5, 26, 12, 0, 0, 0, time.UTC) },
	})
	if err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(path)
	s := string(body)
	if !strings.Contains(s, "**A:** (skipped by user)") {
		t.Errorf("skipped marker missing:\n%s", s)
	}
	if !strings.Contains(s, "**A:** actual answer") {
		t.Errorf("second answer missing:\n%s", s)
	}
}

func TestPollUntilAnswered_AllAnswered(t *testing.T) {
	path := tempPath(t)
	body := `## Q: q1
**A:** done
## Q: q2
**A:** done
`
	_ = os.WriteFile(path, []byte(body), 0o644)
	items := &Items{Blocking: []Item{
		{Question: "q1", Blocking: true},
		{Question: "q2", Blocking: true},
	}}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := PollUntilAnswered(ctx, items, path, 10*time.Millisecond); err != nil {
		t.Errorf("PollUntilAnswered: %v", err)
	}
}

func TestPollUntilAnswered_TimesOutWhenMissing(t *testing.T) {
	path := tempPath(t)
	items := &Items{Blocking: []Item{{Question: "q1", Blocking: true}}}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	err := PollUntilAnswered(ctx, items, path, 10*time.Millisecond)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("expected DeadlineExceeded, got %v", err)
	}
}

func TestClearStaleEntries_RemovesFullyAnswered(t *testing.T) {
	path := tempPath(t)
	body := `## Q: q
**A:** answered
`
	_ = os.WriteFile(path, []byte(body), 0o644)
	removed, err := ClearStaleEntries(path)
	if err != nil {
		t.Fatal(err)
	}
	if !removed {
		t.Error("should remove fully-answered file")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("file should be gone")
	}
}

func TestClearStaleEntries_KeepsPartiallyAnswered(t *testing.T) {
	path := tempPath(t)
	body := `## Q: q1
**A:** answered
## Q: q2
**A:**
`
	_ = os.WriteFile(path, []byte(body), 0o644)
	removed, err := ClearStaleEntries(path)
	if err != nil {
		t.Fatal(err)
	}
	if removed {
		t.Error("partial answers should NOT be cleared")
	}
}

func TestClearStaleEntries_NoFile(t *testing.T) {
	removed, err := ClearStaleEntries("/nonexistent")
	if err != nil {
		t.Fatal(err)
	}
	if removed {
		t.Error("missing file should not report removed")
	}
}
