package docs

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
)

// gitInit initializes a fresh repo in dir with one commit so `git diff HEAD`
// has a base to compare against. Returns the repo path.
func gitInit(t *testing.T, dir string) {
	t.Helper()
	for _, args := range [][]string{
		{"init", "-q"},
		{"config", "user.email", "t@example.com"},
		{"config", "user.name", "T"},
		{"config", "commit.gpgsign", "false"},
		{"commit", "--allow-empty", "-m", "init", "-q"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// writeAndStage writes path inside a git repo and `git add`s it so it appears
// in `git diff --cached HEAD`. The skip-check's two-arm pattern (unstaged
// first, staged fallback) means staged-only changes are sufficient.
func writeAndStage(t *testing.T, repo, relPath, body string) {
	t.Helper()
	full := filepath.Join(repo, relPath)
	writeFile(t, full, body)
	cmd := exec.Command("git", "add", relPath)
	cmd.Dir = repo
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git add %s: %v\n%s", relPath, err, out)
	}
}

// writeAndCommit writes a file, stages it, and commits — leaves the repo
// with no "changed files" for the skip-check to see. Used to seed CLAUDE.md
// or other config files the test wants present but NOT in the changed set.
func writeAndCommit(t *testing.T, repo, relPath, body string) {
	t.Helper()
	writeAndStage(t, repo, relPath, body)
	cmd := exec.Command("git", "commit", "-q", "-m", "seed "+relPath)
	cmd.Dir = repo
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git commit %s: %v\n%s", relPath, err, out)
	}
}

func newTestLogger() (staglog.Logger, *bytes.Buffer) {
	var buf bytes.Buffer
	return staglog.NewWithWriter(&buf, 1, 1), &buf
}

func TestShouldSkip_NoChangedFiles(t *testing.T) {
	proj := t.TempDir()
	gitInit(t, proj)
	log, _ := newTestLogger()
	got := shouldSkip(proj, filepath.Join(proj, "CLAUDE.md"), log)
	if !got {
		t.Fatal("expected skip when no files changed")
	}
}

func TestShouldSkip_NoCLAUDEMd(t *testing.T) {
	proj := t.TempDir()
	gitInit(t, proj)
	// Create a changed file but no CLAUDE.md — should NOT skip (false-negative
	// skip is worse than false-positive run).
	writeAndStage(t, proj, "foo.go", "package main\n")
	log, _ := newTestLogger()
	got := shouldSkip(proj, filepath.Join(proj, "CLAUDE.md"), log)
	if got {
		t.Fatal("expected run (skip=false) when CLAUDE.md is missing")
	}
}

func TestShouldSkip_NoSection(t *testing.T) {
	proj := t.TempDir()
	gitInit(t, proj)
	// CLAUDE.md present (committed, not in changed set) but has no
	// Documentation Responsibilities section. Coder touched a .go file.
	writeAndCommit(t, proj, "CLAUDE.md", "# Project\n\n## Other\nstuff\n")
	writeAndStage(t, proj, "foo.go", "package main\n")
	log, _ := newTestLogger()
	got := shouldSkip(proj, "CLAUDE.md", log)
	if got {
		t.Fatal("expected run (skip=false) when CLAUDE.md has no surface section")
	}
}

func TestShouldSkip_PatternsNoMatch(t *testing.T) {
	proj := t.TempDir()
	gitInit(t, proj)
	// CLAUDE.md is project config (committed, not part of the changed set).
	// Coder touched a .go file; the surface section names *.md / explicit-dir/.
	writeAndCommit(t, proj, "CLAUDE.md", `# X
## Documentation Responsibilities
- Update *.md when public surface changes
- Update some-explicit-dir/ for new flags
`)
	writeAndStage(t, proj, "foo.go", "package main\n")
	// Force the always-seeded README.md / docs/ defaults to point somewhere
	// the changed file definitely doesn't match.
	t.Setenv("DOCS_DIRS", "definitely-not-real/")
	t.Setenv("DOCS_README_FILE", "definitely-not-a-readme.md")
	log, _ := newTestLogger()
	got := shouldSkip(proj, "CLAUDE.md", log)
	if !got {
		t.Fatal("expected skip when changed files don't intersect surface patterns")
	}
}

func TestShouldSkip_PatternsMatch(t *testing.T) {
	proj := t.TempDir()
	gitInit(t, proj)
	// CLAUDE.md is config (committed); README.md is the change the coder made.
	writeAndCommit(t, proj, "CLAUDE.md", `# X
## Documentation Responsibilities
- Update README.md
`)
	writeAndStage(t, proj, "README.md", "# project\n")
	log, _ := newTestLogger()
	got := shouldSkip(proj, "CLAUDE.md", log)
	if got {
		t.Fatal("expected run (skip=false) when changed file matches surface pattern")
	}
}

func TestExtractDocResponsibilities(t *testing.T) {
	body := `# Project

## Other
junk

## Documentation Responsibilities
- README.md
- docs/

## Next
more junk
`
	got := extractDocResponsibilities(body)
	if !strings.Contains(got, "README.md") {
		t.Fatalf("section missing README.md: %q", got)
	}
	if strings.Contains(got, "more junk") {
		t.Fatalf("section bled into next H2: %q", got)
	}
}

func TestExtractPublicSurface_AlwaysIncludesDefaults(t *testing.T) {
	proj := t.TempDir()
	// Section present but empty body — defaults should still seed the slice.
	writeFile(t, filepath.Join(proj, "CLAUDE.md"), `# X

## Documentation Responsibilities

stub
`)
	t.Setenv("DOCS_README_FILE", "")
	t.Setenv("DOCS_DIRS", "")
	patterns := extractPublicSurface(proj, "CLAUDE.md")
	if len(patterns) == 0 {
		t.Fatal("patterns empty — defaults should have seeded README.md + docs/")
	}
	have := map[string]bool{}
	for _, p := range patterns {
		have[p] = true
	}
	if !have["README.md"] {
		t.Fatalf("README.md not in patterns: %v", patterns)
	}
	if !have["docs/"] {
		t.Fatalf("docs/ not in patterns: %v", patterns)
	}
}

func TestExtractPublicSurface_NoSection(t *testing.T) {
	proj := t.TempDir()
	writeFile(t, filepath.Join(proj, "CLAUDE.md"), "# X\nno section here\n")
	patterns := extractPublicSurface(proj, "CLAUDE.md")
	if patterns != nil {
		t.Fatalf("expected nil when section absent, got %v", patterns)
	}
}

func TestFilesMatchSurface(t *testing.T) {
	cases := []struct {
		name     string
		files    []string
		patterns []string
		want     bool
	}{
		{"glob match", []string{"src/foo.sh"}, []string{"*.sh"}, true},
		{"glob no-match", []string{"src/foo.go"}, []string{"*.sh"}, false},
		{"literal substring match", []string{"docs/foo.md"}, []string{"docs/"}, true},
		{"literal substring no-match", []string{"src/foo.go"}, []string{"docs/"}, false},
		{"empty patterns", []string{"x"}, []string{""}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := filesMatchSurface(c.files, c.patterns); got != c.want {
				t.Fatalf("got %v want %v", got, c.want)
			}
		})
	}
}

func TestGlobToRegexp(t *testing.T) {
	re, err := globToRegexp("*.md")
	if err != nil {
		t.Fatal(err)
	}
	if !re.MatchString("README.md") {
		t.Fatal("expected match")
	}
	if re.MatchString("README.txt") {
		t.Fatal("unexpected match")
	}
}
