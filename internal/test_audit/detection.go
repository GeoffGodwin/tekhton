package test_audit

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Orphan detection — extract import targets from each test file, cross-
// reference against the deleted-files basename list, and emit one finding
// per match.

var (
	// pythonImportRE matches `from X import` and `import X` tokens.
	pythonImportRE = regexp.MustCompile(`(?:from\s+|import\s+)([\w.]+)`)

	// jsImportRE matches `require('X')` and `from 'X'` / `from "X"` tokens.
	jsImportRE = regexp.MustCompile(`(?:require\s*\(\s*['"]|from\s+['"])([^'"]+)`)
)

// DetectOrphanedTests returns one finding per test file that imports a
// deleted module. Mirrors lib/test_audit_detection.sh::_detect_orphaned_tests.
// Reads ac.TestFiles + ac.DeletedFiles, writes the result back to
// ac.OrphanFindings.
func DetectOrphanedTests(ac *AuditContext) []string {
	if ac == nil || len(ac.TestFiles) == 0 || len(ac.DeletedFiles) == 0 {
		if ac != nil {
			ac.OrphanFindings = nil
		}
		return nil
	}

	var findings []string
	for _, testFile := range ac.TestFiles {
		if testFile == "" {
			continue
		}
		body, err := os.ReadFile(testFile)
		if err != nil {
			continue
		}
		imports := extractImports(string(body))
		for _, deleted := range ac.DeletedFiles {
			if deleted == "" {
				continue
			}
			base := filepath.Base(deleted)
			ext := filepath.Ext(base)
			noExt := strings.TrimSuffix(base, ext)
			if noExt == "" {
				continue
			}
			if strings.Contains(imports, noExt) {
				findings = append(findings, fmt.Sprintf(
					"ORPHAN: %s imports deleted module '%s'", testFile, deleted))
			}
		}
	}
	ac.OrphanFindings = findings
	return findings
}

// extractImports concatenates the union of Python + JS/TS import tokens.
// Used by DetectOrphanedTests; a simple "contains" check against the
// deleted-module basename mirrors the bash `grep -qF` behavior.
func extractImports(src string) string {
	var b strings.Builder
	for _, m := range pythonImportRE.FindAllStringSubmatch(src, -1) {
		if len(m) >= 2 {
			b.WriteString(m[1])
			b.WriteString("\n")
		}
	}
	for _, m := range jsImportRE.FindAllStringSubmatch(src, -1) {
		if len(m) >= 2 {
			b.WriteString(m[1])
			b.WriteString("\n")
		}
	}
	return b.String()
}

// Weakening detection — for each MODIFIED (existed at HEAD) test file,
// run `git diff HEAD -- file`, count removed vs added assertion lines via
// regex, emit findings when removed > added, when specific→broad swaps
// appear, or when test functions are removed.

var (
	assertionRE = regexp.MustCompile(
		`\b(assert|expect|should|assertEqual|assertEquals|assertThat|assertTrue|assertFalse|toBe|toEqual|toMatch|toThrow)\b`)
	broadeningRE = regexp.MustCompile(
		`(assertTrue\s*\(|assertGreater|assertLess|toBeGreater|toBeLess|toBeTruthy|toBeFalsy)`)
	specificRE = regexp.MustCompile(
		`(assertEqual|assertEquals|toBe\(|toEqual\(|toStrictEqual)`)
	testFnRE = regexp.MustCompile(
		`^\s*(def test_|it\(|test\(|func Test|describe\()`)
)

// DetectTestWeakening returns findings for each test file whose diff vs
// HEAD shows net assertion loss, broadening swaps, or removed test
// functions. Mirrors lib/test_audit_detection.sh::_detect_test_weakening.
func DetectTestWeakening(ctx context.Context, ac *AuditContext, projectDir string) []string {
	if ac == nil || len(ac.TestFiles) == 0 {
		if ac != nil {
			ac.WeakeningFindings = nil
		}
		return nil
	}
	if !isGitRepo(ctx, projectDir) {
		ac.WeakeningFindings = nil
		return nil
	}

	var findings []string
	for _, tf := range ac.TestFiles {
		if tf == "" {
			continue
		}
		if _, err := os.Stat(filepath.Join(projectDir, tf)); err != nil {
			// Test file may have been deleted post-write; skip rather than fail.
			if _, err2 := os.Stat(tf); err2 != nil {
				continue
			}
		}
		// Skip newly created files (no prior HEAD blob).
		if _, err := runGit(ctx, projectDir, "show", "HEAD:"+tf); err != nil {
			continue
		}
		diff, err := runGit(ctx, projectDir, "diff", "HEAD", "--", tf)
		if err != nil || diff == "" {
			continue
		}
		findings = append(findings, weakeningFindingsForDiff(tf, diff)...)
	}
	ac.WeakeningFindings = findings
	return findings
}

// weakeningFindingsForDiff is the per-file finding generator. Extracted so
// the regex tallies are unit-testable without touching git.
func weakeningFindingsForDiff(testFile, diff string) []string {
	removed, added := 0, 0
	broadened, specificRemoved := 0, 0
	removedTests := 0

	for _, line := range strings.Split(diff, "\n") {
		if len(line) == 0 {
			continue
		}
		switch line[0] {
		case '-':
			if len(line) >= 2 && line[1] == '-' {
				continue // ignore diff headers like `--- a/foo`
			}
			body := line[1:]
			if assertionRE.MatchString(body) {
				removed++
			}
			if specificRE.MatchString(body) {
				specificRemoved++
			}
			if testFnRE.MatchString(body) {
				removedTests++
			}
		case '+':
			if len(line) >= 2 && line[1] == '+' {
				continue // ignore diff headers like `+++ b/foo`
			}
			body := line[1:]
			if assertionRE.MatchString(body) {
				added++
			}
			if broadeningRE.MatchString(body) {
				broadened++
			}
		}
	}

	var out []string
	if removed > added {
		out = append(out, fmt.Sprintf(
			"WEAKENING: %s — net loss of %d assertion(s) (removed %d, added %d)",
			testFile, removed-added, removed, added))
	}
	if specificRemoved > 0 && broadened > 0 {
		out = append(out, fmt.Sprintf(
			"WEAKENING: %s — %d specific assertion(s) replaced with %d broader assertion(s)",
			testFile, specificRemoved, broadened))
	}
	if removedTests > 0 {
		out = append(out, fmt.Sprintf(
			"WEAKENING: %s — %d test function(s) removed",
			testFile, removedTests))
	}
	return out
}
