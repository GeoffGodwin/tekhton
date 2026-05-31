package crawler

import (
	"strings"
	"testing"
)

func TestAnnotateLineSpaceBoundary(t *testing.T) {
	// Bash sed `\($\| \)` quirk: annotation requires the name be followed
	// by a space, NOT EOL. These tests pin that behaviour so future
	// "let me fix the EOL gap" PRs fail red.
	cases := []struct {
		in, want string
	}{
		// Space after — annotated.
		{"├── src ", "├── src [source] "},
		{"./src dir", "./src [source] dir"},
		// EOL — NOT annotated (bash quirk).
		{"./src", "./src"},
		{"./.github", "./.github"},
		// Followed by /, not space — NOT annotated.
		{"./src/main.go", "./src/main.go"},
	}
	for _, c := range cases {
		if got := annotateLine(c.in); got != c.want {
			t.Errorf("annotateLine(%q):\n  got  %q\n  want %q", c.in, got, c.want)
		}
	}
}

func TestAnnotateLineGroupOrdering(t *testing.T) {
	// `.config` (literal-dot start) must win over `config` when both
	// names are present — longest-first within the configuration group.
	got := annotateLine("./.config foo")
	want := "./.config [configuration] foo"
	if got != want {
		t.Errorf("annotation longest-first:\n  got  %q\n  want %q", got, want)
	}
}

func TestAnnotateLineSequentialGroups(t *testing.T) {
	// `tests` and `docs` are separate groups; both annotations apply.
	got := annotateLine("./tests after docs again")
	if !strings.Contains(got, "[tests]") {
		t.Errorf("missing tests annotation: %q", got)
	}
	if !strings.Contains(got, "[documentation]") {
		t.Errorf("missing documentation annotation: %q", got)
	}
}

func TestFindBasedTreeStripsPrefix(t *testing.T) {
	dir := t.TempDir()
	out := findBasedTree(dir, 6)
	if !strings.HasPrefix(out, ".") {
		t.Errorf("findBasedTree should rewrite root to '.', got %q", out[:min(40, len(out))])
	}
}

func TestItoa(t *testing.T) {
	cases := map[int]string{0: "0", 1: "1", 42: "42", -7: "-7", 1000: "1000"}
	for in, want := range cases {
		if got := itoa(in); got != want {
			t.Errorf("itoa(%d) = %q, want %q", in, got, want)
		}
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
