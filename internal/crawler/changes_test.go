package crawler

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestParseDiffNameStatus(t *testing.T) {
	out := []byte("M\tREADME.md\n" +
		"A\tnew_file.go\n" +
		"D\told_file.go\n" +
		"R100\told/x.go\tnew/x.go\n" +
		"\n")
	got := parseDiffNameStatus(out)
	want := []Change{
		{Status: "M", Path: "README.md"},
		{Status: "A", Path: "new_file.go"},
		{Status: "D", Path: "old_file.go"},
		{Status: "R100", Path: "old/x.go", RenameTo: "new/x.go"},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d entries, want %d: %v", len(got), len(want), got)
	}
	for i, w := range want {
		if got[i] != w {
			t.Errorf("entry %d: got %+v, want %+v", i, got[i], w)
		}
	}
}

func TestParsePorcelain(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want []Change
	}{
		{
			name: "untracked",
			in:   "?? new.go\n",
			want: []Change{{Status: "A", Path: "new.go"}},
		},
		{
			name: "modified working tree",
			in:   " M file.go\n",
			want: []Change{{Status: "M", Path: "file.go"}},
		},
		{
			name: "deleted working tree",
			in:   " D file.go\n",
			want: []Change{{Status: "D", Path: "file.go"}},
		},
		{
			name: "staged modify",
			in:   "M  file.go\n",
			want: []Change{{Status: "M", Path: "file.go"}},
		},
		{
			name: "rename",
			in:   "R  old.go -> new.go\n",
			want: []Change{{Status: "R", Path: "old.go", RenameTo: "new.go"}},
		},
		{
			name: "ignored line",
			in:   "ZZ foo.go\n",
			want: nil,
		},
		{
			name: "short line skipped",
			in:   "x\n",
			want: nil,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := parsePorcelain([]byte(tc.in))
			if len(got) != len(tc.want) {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
			for i, w := range tc.want {
				if got[i] != w {
					t.Errorf("entry %d: got %+v, want %+v", i, got[i], w)
				}
			}
		})
	}
}

// gitInit creates a fresh git repo in dir with one commit. Tests that
// exercise DetectChangedFiles use this so the test is portable.
func gitInit(t *testing.T, dir string) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	run := func(args ...string) {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=test", "GIT_AUTHOR_EMAIL=t@e",
			"GIT_COMMITTER_NAME=test", "GIT_COMMITTER_EMAIL=t@e",
		)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q", "-b", "main")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("# x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run("add", "README.md")
	run("commit", "-q", "-m", "init")
	out, err := exec.Command("git", "-C", dir, "rev-parse", "HEAD").Output()
	if err != nil {
		t.Fatal(err)
	}
	return string(out[:7])
}

func TestDetectChangedFilesNoChanges(t *testing.T) {
	dir := t.TempDir()
	sha := gitInit(t, dir)
	changes, err := DetectChangedFiles(context.Background(), dir, sha)
	if err != nil {
		t.Fatalf("DetectChangedFiles: %v", err)
	}
	if len(changes) != 0 {
		t.Errorf("expected zero changes on clean tree, got %v", changes)
	}
}

func TestDetectChangedFilesWorkingTreeOnly(t *testing.T) {
	dir := t.TempDir()
	sha := gitInit(t, dir)
	// Modify a tracked file in working tree.
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("# changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Add an untracked file.
	if err := os.WriteFile(filepath.Join(dir, "new.go"), []byte("package x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	changes, err := DetectChangedFiles(context.Background(), dir, sha)
	if err != nil {
		t.Fatal(err)
	}
	if len(changes) != 2 {
		t.Fatalf("expected 2 changes, got %v", changes)
	}
	// Sorted by path.
	want := map[string]string{
		"README.md": "M",
		"new.go":    "A",
	}
	for _, c := range changes {
		if w, ok := want[c.Path]; !ok || c.Status != w {
			t.Errorf("unexpected change %+v", c)
		}
	}
}

func TestDetectChangedFilesWorkingTreeOverridesCommitted(t *testing.T) {
	dir := t.TempDir()
	sha := gitInit(t, dir)
	// Commit a modification.
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("# v2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run := func(args ...string) {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=test", "GIT_AUTHOR_EMAIL=t@e",
			"GIT_COMMITTER_NAME=test", "GIT_COMMITTER_EMAIL=t@e",
		)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("commit", "-q", "-am", "v2")
	// Then delete in working tree.
	if err := os.Remove(filepath.Join(dir, "README.md")); err != nil {
		t.Fatal(err)
	}

	changes, err := DetectChangedFiles(context.Background(), dir, sha)
	if err != nil {
		t.Fatal(err)
	}
	if len(changes) != 1 {
		t.Fatalf("expected 1 unique change, got %v", changes)
	}
	if changes[0].Status != "D" {
		t.Errorf("working-tree D should win over committed M: got %+v", changes[0])
	}
}

func TestGitCommitExists(t *testing.T) {
	dir := t.TempDir()
	sha := gitInit(t, dir)
	ctx := context.Background()
	if !gitCommitExists(ctx, dir, sha) {
		t.Errorf("recently-created commit should exist")
	}
	if gitCommitExists(ctx, dir, "0000000") {
		t.Errorf("bogus sha should not exist")
	}
	if gitCommitExists(ctx, dir, "") {
		t.Errorf("empty sha should return false")
	}
}

func TestIsGitRepo(t *testing.T) {
	dir := t.TempDir()
	if isGitRepo(context.Background(), dir) {
		t.Errorf("fresh tmpdir should not be a git repo")
	}
	gitInit(t, dir)
	if !isGitRepo(context.Background(), dir) {
		t.Errorf("post-init dir should be a git repo")
	}
}
