package tester

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// RoutingKind identifies the branch the tester-stage validation router
// selected. The six values map 1:1 to the bash branches in
// stages/tester_validation.sh::_validate_tester_output.
type RoutingKind int

const (
	// RoutingClean — TESTER_REPORT.md is present, no compilation or test
	// failures detected, REMAINING == 0. Bash branch:
	// stages/tester_validation.sh:107-115 (`success` + `clear_pipeline_state`).
	RoutingClean RoutingKind = iota
	// RoutingCompilationErrors — log contains "Compilation failed" or
	// "Failed to load". Bash branch: stages/tester_validation.sh:56-73.
	// Affected test file checkboxes are flipped from [x] back to [ ].
	RoutingCompilationErrors
	// RoutingTestFailures — log contains negative-number test-failure
	// summary lines (pytest-style `-1: ...`). Bash branch:
	// stages/tester_validation.sh:74-86 (the tester-fix entry).
	RoutingTestFailures
	// RoutingPartialRun — TESTER_REPORT.md is present, REMAINING > 0,
	// no failures detected. Bash branch:
	// stages/tester_validation.sh:86-106 (the continuation loop entry).
	RoutingPartialRun
	// RoutingNoReportButTestsCreated — TESTER_REPORT.md missing AND
	// git diff shows test/spec file mutations. Bash branch:
	// stages/tester_validation.sh:27-46. Trips the #46 commit gate,
	// synthesizes a minimal report.
	RoutingNoReportButTestsCreated
	// RoutingNoReportNoTests — TESTER_REPORT.md missing AND no test
	// files appear in git diff. Bash branch:
	// stages/tester_validation.sh:47-50.
	RoutingNoReportNoTests
)

// String returns the bash-style name for the routing kind, used in tests
// and in the resume-message body.
func (r RoutingKind) String() string {
	switch r {
	case RoutingClean:
		return "clean"
	case RoutingCompilationErrors:
		return "compilation_errors"
	case RoutingTestFailures:
		return "test_failures"
	case RoutingPartialRun:
		return "partial_run"
	case RoutingNoReportButTestsCreated:
		return "no_report_but_tests_created"
	case RoutingNoReportNoTests:
		return "no_report_no_tests"
	default:
		return fmt.Sprintf("unknown(%d)", int(r))
	}
}

// ValidationDecision is what ValidateOutput returns to the caller. The
// caller (m38.6 tester RunStage) consumes it to drive the next step:
// resume save, fix dispatch, or clean exit.
type ValidationDecision struct {
	Routing           RoutingKind
	Remaining         int
	CompilationPaths  []string
	SynthesizedReport string
	ResumeMessage     string
}

// Request carries the inputs ValidateOutput needs from the surrounding
// tester stage. Minimal field set in m38.1 — m38.6 will extend this as
// the main stage port consumes more fields. Path fields may be relative
// or absolute; relative paths are resolved against ProjectDir.
type Request struct {
	ProjectDir       string
	TekhtonDir       string
	TesterReportFile string
	LogFile          string
	Task             string
}

// AgentResult is a placeholder for the m38.6 main-stage agent envelope.
// ValidateOutput does not consume any fields in m38.1; the parameter is
// kept on the signature so m38.2-m38.6 can extend it without changing
// every call site.
type AgentResult struct{}

// CommitGateTripper is the seam ValidateOutput uses to trip the #46
// commit gate when the tester produced no report but created test files.
// The default implementation writes the .final_check_result sentinel
// directly. Tests override the package-level commitGateTripper to assert
// the call.
type CommitGateTripper interface {
	TripCommitGate(ctx context.Context, projectDir, tekhtonDir, reason string) error
}

// GitDiffRunner is the seam ValidateOutput uses to inspect the working
// tree for test file mutations when the report is missing. The default
// shells out to git; tests inject a fake to drive the
// NoReportButTestsCreated branch.
type GitDiffRunner interface {
	NameOnlyAgainstHEAD(ctx context.Context, projectDir string) ([]string, error)
}

var (
	commitGateTripper CommitGateTripper = defaultCommitGateTripper{}
	gitDiffRunner     GitDiffRunner     = defaultGitDiffRunner{}
)

// SetCommitGateTripper overrides the package commit-gate seam. Returns the
// previous value so callers can restore it after a test.
func SetCommitGateTripper(t CommitGateTripper) (prev CommitGateTripper) {
	prev = commitGateTripper
	commitGateTripper = t
	return prev
}

// SetGitDiffRunner overrides the package git-diff seam. Returns the
// previous value so callers can restore it after a test.
func SetGitDiffRunner(g GitDiffRunner) (prev GitDiffRunner) {
	prev = gitDiffRunner
	gitDiffRunner = g
	return prev
}

// ValidateOutput is the byte-equivalent port of
// stages/tester_validation.sh::_validate_tester_output. It inspects the
// tester report and log file and returns the routing decision. The
// CompilationErrors branch additionally rewrites the report on disk via
// atomic tmp + rename — read-into-memory, flip [x]→[ ] for affected test
// file basenames, atomic write back. NoReportButTestsCreated trips the
// commit gate AND populates SynthesizedReport with the byte-equivalent
// fallback body.
func ValidateOutput(ctx context.Context, req *Request, _ *AgentResult) ValidationDecision {
	if req == nil {
		return ValidationDecision{Routing: RoutingNoReportNoTests}
	}
	reportPath := resolveProjectPath(req.ProjectDir, req.TesterReportFile)
	logPath := resolveProjectPath(req.ProjectDir, req.LogFile)

	if !pathExists(reportPath) {
		return validateMissingReport(ctx, req, reportPath)
	}

	if hasCompilationFailures(logPath) {
		return validateCompilationErrors(req, reportPath, logPath)
	}
	if hasTestFailureSummary(logPath) {
		return validateTestFailures(req)
	}

	remaining := countRemaining(reportPath)
	if remaining > 0 {
		return ValidationDecision{
			Routing:       RoutingPartialRun,
			Remaining:     remaining,
			ResumeMessage: fmt.Sprintf("%d test(s) remaining — %s has the checklist", remaining, req.TesterReportFile),
		}
	}
	return ValidationDecision{Routing: RoutingClean}
}

// validateMissingReport routes the "report missing" pair of bash branches.
// When the working tree shows test/spec mutations, this trips the commit
// gate and synthesizes a fallback report body.
func validateMissingReport(ctx context.Context, req *Request, reportPath string) ValidationDecision {
	testFiles := changedTestFiles(ctx, req.ProjectDir)
	if len(testFiles) == 0 {
		return ValidationDecision{
			Routing:       RoutingNoReportNoTests,
			ResumeMessage: fmt.Sprintf("Re-run with: --start-at test %q", req.Task),
		}
	}
	// Trip the #46 commit gate. The Watch For section calls this out as the
	// M23/M28 regression — without the gate, the pipeline rubber-stamps a
	// milestone-complete commit even though the tester never confirmed what
	// it tested.
	tekhtonDir := req.TekhtonDir
	if tekhtonDir == "" {
		tekhtonDir = ".tekhton"
	}
	_ = commitGateTripper.TripCommitGate(ctx, req.ProjectDir, tekhtonDir, "tester_did_not_produce_report")
	body := synthesizeFallbackReport(req.TesterReportFile, testFiles)
	if err := atomicWriteFile(reportPath, []byte(body)); err != nil {
		// Best-effort — still surface the routing so the caller knows the
		// report was synthesized in memory even when the on-disk write
		// failed.
		_ = err
	}
	return ValidationDecision{
		Routing:           RoutingNoReportButTestsCreated,
		SynthesizedReport: body,
		ResumeMessage:     fmt.Sprintf("Tester created %d test file(s) but no report — synthesized %s.", len(testFiles), req.TesterReportFile),
	}
}

// validateCompilationErrors collects the failed test paths from the log,
// flips matching [x] checkboxes in the report back to [ ], writes the
// report atomically, and returns the routing decision.
func validateCompilationErrors(req *Request, reportPath, logPath string) ValidationDecision {
	failedPaths := compilationFailedPaths(logPath)
	if len(failedPaths) > 0 {
		failedBasenames := basenameSet(failedPaths)
		if data, err := os.ReadFile(reportPath); err == nil {
			modified := flipFailedCheckboxes(string(data), failedBasenames)
			if modified != string(data) {
				_ = atomicWriteFile(reportPath, []byte(modified))
			}
		}
	}
	return ValidationDecision{
		Routing:          RoutingCompilationErrors,
		CompilationPaths: failedPaths,
		ResumeMessage:    fmt.Sprintf("Fix the failing test files, then resume with: --start-at tester %q", req.Task),
	}
}

// validateTestFailures returns the routing decision for the test-failure
// branch. The downstream caller (m38.3 tester_fix) dispatches the inline
// fix agent when TESTER_FIX_ENABLED is set.
func validateTestFailures(req *Request) ValidationDecision {
	return ValidationDecision{
		Routing:       RoutingTestFailures,
		ResumeMessage: fmt.Sprintf("Resume with: --start-at tester %q", req.Task),
	}
}

// hasCompilationFailures mirrors the bash:
//
//	grep -q "Compilation failed" "$LOG_FILE" || grep -q "Failed to load" "$LOG_FILE"
func hasCompilationFailures(logPath string) bool {
	if logPath == "" {
		return false
	}
	return logContains(logPath, []string{"Compilation failed", "Failed to load"})
}

// hasTestFailureSummary matches the negative-number test-failure summary
// regexes used at stages/tester_validation.sh:74. The two regex shapes are
// preserved exactly: `^\s+-[0-9]+:` and ` -[1-9][0-9]*:`. These were
// tuned against real test-framework output (pytest's `-1: ...` style) —
// do not relax them without retro-testing against the original fixtures.
var (
	negFailureRe1 = regexp.MustCompile(`^\s+-[0-9]+:`)
	negFailureRe2 = regexp.MustCompile(` -[1-9][0-9]*:`)
)

func hasTestFailureSummary(logPath string) bool {
	if logPath == "" {
		return false
	}
	f, err := os.Open(logPath)
	if err != nil {
		return false
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1<<16), 1<<24)
	for scanner.Scan() {
		line := scanner.Text()
		if negFailureRe1.MatchString(line) {
			return true
		}
		if negFailureRe2.MatchString(line) {
			return true
		}
	}
	return false
}

// compilationFailedPaths extracts "Compilation failed for testPath=PATH:..."
// from the log and returns the unique sorted PATH set. Mirrors the bash:
//
//	grep "Compilation failed for testPath=" "$LOG_FILE" \
//	  | sed 's/.*testPath=//' | sed 's/:.*//' | sort -u
var compilationPathRe = regexp.MustCompile(`Compilation failed for testPath=([^:]+):`)

func compilationFailedPaths(logPath string) []string {
	if logPath == "" {
		return nil
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		return nil
	}
	seen := map[string]struct{}{}
	for _, m := range compilationPathRe.FindAllStringSubmatch(string(data), -1) {
		if len(m) >= 2 {
			seen[strings.TrimSpace(m[1])] = struct{}{}
		}
	}
	out := make([]string, 0, len(seen))
	for p := range seen {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// changedTestFiles is the seam-backed git diff walker. Mirrors:
//
//	git diff --name-only HEAD | grep -ciE 'test|spec'
//
// with the difference that we return the matched filenames rather than
// just the count, so the synthesized report can list them.
var testOrSpecRe = regexp.MustCompile(`(?i)test|spec`)

func changedTestFiles(ctx context.Context, projectDir string) []string {
	files, err := gitDiffRunner.NameOnlyAgainstHEAD(ctx, projectDir)
	if err != nil {
		return nil
	}
	var out []string
	for _, f := range files {
		if testOrSpecRe.MatchString(f) {
			out = append(out, f)
		}
	}
	return out
}

// countRemaining counts unchecked checklist items in the tester report:
// `^- \[ \]` at start of line. Mirrors:
//
//	grep -c "^- \[ \]" "$TESTER_REPORT_FILE"
func countRemaining(reportPath string) int {
	f, err := os.Open(reportPath)
	if err != nil {
		return 0
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1<<16), 1<<24)
	count := 0
	for scanner.Scan() {
		if strings.HasPrefix(scanner.Text(), "- [ ]") {
			count++
		}
	}
	return count
}

// flipFailedCheckboxes is the in-memory port of the destructive sed
// rewrite at stages/tester_validation.sh:71. For each failed basename
// (extracted from the log), find lines whose pattern matches:
//
//	[x] `...BASENAME...`
//
// and replace with:
//
//   - [ ] `BASENAME` — COMPILATION FAILED: re-read source models before rewriting
//
// The bash uses `sed -i` with a shell-glob-ish regex. We mirror the
// semantics: any line that contains both "[x] `" and BASENAME between
// backticks is treated as a match.
func flipFailedCheckboxes(report string, failedBasenames map[string]struct{}) string {
	if len(failedBasenames) == 0 {
		return report
	}
	lines := strings.Split(report, "\n")
	for i, line := range lines {
		if !strings.Contains(line, "[x] `") {
			continue
		}
		for base := range failedBasenames {
			if strings.Contains(line, base) {
				lines[i] = fmt.Sprintf("- [ ] `%s` — COMPILATION FAILED: re-read source models before rewriting", base)
				break
			}
		}
	}
	return strings.Join(lines, "\n")
}

// synthesizeFallbackReport mirrors the bash heredoc at
// stages/tester_validation.sh:36-46. testFiles are bullet-rendered as
// `- [x] \`PATH\“ per the bash `sed 's/^/- [x] \`/' | sed 's/$/\`/'`
// pipeline.
func synthesizeFallbackReport(reportFile string, testFiles []string) string {
	files := testFiles
	if len(files) > 20 {
		files = files[:20]
	}
	var bullets strings.Builder
	for _, f := range files {
		bullets.WriteString("- [x] `")
		bullets.WriteString(f)
		bullets.WriteString("`\n")
	}
	body := fmt.Sprintf(`## Test Summary
%s was synthesized by the pipeline. The tester agent created
test files but did not produce a report. Review the test files directly.

## Test Files Created
%s
## Bugs Found
None
`, reportFile, bullets.String())
	return body
}

// logContains scans logPath line-by-line and returns true on the first
// occurrence of any needle. The needle list is small; a fixed-string
// pass beats compiling a regex.
func logContains(logPath string, needles []string) bool {
	f, err := os.Open(logPath)
	if err != nil {
		return false
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1<<16), 1<<24)
	for scanner.Scan() {
		line := scanner.Text()
		for _, n := range needles {
			if strings.Contains(line, n) {
				return true
			}
		}
	}
	return false
}

// basenameSet returns the set of path basenames for use by
// flipFailedCheckboxes. Empty input returns an empty map.
func basenameSet(paths []string) map[string]struct{} {
	out := make(map[string]struct{}, len(paths))
	for _, p := range paths {
		out[filepath.Base(p)] = struct{}{}
	}
	return out
}

// resolveProjectPath joins relative paths under projectDir. Absolute
// paths are returned unchanged.
func resolveProjectPath(projectDir, path string) string {
	if path == "" || filepath.IsAbs(path) {
		return path
	}
	if projectDir == "" {
		return path
	}
	return filepath.Join(projectDir, path)
}

// pathExists is the m38.1 helper for `[ -f "$path" ]`.
func pathExists(path string) bool {
	if path == "" {
		return false
	}
	fi, err := os.Stat(path)
	if err != nil {
		return false
	}
	return !fi.IsDir()
}

// atomicWriteFile writes data to path via tmpfile + rename — the
// project convention for report files that may be read concurrently by
// the dashboard, the resume detector, etc. Matches the
// internal/test_baseline atomic-write pattern called out in the m38.1
// Watch For section.
func atomicWriteFile(path string, data []byte) error {
	if path == "" {
		return errors.New("atomic write: empty path")
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tester-report-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, path)
}

// defaultCommitGateTripper writes the .final_check_result sentinel
// directly, mirroring lib/common.sh::trip_commit_gate. The reason is
// idempotent — the first reason wins (the bash version checks for an
// existing non-empty sentinel before writing).
type defaultCommitGateTripper struct{}

func (defaultCommitGateTripper) TripCommitGate(_ context.Context, projectDir, tekhtonDir, reason string) error {
	if reason == "" {
		reason = "synthesize_fallback"
	}
	if tekhtonDir == "" {
		tekhtonDir = ".tekhton"
	}
	sentinel := filepath.Join(tekhtonDir, ".final_check_result")
	if !filepath.IsAbs(sentinel) && projectDir != "" {
		sentinel = filepath.Join(projectDir, sentinel)
	}
	if err := os.MkdirAll(filepath.Dir(sentinel), 0o755); err != nil {
		return err
	}
	if fi, err := os.Stat(sentinel); err == nil && fi.Size() > 0 {
		return nil
	}
	body := fmt.Sprintf("1\n# %s\n", reason)
	return os.WriteFile(sentinel, []byte(body), 0o644)
}

// defaultGitDiffRunner shells out to git from the project directory.
// Tests substitute a fake so the suite never depends on a configured
// git binary or a real working tree.
type defaultGitDiffRunner struct{}

func (defaultGitDiffRunner) NameOnlyAgainstHEAD(ctx context.Context, projectDir string) ([]string, error) {
	cmd := exec.CommandContext(ctx, "git", "diff", "--name-only", "HEAD")
	if projectDir != "" {
		cmd.Dir = projectDir
	}
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	var files []string
	for _, line := range strings.Split(string(out), "\n") {
		trim := strings.TrimSpace(line)
		if trim != "" {
			files = append(files, trim)
		}
	}
	return files, nil
}
