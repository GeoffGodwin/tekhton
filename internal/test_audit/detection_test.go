package test_audit

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestDetectOrphanedTests_PythonImport(t *testing.T) {
	dir := t.TempDir()
	tf := filepath.Join(dir, "test_foo.py")
	if err := os.WriteFile(tf, []byte("from mymodule import bar\nimport mymodule\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	ac := &AuditContext{
		TestFiles:    []string{tf},
		DeletedFiles: []string{"src/mymodule.py"},
	}
	got := DetectOrphanedTests(ac)
	if len(got) == 0 {
		t.Fatalf("expected at least one orphan finding")
	}
	expected := "ORPHAN: " + tf + " imports deleted module 'src/mymodule.py'"
	found := false
	for _, f := range got {
		if f == expected {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected finding %q, got %v", expected, got)
	}
}

func TestDetectOrphanedTests_JSImport(t *testing.T) {
	dir := t.TempDir()
	tf := filepath.Join(dir, "test_x.js")
	if err := os.WriteFile(tf, []byte("const m = require('./mymodule');\nimport thing from './mymodule';\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	ac := &AuditContext{
		TestFiles:    []string{tf},
		DeletedFiles: []string{"src/mymodule.js"},
	}
	got := DetectOrphanedTests(ac)
	if len(got) == 0 {
		t.Fatalf("expected one orphan finding, got %d", len(got))
	}
}

func TestDetectOrphanedTests_NoTestFilesIsEmpty(t *testing.T) {
	ac := &AuditContext{DeletedFiles: []string{"src/foo.py"}}
	if got := DetectOrphanedTests(ac); len(got) != 0 {
		t.Fatalf("no test files should produce no findings, got %d", len(got))
	}
}

func TestDetectOrphanedTests_NoDeletedFilesIsEmpty(t *testing.T) {
	ac := &AuditContext{TestFiles: []string{"a"}}
	if got := DetectOrphanedTests(ac); len(got) != 0 {
		t.Fatalf("no deletes should produce no findings, got %d", len(got))
	}
}

func TestWeakeningFindingsForDiff_NetLossOfTwo(t *testing.T) {
	diff := strings.Join([]string{
		"--- a/test_foo.py",
		"+++ b/test_foo.py",
		"@@ -1,5 +1,5 @@",
		"-assertEqual(foo, 1)",
		"-assertEqual(foo, 2)",
		"-assertEqual(foo, 3)",
		"+assertEqual(foo, 1)",
	}, "\n")
	got := weakeningFindingsForDiff("test_foo.py", diff)
	if len(got) == 0 {
		t.Fatalf("expected at least one weakening finding")
	}
	found := false
	for _, f := range got {
		if strings.Contains(f, "net loss of 2 assertion(s)") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected 'net loss of 2 assertion(s)' finding, got %v", got)
	}
}

func TestWeakeningFindingsForDiff_RemovedTestFunctions(t *testing.T) {
	diff := strings.Join([]string{
		"--- a/test.py",
		"+++ b/test.py",
		"-def test_foo():",
		"-def test_bar():",
	}, "\n")
	got := weakeningFindingsForDiff("test.py", diff)
	found := false
	for _, f := range got {
		if strings.Contains(f, "2 test function(s) removed") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected '2 test function(s) removed' finding, got %v", got)
	}
}

func TestWeakeningFindingsForDiff_BroadeningSwap(t *testing.T) {
	diff := strings.Join([]string{
		"--- a/test.py",
		"+++ b/test.py",
		"-assertEqual(x, 1)",
		"-toBe(y, 2)",
		"+assertTrue(x > 0)",
		"+toBeTruthy(y)",
	}, "\n")
	got := weakeningFindingsForDiff("test.py", diff)
	found := false
	for _, f := range got {
		if strings.Contains(f, "specific assertion(s) replaced with") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected broadening finding, got %v", got)
	}
}

func TestDetectTestWeakening_FullPipeline(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	dir := setupGitRepo(t)
	tf := "tests/test_x.py"
	abs := filepath.Join(dir, tf)
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(abs, []byte(
		"def test_one():\n    assertEqual(x, 1)\n    assertEqual(y, 2)\n    assertEqual(z, 3)\n",
	), 0o644); err != nil {
		t.Fatal(err)
	}
	gitInRepo(t, dir, "add", tf)
	gitInRepo(t, dir, "commit", "-m", "seed")
	// Now weaken it: drop two assertions.
	if err := os.WriteFile(abs, []byte(
		"def test_one():\n    assertEqual(x, 1)\n",
	), 0o644); err != nil {
		t.Fatal(err)
	}

	ac := &AuditContext{TestFiles: []string{tf}}
	got := DetectTestWeakening(context.Background(), ac, dir)
	if len(got) == 0 {
		t.Fatalf("expected weakening finding after dropping assertions; got none")
	}
}

func setupGitRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, args := range [][]string{
		{"init", "-q"},
		{"config", "user.email", "test@example.com"},
		{"config", "user.name", "Test"},
		{"config", "commit.gpgsign", "false"},
	} {
		gitInRepo(t, dir, args...)
	}
	return dir
}

func gitInRepo(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v failed: %v: %s", args, err, out)
	}
}
