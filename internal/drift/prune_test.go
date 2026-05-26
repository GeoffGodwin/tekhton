package drift

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPrune_BelowThreshold_NoOp(t *testing.T) {
	l := tempLog(t)
	for i := 0; i < 5; i++ {
		_ = l.AppendObservations("t", "- obs")
	}
	_ = l.ResolveAllObservations()
	pruned, err := l.Prune(PruneOptions{KeepCount: 20})
	if err != nil {
		t.Fatal(err)
	}
	if pruned != 0 {
		t.Errorf("pruned = %d, want 0 (below threshold)", pruned)
	}
}

func TestPrune_AboveThreshold_ArchivesExcess(t *testing.T) {
	dir := filepath.Dir(tempLog(t).Path)
	l := NewLog(filepath.Join(dir, "DRIFT_LOG.md"))
	archive := filepath.Join(dir, "DRIFT_ARCHIVE.md")
	_ = l.EnsureLog()
	// Synthesize 25 resolved entries directly.
	for i := 0; i < 25; i++ {
		body, _ := os.ReadFile(l.Path)
		s := string(body)
		// Insert at top of Resolved section so head=newest order matches bash.
		marker := "## Resolved"
		idx := strings.Index(s, marker)
		if idx == -1 {
			t.Fatal("missing Resolved marker")
		}
		end := idx + len(marker) + 1 // after the newline
		entry := "- [RESOLVED 2026-05-26] entry-" + itoa(i) + "\n"
		newBody := s[:end] + entry + s[end:]
		_ = os.WriteFile(l.Path, []byte(newBody), 0o644)
	}
	pruned, err := l.Prune(PruneOptions{KeepCount: 20, ArchivePath: archive})
	if err != nil {
		t.Fatal(err)
	}
	if pruned != 5 {
		t.Errorf("pruned = %d, want 5", pruned)
	}
	// Archive must exist and contain the excess entries.
	body, err := os.ReadFile(archive)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "## Archived Entries") {
		t.Error("archive preamble missing")
	}
	resolved, _ := l.GetResolved()
	if len(resolved) != 20 {
		t.Errorf("remaining = %d, want 20", len(resolved))
	}
}

// itoa avoids importing strconv just for the prune fixture loop.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	digits := []byte{}
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}
