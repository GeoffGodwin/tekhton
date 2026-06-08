package coder

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestReconstructSummary_StatusTable asserts the 3-status table acceptance
// criterion: COMPLETE / FAILED / INCOMPLETE all produce a "## Status: <X>"
// line; anything else is rejected.
func TestReconstructSummary_StatusTable(t *testing.T) {
	cases := []struct {
		status   string
		want     string
		wantErr  bool
	}{
		{"COMPLETE", "## Status: COMPLETE", false},
		{"FAILED", "## Status: FAILED", false},
		{"INCOMPLETE", "## Status: INCOMPLETE", false},
		{"", "## Status: COMPLETE", false}, // default
		{"WEIRD", "", true},
	}
	for _, c := range cases {
		t.Run(c.status, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "summary.md")
			err := ReconstructSummary(context.Background(), path, c.status, &Deps{
				GitTrackedNameOnly: func() (string, error) { return "main.go\n", nil },
				GitDiffStat:        func() (string, error) { return "main.go | 5 ++--\n", nil },
				GitUntrackedFiles:  func() (string, error) { return "new.go\n", nil },
			})
			if c.wantErr {
				if err == nil {
					t.Fatalf("expected error for status %q", c.status)
				}
				return
			}
			if err != nil {
				t.Fatalf("ReconstructSummary err = %v", err)
			}
			b, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read summary: %v", err)
			}
			body := string(b)
			if !strings.Contains(body, c.want) {
				t.Errorf("summary missing %q; got:\n%s", c.want, body)
			}
			if !strings.Contains(body, "## Files Modified") {
				t.Errorf("summary missing ## Files Modified section")
			}
			if !strings.Contains(body, "## New Files Created") {
				t.Errorf("summary missing ## New Files Created section")
			}
			if !strings.Contains(body, "## Git Diff Summary") {
				t.Errorf("summary missing ## Git Diff Summary section")
			}
		})
	}
}

// TestReconstructSummary_ExcludesLogs asserts the load-bearing exclusions
// from stages/coder.sh:63-66: .claude/logs/ and the session-dir basename
// are filtered out of the untracked list.
func TestReconstructSummary_ExcludesLogs(t *testing.T) {
	t.Setenv("TEKHTON_SESSION_DIR", "/tmp/sess_abc")
	dir := t.TempDir()
	path := filepath.Join(dir, "summary.md")
	err := ReconstructSummary(context.Background(), path, "COMPLETE", &Deps{
		GitTrackedNameOnly: func() (string, error) { return "main.go\n", nil },
		GitDiffStat:        func() (string, error) { return "stat", nil },
		GitUntrackedFiles: func() (string, error) {
			return ".claude/logs/run-1.log\nsess_abc/foo.json\nlegit.go\n", nil
		},
	})
	if err != nil {
		t.Fatalf("ReconstructSummary err = %v", err)
	}
	b, _ := os.ReadFile(path)
	body := string(b)
	if strings.Contains(body, ".claude/logs/") {
		t.Errorf(".claude/logs/ entry leaked into summary")
	}
	if strings.Contains(body, "sess_abc/foo.json") {
		t.Errorf("session-dir entry leaked into summary")
	}
	if !strings.Contains(body, "legit.go") {
		t.Errorf("legitimate new file missing from summary")
	}
}

// TestFilterUntracked covers the helper directly so a future refactor that
// moves the regex around doesn't silently drop the exclusions.
func TestFilterUntracked(t *testing.T) {
	cases := []struct {
		name, in, session, want string
	}{
		{"empty", "", "x", ""},
		{"logs-stripped", ".claude/logs/a.log\nmain.go", "x", "main.go"},
		{"session-stripped", "sess/x.json\nmain.go", "sess", "main.go"},
		{"nosession-noop", "a/b.go", "__nosession__", "a/b.go"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := filterUntracked(c.in, c.session)
			if got != c.want {
				t.Errorf("filterUntracked(%q, %q) = %q; want %q",
					c.in, c.session, got, c.want)
			}
		})
	}
}

// TestTopNLines exercises the head -N helper.
func TestTopNLines(t *testing.T) {
	got := topNLines("a\nb\nc\nd\n", 2)
	if got != "a\nb" {
		t.Errorf("topNLines = %q; want a\\nb", got)
	}
	if topNLines("", 5) != "" {
		t.Errorf("topNLines empty != \"\"")
	}
	if topNLines("a", 0) != "" {
		t.Errorf("topNLines n=0 != \"\"")
	}
}
