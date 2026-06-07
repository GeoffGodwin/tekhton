// Package test_audit implements the m38.4 port of the Tekhton test-audit
// subsystem. It ports six bash files (lib/test_audit*.sh) to a single Go
// package. Cross-file calls were extensive on the bash side; the Go shape
// preserves that one-package partitioning rather than splitting into
// sub-packages.
//
// Public API:
//   - Run            — pipeline-integration entry; collect → detect → agent → verdict
//   - RunStandalone  — --audit-tests entry; discover-all → agent → verdict
//   - DefaultOptions — regression-canary defaults (MaxReworkCycles=1 etc.)
//
// Loadbearing semantics preserved here:
//
//  1. MaxReworkCycles default of 1 is intentional. Higher values produced
//     runaway scope expansion in earlier dogfooding. TestDefaultOptions_*
//     guards this default.
//
//  2. Missing TEST_AUDIT_REPORT.md → VerdictPASS (bash default). The
//     missing-report branch is the 4th outcome; PASS/CONCERNS/NEEDS_WORK are
//     the three parsed verdicts.
//
//  3. M88 symbol detection uses native encoding/json — no python shell-out.
//     The bash version shelled to python3 because bash lacks structured JSON
//     support; Go does not.
//
//  4. _AUDIT_TEST_FILES and _AUDIT_SAMPLE_FILES are tracked separately. The
//     audit prompt renders them in distinct labeled sections so the agent
//     can apply scope-alignment scrutiny to sampled files without assuming
//     recent coder changes caused issues.
package test_audit

import (
	"bufio"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// AuditContext is the shared per-run state assembled by CollectAuditContext
// and consumed by every detector + the audit-agent prompt builder. Mirrors
// the bash `_AUDIT_*` globals one field per name.
type AuditContext struct {
	TestFiles         []string
	ImplFiles         []string
	DeletedFiles      []string
	SampleFiles       []string
	OrphanFindings    []string
	WeakeningFindings []string
	SymbolFindings    []string
}

// Request bundles the per-invocation paths and env that Run/RunStandalone
// need. The Go entry uses a struct rather than a long arg list so the seam
// is clear and tests can populate one or two fields without ceremony.
type Request struct {
	ProjectDir       string
	TekhtonHome      string
	PromptsDir       string
	TesterReportFile string
	CoderSummaryFile string
	AuditReportFile  string
	NonBlockingFile  string
	HistoryFile      string
	TestMapFile      string
	TagsFile         string
	Options          Options
	Logger           Logger
}

// Logger is the optional log/event emitter; nil is a no-op.
type Logger interface {
	Logf(format string, args ...any)
}

type noopLogger struct{}

func (noopLogger) Logf(string, ...any) {}

// resolveLogger returns the logger from a Request, falling back to a no-op.
func resolveLogger(req *Request) Logger {
	if req == nil || req.Logger == nil {
		return noopLogger{}
	}
	return req.Logger
}

// testerReportTickedRE matches the `- [x] \`path\`` lines of TESTER_REPORT.md.
var testerReportTickedRE = regexp.MustCompile("^\\- \\[x\\] `([^`]+)`")

// coderSummaryBacktickRE matches every `path` token inside CODER_SUMMARY.md.
var coderSummaryBacktickRE = regexp.MustCompile("`([^`]+)`")

// implFileTestFilterRE rejects implementation-file matches that look like
// tests/specs. Mirrors the bash `grep -vE 'test|spec|Test|Spec'` filter.
var implFileTestFilterRE = regexp.MustCompile("(?i)test|spec")

// CollectAuditContext gathers test files, implementation files, and deleted
// files into an AuditContext. Best-effort: missing files / non-git repos
// yield empty slices rather than errors.
func CollectAuditContext(ctx context.Context, req *Request) *AuditContext {
	ac := &AuditContext{}
	if req == nil {
		return ac
	}
	ac.TestFiles = readTestFilesFromReport(req.TesterReportFile)
	ac.ImplFiles = readImplFilesFromCoderSummary(req.CoderSummaryFile)
	ac.DeletedFiles = readDeletedFiles(ctx, req.ProjectDir)
	return ac
}

func readTestFilesFromReport(path string) []string {
	if path == "" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		m := testerReportTickedRE.FindStringSubmatch(sc.Text())
		if len(m) == 2 {
			out = append(out, m[1])
		}
	}
	return out
}

func readImplFilesFromCoderSummary(path string) []string {
	if path == "" {
		return nil
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	matches := coderSummaryBacktickRE.FindAllStringSubmatch(string(body), -1)
	var out []string
	for _, m := range matches {
		if len(m) != 2 {
			continue
		}
		tok := m[1]
		if implFileTestFilterRE.MatchString(tok) {
			continue
		}
		out = append(out, tok)
	}
	return out
}

func readDeletedFiles(ctx context.Context, projectDir string) []string {
	if projectDir == "" {
		return nil
	}
	if !isGitRepo(ctx, projectDir) {
		return nil
	}
	var out []string
	out = append(out, gitDeletedNames(ctx, projectDir, []string{"diff", "--name-status", "HEAD"})...)
	out = append(out, gitDeletedNames(ctx, projectDir, []string{"diff", "--cached", "--name-status"})...)
	return dedupeStrings(out)
}

func gitDeletedNames(ctx context.Context, projectDir string, args []string) []string {
	out, err := runGit(ctx, projectDir, args...)
	if err != nil {
		return nil
	}
	var deleted []string
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "D" {
			deleted = append(deleted, fields[1])
		}
	}
	return deleted
}

func isGitRepo(ctx context.Context, projectDir string) bool {
	_, err := runGit(ctx, projectDir, "rev-parse", "--git-dir")
	return err == nil
}

func runGit(ctx context.Context, projectDir string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = projectDir
	out, err := cmd.Output()
	return string(out), err
}

func dedupeStrings(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, s := range in {
		if s == "" {
			continue
		}
		if _, ok := seen[s]; ok {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	return out
}

// testFileNamingRE matches the common test-file-naming conventions used by
// _discover_all_test_files. The bash version greps git ls-files; the Go
// port preserves that one-shot scan and falls back to filepath.Walk only
// when the project is not a git repo (returns empty in the bash version —
// we keep the same behavior).
var testFileNamingRE = regexp.MustCompile(`(?i)(^tests?/|/__tests__/|_test\.|\.test\.|\.spec\.|_spec\.|test_)`)

// DiscoverAllTestFiles lists every project test file (used by RunStandalone
// and the M89 sampler). Mirrors the bash `_discover_all_test_files`: uses
// git ls-files to respect .gitignore. Returns empty when not in a git repo.
func DiscoverAllTestFiles(ctx context.Context, projectDir string) []string {
	if projectDir == "" {
		return nil
	}
	if !isGitRepo(ctx, projectDir) {
		return nil
	}
	out, err := runGit(ctx, projectDir, "ls-files")
	if err != nil {
		return nil
	}
	var hits []string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if testFileNamingRE.MatchString(line) {
			hits = append(hits, line)
		}
	}
	return hits
}

// BuildTestAuditContext assembles the TEST_AUDIT_CONTEXT prompt block. The
// bash version exported globals; the Go port returns the rendered string
// alongside the CODER_DELETED_FILES string so callers can populate the
// prompt variable map directly.
func BuildTestAuditContext(ac *AuditContext) (testAuditContext string, coderDeletedFiles string) {
	if ac == nil {
		return "", ""
	}
	var b strings.Builder
	b.WriteString("## Test Files Under Audit (modified this run)\n")
	if len(ac.TestFiles) > 0 {
		for _, f := range ac.TestFiles {
			b.WriteString("- ")
			b.WriteString(f)
			b.WriteString("\n")
		}
	} else {
		b.WriteString("- (none)\n")
	}
	if len(ac.SampleFiles) > 0 {
		b.WriteString("\n## Test Files Under Audit (freshness sample — may be stale)\n")
		for _, f := range ac.SampleFiles {
			b.WriteString("- ")
			b.WriteString(f)
			b.WriteString("\n")
		}
	}
	b.WriteString("\n## Implementation Files Changed\n")
	if len(ac.ImplFiles) > 0 {
		for _, f := range ac.ImplFiles {
			b.WriteString("- ")
			b.WriteString(f)
			b.WriteString("\n")
		}
	} else {
		b.WriteString("- none\n")
	}
	if len(ac.OrphanFindings) > 0 {
		b.WriteString("\n## Shell-Detected Orphans (pre-verified)\n")
		b.WriteString(strings.Join(ac.OrphanFindings, "\n"))
		b.WriteString("\n")
	}
	if len(ac.WeakeningFindings) > 0 {
		b.WriteString("\n## Shell-Detected Weakening (pre-verified)\n")
		b.WriteString(strings.Join(ac.WeakeningFindings, "\n"))
		b.WriteString("\n")
	}

	return b.String(), strings.Join(ac.DeletedFiles, "\n")
}

// resolveProjectRelative resolves a relative path under projectDir. Empty
// paths stay empty.
func resolveProjectRelative(projectDir, path string) string {
	if path == "" {
		return ""
	}
	if filepath.IsAbs(path) {
		return path
	}
	if projectDir == "" {
		return path
	}
	return filepath.Join(projectDir, path)
}
