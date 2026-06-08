package buildfix

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// withFrozenClock swaps nowFn for the duration of the test. The bash
// helpers stamp `date '+%Y-%m-%d %H:%M:%S'` inline; tests inject a fixed
// timestamp so byte-identical fixture diffs work.
func withFrozenClock(t *testing.T, ts time.Time) {
	t.Helper()
	prev := nowFn
	nowFn = func() time.Time { return ts }
	t.Cleanup(func() { nowFn = prev })
}

// normalizeTimestamp replaces a `YYYY-MM-DD HH:MM:SS` timestamp with
// `<TIMESTAMP>` so fixture baselines can be checked into git without
// being date-sensitive.
func normalizeTimestamp(s string) string {
	re := regexp.MustCompile(`\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}`)
	return re.ReplaceAllString(s, "<TIMESTAMP>")
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	neg := false
	if n < 0 {
		neg = true
		n = -n
	}
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	if neg {
		b = append([]byte{'-'}, b...)
	}
	return string(b)
}

// TestCountErrors_Basic verifies wc -l parity (newline counting).
func TestCountErrors_Basic(t *testing.T) {
	dir := t.TempDir()
	cases := []struct {
		name    string
		content string
		want    int
	}{
		{"empty file", "", 0},
		{"three lines with trailing newline", "a\nb\nc\n", 3},
		{"two lines no trailing newline (wc -l counts \\n)", "a\nb", 1},
		{"single line with newline", "x\n", 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path := filepath.Join(dir, "errs-"+c.name+".txt")
			if err := os.WriteFile(path, []byte(c.content), 0o644); err != nil {
				t.Fatalf("setup: %v", err)
			}
			got, err := CountErrors(path)
			if err != nil {
				t.Fatalf("CountErrors: %v", err)
			}
			if got != c.want {
				t.Fatalf("CountErrors(%q) = %d, want %d", c.content, got, c.want)
			}
		})
	}
}

// TestCountErrors_MissingFile pins the bash "0 on missing file"
// semantic — no error returned, value is zero.
func TestCountErrors_MissingFile(t *testing.T) {
	got, err := CountErrors(filepath.Join(t.TempDir(), "does-not-exist.txt"))
	if err != nil {
		t.Fatalf("CountErrors on missing file returned err=%v, want nil", err)
	}
	if got != 0 {
		t.Fatalf("CountErrors on missing file = %d, want 0", got)
	}
}

// TestErrorTail_ExactWindow covers the milestone acceptance criterion:
// "returns the last 20 non-blank lines exactly (not 19 or 21)" — verified
// by a fixture with 30 lines (5 blank, 25 non-blank) asserting 20 lines
// returned.
func TestErrorTail_ExactWindow(t *testing.T) {
	var lines []string
	// 25 non-blank lines numbered 1..25, with 5 blank lines interspersed
	// (every 6th line is whitespace-only).
	idx := 1
	for i := 0; i < 30; i++ {
		if i%6 == 5 {
			lines = append(lines, "   ") // whitespace-only line (treated as blank)
			continue
		}
		lines = append(lines, "line "+itoa(idx))
		idx++
	}
	if idx-1 != 25 {
		t.Fatalf("fixture broken: expected 25 non-blank lines, got %d", idx-1)
	}

	path := filepath.Join(t.TempDir(), "errors.txt")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	got, err := ErrorTail(path)
	if err != nil {
		t.Fatalf("ErrorTail: %v", err)
	}
	gotLines := strings.Split(got, "\n")
	if len(gotLines) != defaultErrorTailWindow {
		t.Fatalf("ErrorTail returned %d lines, want exactly %d", len(gotLines), defaultErrorTailWindow)
	}
	if gotLines[len(gotLines)-1] != "line 25" {
		t.Fatalf("ErrorTail last line = %q, want %q", gotLines[len(gotLines)-1], "line 25")
	}
	if gotLines[0] != "line 6" {
		t.Fatalf("ErrorTail first line = %q, want %q", gotLines[0], "line 6")
	}
}

// TestErrorTail_FewerThanWindow returns all non-blank lines when the
// file holds fewer than the window size.
func TestErrorTail_FewerThanWindow(t *testing.T) {
	path := filepath.Join(t.TempDir(), "small.txt")
	if err := os.WriteFile(path, []byte("a\n\nb\n  \nc\n"), 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	got, err := ErrorTail(path)
	if err != nil {
		t.Fatalf("ErrorTail: %v", err)
	}
	if got != "a\nb\nc" {
		t.Fatalf("ErrorTail = %q, want %q", got, "a\nb\nc")
	}
}

// TestErrorTail_MissingFile pins the bash empty-string semantic.
func TestErrorTail_MissingFile(t *testing.T) {
	got, err := ErrorTail(filepath.Join(t.TempDir(), "does-not-exist.txt"))
	if err != nil {
		t.Fatalf("ErrorTail on missing file: err=%v, want nil", err)
	}
	if got != "" {
		t.Fatalf("ErrorTail on missing file = %q, want empty", got)
	}
}

// TestErrorTailWindowConstant pins the literal 20 in case a future
// refactor tries to make it env-driven. The m39.3 stall-detection
// fixture depends on this exact value.
func TestErrorTailWindowConstant(t *testing.T) {
	if defaultErrorTailWindow != 20 {
		t.Fatalf("defaultErrorTailWindow = %d, want 20 (m39.3 loop fixture)", defaultErrorTailWindow)
	}
}
