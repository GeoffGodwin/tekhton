package notes

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// --- git repo helpers -------------------------------------------------------

// skipIfNoGit skips the test when git is not on PATH — the acceptance
// heuristics degrade gracefully in that case and there is nothing to
// assert.
func skipIfNoGit(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
}

// makeGitRepo initialises an empty git repository in a fresh temp dir,
// seeds an initial commit (so HEAD is a valid ref), and returns the dir
// path. All git commands use local user config so the test is hermetic.
func makeGitRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()

	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		// Provide author/committer identity in the environment so the
		// test does not depend on global git config.
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=tester",
			"GIT_AUTHOR_EMAIL=tester@example.com",
			"GIT_COMMITTER_NAME=tester",
			"GIT_COMMITTER_EMAIL=tester@example.com",
		)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
		}
	}

	run("init")
	run("config", "user.name", "tester")
	run("config", "user.email", "tester@example.com")

	// Seed an initial commit so HEAD is valid.
	writeTestFile(t, dir, "README.md", "# repo\n")
	run("add", "README.md")
	run("commit", "-m", "initial")
	return dir
}

// writeTestFile writes content to dir/relPath, creating parent dirs if
// needed. Intentionally named so it does not shadow testing.TB.
func writeTestFile(t *testing.T, dir, relPath, content string) {
	t.Helper()
	full := filepath.Join(dir, relPath)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatalf("mkdirAll(%s): %v", filepath.Dir(full), err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatalf("writeFile(%s): %v", relPath, err)
	}
}

// gitAdd stages the named paths in dir.
func gitStage(t *testing.T, dir string, paths ...string) {
	t.Helper()
	args := append([]string{"add"}, paths...)
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git add %v: %v\n%s", paths, err, out)
	}
}

// gitCommitAll stages all changes and creates a commit.
func gitCommitAll(t *testing.T, dir, msg string) {
	t.Helper()
	gitStage(t, dir, "-A")
	cmd := exec.Command("git", "commit", "-m", msg)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=tester",
		"GIT_AUTHOR_EMAIL=tester@example.com",
		"GIT_COMMITTER_NAME=tester",
		"GIT_COMMITTER_EMAIL=tester@example.com",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git commit: %v\n%s", err, out)
	}
}

// --- BUG acceptance ---------------------------------------------------------

func TestBugAcceptance(t *testing.T) {
	skipIfNoGit(t)
	ctx := context.Background()

	cases := []struct {
		name          string
		setup         func(dir string)
		coderSummary  string // content of CODER_SUMMARY.md; "" = do not create
		wantCode      string
		wantWarnCount int
	}{
		{
			// No test file in diff or untracked, no CODER_SUMMARY.md
			// present → only warn_no_test (RCA check is skipped when
			// the file is absent).
			name: "warn_no_test_no_summary",
			setup: func(dir string) {
				// Commit a non-test source file then modify it so it
				// appears in `git diff --name-only HEAD`.
				writeTestFile(t, dir, "src/main.go", "package main\n")
				gitCommitAll(t, dir, "add main.go")
				writeTestFile(t, dir, "src/main.go", "package main\n// changed\n")
			},
			coderSummary:  "", // absent — RCA warning must NOT fire
			wantCode:      "warn_no_test",
			wantWarnCount: 1,
		},
		{
			// Non-test file modified AND no root-cause section in the
			// summary → both warnings.
			name: "warn_no_test_and_no_rca",
			setup: func(dir string) {
				writeTestFile(t, dir, "src/main.go", "package main\n")
				gitCommitAll(t, dir, "add main.go")
				writeTestFile(t, dir, "src/main.go", "package main\n// changed\n")
			},
			coderSummary:  "## Summary\n\nFixed something.\n",
			wantCode:      "warn_no_test,warn_no_rca",
			wantWarnCount: 2,
		},
		{
			// An untracked test file satisfies the coverage check; a
			// CODER_SUMMARY.md whose FIRST line is `## Root Cause`
			// satisfies RCA.
			//
			// NOTE: rootCauseRE uses `^` without `(?m)`, so it only
			// matches the heading when it appears at the very start of the
			// file (start-of-text, not start-of-line). In practice this
			// means a CODER_SUMMARY.md that starts with ## Status or
			// ## Summary will spuriously trigger warn_no_rca — this is a
			// known divergence from the bash `grep -qi "^## Root Cause"`
			// semantics and is documented in ## Bugs Found.
			name: "pass_test_and_rca",
			setup: func(dir string) {
				// Commit a source file so HEAD has content.
				writeTestFile(t, dir, "src/main.go", "package main\n")
				gitCommitAll(t, dir, "add main.go")
				// Add an untracked test file — appears in
				// `git ls-files --others --exclude-standard`.
				writeTestFile(t, dir, "src/main_test.go", "package main\n")
			},
			// Root Cause heading must be at position 0 of the file for
			// the current regex to match.
			coderSummary:  "## Root Cause\n\nBad pointer dereference.\n",
			wantCode:      "pass",
			wantWarnCount: 0,
		},
		{
			// Test file present in `git diff HEAD` (committed then
			// modified) satisfies coverage; missing CODER_SUMMARY → no
			// RCA warning.
			name: "test_in_diff_no_summary",
			setup: func(dir string) {
				writeTestFile(t, dir, "tests/foo_test.go", "package foo\n")
				gitCommitAll(t, dir, "add test")
				writeTestFile(t, dir, "tests/foo_test.go", "package foo\n// v2\n")
			},
			coderSummary:  "",
			wantCode:      "pass",
			wantWarnCount: 0,
		},
		{
			// CODER_SUMMARY.md exists but has no ## Root Cause; test
			// file present → only warn_no_rca.
			name: "warn_no_rca_test_present",
			setup: func(dir string) {
				writeTestFile(t, dir, "tests/foo_test.go", "package foo\n")
				gitCommitAll(t, dir, "add test")
				writeTestFile(t, dir, "tests/foo_test.go", "package foo\n// v2\n")
			},
			coderSummary:  "## Summary\n\nFixed the bug.\n",
			wantCode:      "warn_no_rca",
			wantWarnCount: 1,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := makeGitRepo(t)
			tc.setup(dir)

			opts := AcceptanceOptions{ProjectDir: dir}
			if tc.coderSummary != "" {
				summaryPath := filepath.Join(dir, ".tekhton", "CODER_SUMMARY.md")
				writeTestFile(t, dir, ".tekhton/CODER_SUMMARY.md", tc.coderSummary)
				opts.CoderSummaryFile = summaryPath
			} else {
				// Point at a non-existent file so the RCA check is
				// skipped (os.ReadFile returns an error → warn_no_rca
				// is not emitted).
				opts.CoderSummaryFile = filepath.Join(dir, "does_not_exist.md")
			}

			res, err := RunAcceptance(ctx, "BUG", opts)
			if err != nil {
				t.Fatalf("RunAcceptance: %v", err)
			}
			if res.Tag != "BUG" {
				t.Errorf("Tag = %q, want BUG", res.Tag)
			}
			if res.Code != tc.wantCode {
				t.Errorf("Code = %q, want %q", res.Code, tc.wantCode)
			}
			if len(res.Warnings) != tc.wantWarnCount {
				t.Errorf("len(Warnings) = %d, want %d; warnings: %v",
					len(res.Warnings), tc.wantWarnCount, res.Warnings)
			}
		})
	}
}

// --- FEAT acceptance --------------------------------------------------------

func TestFeatAcceptance(t *testing.T) {
	skipIfNoGit(t)
	ctx := context.Background()

	t.Run("pass_no_new_files", func(t *testing.T) {
		dir := makeGitRepo(t)
		// Only committed files, nothing untracked or staged-new.
		writeTestFile(t, dir, "internal/pkg1/a.go", "package pkg1\n")
		gitCommitAll(t, dir, "add pkg1")

		res, err := RunAcceptance(ctx, "FEAT", AcceptanceOptions{ProjectDir: dir})
		if err != nil {
			t.Fatalf("RunAcceptance: %v", err)
		}
		if res.Code != "pass" {
			t.Errorf("Code = %q, want pass", res.Code)
		}
		if len(res.Warnings) != 0 {
			t.Errorf("unexpected warnings: %v", res.Warnings)
		}
	})

	t.Run("warn_file_placement", func(t *testing.T) {
		dir := makeGitRepo(t)
		// Populate common directories so topNDirs includes them.
		for i := 0; i < 5; i++ {
			writeTestFile(t, dir,
				filepath.Join("internal", "pkg1", "file"+string(rune('a'+i))+".go"),
				"package pkg1\n")
		}
		for i := 0; i < 3; i++ {
			writeTestFile(t, dir,
				filepath.Join("internal", "pkg2", "file"+string(rune('a'+i))+".go"),
				"package pkg2\n")
		}
		gitCommitAll(t, dir, "seed common dirs")

		// Add an untracked non-test file in an unusual sibling directory.
		// "internal/pkg3" is not in the top-N list; its parent "internal"
		// has siblings (pkg1, pkg2) that ARE in the list → warn.
		writeTestFile(t, dir, "internal/pkg3/new_feature.go", "package pkg3\n")

		res, err := RunAcceptance(ctx, "FEAT", AcceptanceOptions{ProjectDir: dir})
		if err != nil {
			t.Fatalf("RunAcceptance: %v", err)
		}
		if res.Code != "warn_file_placement" {
			t.Errorf("Code = %q, want warn_file_placement", res.Code)
		}
		if len(res.Warnings) != 1 {
			t.Errorf("len(Warnings) = %d, want 1; warnings: %v", len(res.Warnings), res.Warnings)
		}
		if !strings.Contains(res.Warnings[0], "internal/pkg3/new_feature.go") {
			t.Errorf("warning should name the offending file: %q", res.Warnings[0])
		}
	})

	t.Run("pass_new_file_in_common_dir", func(t *testing.T) {
		dir := makeGitRepo(t)
		// Populate common directories.
		for i := 0; i < 5; i++ {
			writeTestFile(t, dir,
				filepath.Join("internal", "pkg1", "file"+string(rune('a'+i))+".go"),
				"package pkg1\n")
		}
		gitCommitAll(t, dir, "seed common dirs")

		// New untracked file sits inside the common dir → no warning.
		writeTestFile(t, dir, "internal/pkg1/new_feature.go", "package pkg1\n")

		res, err := RunAcceptance(ctx, "FEAT", AcceptanceOptions{ProjectDir: dir})
		if err != nil {
			t.Fatalf("RunAcceptance: %v", err)
		}
		if res.Code != "pass" {
			t.Errorf("Code = %q, want pass; warnings: %v", res.Code, res.Warnings)
		}
	})

	t.Run("pass_new_test_file_skipped", func(t *testing.T) {
		dir := makeGitRepo(t)
		// Populate a common dir so topNDirs is non-empty.
		for i := 0; i < 3; i++ {
			writeTestFile(t, dir,
				filepath.Join("internal", "pkg1", "file"+string(rune('a'+i))+".go"),
				"package pkg1\n")
		}
		gitCommitAll(t, dir, "seed")

		// Add an unusual dir but ONLY with test files — the feat check
		// skips test files explicitly.
		writeTestFile(t, dir, "internal/pkg3/foo_test.go", "package pkg3\n")

		res, err := RunAcceptance(ctx, "FEAT", AcceptanceOptions{ProjectDir: dir})
		if err != nil {
			t.Fatalf("RunAcceptance: %v", err)
		}
		if res.Code != "pass" {
			t.Errorf("Code = %q, want pass; test files should be ignored", res.Code)
		}
	})
}

// --- POLISH acceptance ------------------------------------------------------

func TestPolishAcceptance(t *testing.T) {
	skipIfNoGit(t)
	ctx := context.Background()

	t.Run("warn_logic_modified_unstaged", func(t *testing.T) {
		dir := makeGitRepo(t)
		// Commit a Go source file, then modify it (unstaged) so it
		// appears in `git diff --name-only HEAD`.
		writeTestFile(t, dir, "lib/parser.go", "package lib\n")
		gitCommitAll(t, dir, "add parser")
		writeTestFile(t, dir, "lib/parser.go", "package lib\n// changed\n")

		res, err := RunAcceptance(ctx, "POLISH", AcceptanceOptions{ProjectDir: dir})
		if err != nil {
			t.Fatalf("RunAcceptance: %v", err)
		}
		if res.Code != "warn_logic_modified" {
			t.Errorf("Code = %q, want warn_logic_modified", res.Code)
		}
		if len(res.Warnings) != 1 {
			t.Errorf("len(Warnings) = %d, want 1; warnings: %v", len(res.Warnings), res.Warnings)
		}
		if !strings.Contains(res.Warnings[0], "lib/parser.go") {
			t.Errorf("warning should name the offending file: %q", res.Warnings[0])
		}
	})

	t.Run("warn_logic_modified_staged", func(t *testing.T) {
		dir := makeGitRepo(t)
		// Commit then stage a modification.
		writeTestFile(t, dir, "lib/parser.go", "package lib\n")
		gitCommitAll(t, dir, "add parser")
		writeTestFile(t, dir, "lib/parser.go", "package lib\n// staged\n")
		gitStage(t, dir, "lib/parser.go")

		res, err := RunAcceptance(ctx, "POLISH", AcceptanceOptions{ProjectDir: dir})
		if err != nil {
			t.Fatalf("RunAcceptance: %v", err)
		}
		if res.Code != "warn_logic_modified" {
			t.Errorf("Code = %q, want warn_logic_modified", res.Code)
		}
	})

	t.Run("pass_no_logic_files", func(t *testing.T) {
		dir := makeGitRepo(t)
		// Modify only a markdown file — not in defaultPolishLogicPatterns.
		writeTestFile(t, dir, "docs/CHANGELOG.md", "# changelog\n")
		gitCommitAll(t, dir, "add changelog")
		writeTestFile(t, dir, "docs/CHANGELOG.md", "# changelog\n## v2\n")

		res, err := RunAcceptance(ctx, "POLISH", AcceptanceOptions{ProjectDir: dir})
		if err != nil {
			t.Fatalf("RunAcceptance: %v", err)
		}
		if res.Code != "pass" {
			t.Errorf("Code = %q, want pass; warnings: %v", res.Code, res.Warnings)
		}
	})

	t.Run("pass_test_file_excluded", func(t *testing.T) {
		dir := makeGitRepo(t)
		// Modifying a test Go file should NOT trigger warn_logic_modified
		// because test files are excluded from the logic-file list.
		writeTestFile(t, dir, "lib/parser_test.go", "package lib\n")
		gitCommitAll(t, dir, "add test")
		writeTestFile(t, dir, "lib/parser_test.go", "package lib\n// changed\n")

		res, err := RunAcceptance(ctx, "POLISH", AcceptanceOptions{ProjectDir: dir})
		if err != nil {
			t.Fatalf("RunAcceptance: %v", err)
		}
		if res.Code != "pass" {
			t.Errorf("Code = %q, want pass; test files should be excluded", res.Code)
		}
	})

	t.Run("custom_logic_patterns", func(t *testing.T) {
		dir := makeGitRepo(t)
		// Default patterns do not include .txt; custom patterns do.
		// Modified .txt file should produce warn_logic_modified.
		writeTestFile(t, dir, "lib/data.txt", "hello\n")
		gitCommitAll(t, dir, "add data.txt")
		writeTestFile(t, dir, "lib/data.txt", "hello world\n")

		res, err := RunAcceptance(ctx, "POLISH", AcceptanceOptions{
			ProjectDir:          dir,
			PolishLogicPatterns: []string{".txt"},
		})
		if err != nil {
			t.Fatalf("RunAcceptance: %v", err)
		}
		if res.Code != "warn_logic_modified" {
			t.Errorf("Code = %q, want warn_logic_modified with custom patterns", res.Code)
		}
	})
}

// --- Unknown tag pass -------------------------------------------------------

func TestUnknownTagPass(t *testing.T) {
	ctx := context.Background()
	// Unknown tag must return a no-op pass without touching the filesystem
	// or running any git commands — no git repo needed.
	res, err := RunAcceptance(ctx, "CUSTOM", AcceptanceOptions{
		ProjectDir: t.TempDir(),
	})
	if err != nil {
		t.Fatalf("RunAcceptance: %v", err)
	}
	if res.Code != "pass" {
		t.Errorf("unknown tag: Code = %q, want pass", res.Code)
	}
	if len(res.Warnings) != 0 {
		t.Errorf("unknown tag: unexpected warnings: %v", res.Warnings)
	}
}

// TestEmptyTagPass ensures an empty tag string also resolves to pass
// (matches bash default branch semantics).
func TestEmptyTagPass(t *testing.T) {
	ctx := context.Background()
	res, err := RunAcceptance(ctx, "", AcceptanceOptions{
		ProjectDir: t.TempDir(),
	})
	if err != nil {
		t.Fatalf("RunAcceptance: %v", err)
	}
	if res.Code != "pass" {
		t.Errorf("empty tag: Code = %q, want pass", res.Code)
	}
}
