package dag

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/manifest"
)

const sampleClaudeMD = `# Project Rules

## Current Initiative: Test Project

### Milestone Plan

#### Milestone 1: First Feature
Implement the first feature.

Acceptance criteria:
- Feature works
- Tests pass

#### [DONE] Milestone 2: Second Feature
Implement the second feature.

Acceptance criteria:
- Second works

#### Milestone 3: Third Feature
Depends on Milestone 1.

Implement the third feature.

Acceptance criteria:
- Third works
`

func TestMigrateHappyPath(t *testing.T) {
	dir := t.TempDir()
	claudeMD := filepath.Join(dir, "CLAUDE.md")
	if err := os.WriteFile(claudeMD, []byte(sampleClaudeMD), 0o644); err != nil {
		t.Fatal(err)
	}
	mDir := filepath.Join(dir, ".claude/milestones")

	n, err := Migrate(MigrateOptions{ClaudeMD: claudeMD, MilestoneDir: mDir})
	if err != nil {
		t.Fatalf("Migrate: %v", err)
	}
	if n != 3 {
		t.Fatalf("migrated %d, want 3", n)
	}

	manifestPath := filepath.Join(mDir, "MANIFEST.cfg")
	m, err := manifest.Load(manifestPath)
	if err != nil {
		t.Fatalf("Load manifest: %v", err)
	}
	if len(m.Entries) != 3 {
		t.Fatalf("manifest has %d entries, want 3", len(m.Entries))
	}
	for _, e := range m.Entries {
		fp := filepath.Join(mDir, e.File)
		if _, err := os.Stat(fp); err != nil {
			t.Errorf("milestone file missing for %s: %v", e.ID, err)
		}
	}
	// m02 is [DONE]
	e, _ := m.Get("m02")
	if e.Status != StatusDone {
		t.Errorf("m02 status %s, want done", e.Status)
	}
	// m01 fallback dep is empty (first milestone, no prior)
	if e1, _ := m.Get("m01"); len(e1.Depends) != 0 {
		t.Errorf("m01 deps = %v, want empty", e1.Depends)
	}
	// m03 explicit "depends on Milestone 1"
	if e3, _ := m.Get("m03"); !contains(e3.Depends, "m01") {
		t.Errorf("m03 deps = %v, want to contain m01", e3.Depends)
	}
}

func TestMigrateIdempotent(t *testing.T) {
	dir := t.TempDir()
	claudeMD := filepath.Join(dir, "CLAUDE.md")
	_ = os.WriteFile(claudeMD, []byte(sampleClaudeMD), 0o644)
	mDir := filepath.Join(dir, ".claude/milestones")

	if _, err := Migrate(MigrateOptions{ClaudeMD: claudeMD, MilestoneDir: mDir}); err != nil {
		t.Fatalf("first Migrate: %v", err)
	}
	_, err := Migrate(MigrateOptions{ClaudeMD: claudeMD, MilestoneDir: mDir})
	if !errors.Is(err, ErrMigrateAlreadyDone) {
		t.Fatalf("second Migrate err = %v, want ErrMigrateAlreadyDone", err)
	}
}

func TestMigrateNoMilestones(t *testing.T) {
	dir := t.TempDir()
	claudeMD := filepath.Join(dir, "CLAUDE.md")
	_ = os.WriteFile(claudeMD, []byte("# Project Rules\nNo milestones here.\n"), 0o644)
	mDir := filepath.Join(dir, ".claude/milestones")

	_, err := Migrate(MigrateOptions{ClaudeMD: claudeMD, MilestoneDir: mDir})
	if !errors.Is(err, ErrNoMilestonesFound) {
		t.Fatalf("err = %v, want ErrNoMilestonesFound", err)
	}
}

func TestMigrateMissingFile(t *testing.T) {
	dir := t.TempDir()
	mDir := filepath.Join(dir, ".claude/milestones")
	_, err := Migrate(MigrateOptions{ClaudeMD: filepath.Join(dir, "missing.md"), MilestoneDir: mDir})
	if err == nil {
		t.Fatalf("expected error for missing CLAUDE.md")
	}
}

func TestMigrateMultiDep(t *testing.T) {
	dir := t.TempDir()
	claudeMD := filepath.Join(dir, "CLAUDE.md")
	body := `# Project
### Milestones
#### Milestone 1: First
Acceptance criteria:
- ok
#### Milestone 2: Second
Acceptance criteria:
- ok
#### Milestone 3: Third
Depends on Milestone 1.
Also depends on Milestone 2.

Acceptance criteria:
- ok
`
	_ = os.WriteFile(claudeMD, []byte(body), 0o644)
	mDir := filepath.Join(dir, ".claude/milestones")
	n, err := Migrate(MigrateOptions{ClaudeMD: claudeMD, MilestoneDir: mDir})
	if err != nil || n != 3 {
		t.Fatalf("Migrate n=%d err=%v", n, err)
	}
	m, _ := manifest.Load(filepath.Join(mDir, "MANIFEST.cfg"))
	e3, _ := m.Get("m03")
	if !contains(e3.Depends, "m01") || !contains(e3.Depends, "m02") {
		t.Fatalf("m03 deps = %v, want both m01 and m02", e3.Depends)
	}
}

func TestSlugify(t *testing.T) {
	cases := []struct{ in, want string }{
		{"DAG Infrastructure", "dag-infrastructure"},
		{"Has  Spaces", "has-spaces"},
		{"with-hyphens", "with-hyphens"},
		{"Unicode★Star", "unicodestar"},
		{strings.Repeat("a", 50), strings.Repeat("a", 40)},
	}
	for _, c := range cases {
		if got := slugify(c.in); got != c.want {
			t.Errorf("slugify(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestNumberToID(t *testing.T) {
	cases := []struct{ in, want string }{
		{"1", "m01"},
		{"13", "m13"},
		{"3.1", "m03.1"},
		{"100", "m100"},
	}
	for _, c := range cases {
		if got := numberToID(c.in); got != c.want {
			t.Errorf("numberToID(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestRewritePointer(t *testing.T) {
	dir := t.TempDir()
	claudeMD := filepath.Join(dir, "CLAUDE.md")
	body := `# Project

## Architecture
Some architecture.

### Milestone Plan

#### Milestone 1: First
First content.

Acceptance criteria:
- ok

#### Milestone 2: Second
Second content.

## Code Conventions
Conventions.
`
	_ = os.WriteFile(claudeMD, []byte(body), 0o644)

	if err := RewritePointer(claudeMD); err != nil {
		t.Fatal(err)
	}
	out, _ := os.ReadFile(claudeMD)
	s := string(out)
	if !strings.Contains(s, "Milestones are managed as individual files") {
		t.Errorf("pointer comment not inserted")
	}
	if strings.Contains(s, "First content") {
		t.Errorf("milestone content not removed")
	}
	if !strings.Contains(s, "Some architecture") {
		t.Errorf("non-milestone content lost")
	}
	if !strings.Contains(s, "Code Conventions") {
		t.Errorf("post-milestone heading lost")
	}

	// Idempotent
	if err := RewritePointer(claudeMD); err != nil {
		t.Fatal(err)
	}
	out2, _ := os.ReadFile(claudeMD)
	if strings.Count(string(out2), "Milestones are managed") != 1 {
		t.Errorf("pointer comment duplicated on second call")
	}
}

func TestRewritePointerNoMilestones(t *testing.T) {
	dir := t.TempDir()
	claudeMD := filepath.Join(dir, "CLAUDE.md")
	_ = os.WriteFile(claudeMD, []byte("# Project\n\nNo milestones.\n"), 0o644)
	if err := RewritePointer(claudeMD); err != nil {
		t.Fatal(err)
	}
	out, _ := os.ReadFile(claudeMD)
	if strings.Contains(string(out), "Milestones are managed") {
		t.Errorf("pointer wrongly inserted into pristine file")
	}
}

func contains(s []string, target string) bool {
	for _, v := range s {
		if v == target {
			return true
		}
	}
	return false
}
