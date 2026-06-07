package tester

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeCommitGate records every TripCommitGate call so tests can assert
// the NoReportButTestsCreated branch wired the call.
type fakeCommitGate struct {
	calls []fakeGateCall
}

type fakeGateCall struct {
	projectDir string
	tekhtonDir string
	reason     string
}

func (f *fakeCommitGate) TripCommitGate(_ context.Context, projectDir, tekhtonDir, reason string) error {
	f.calls = append(f.calls, fakeGateCall{projectDir, tekhtonDir, reason})
	return nil
}

// fakeGitDiff returns the configured list, ignoring the context and dir.
// Returns an error when err != nil so we can also exercise the failure
// path.
type fakeGitDiff struct {
	files []string
	err   error
}

func (f *fakeGitDiff) NameOnlyAgainstHEAD(_ context.Context, _ string) ([]string, error) {
	return f.files, f.err
}

// installSeams swaps both seams for the duration of the test. The
// restore function MUST be deferred — production calls to git or to the
// .final_check_result writer would leak across tests otherwise.
func installSeams(t *testing.T, gate CommitGateTripper, diff GitDiffRunner) func() {
	t.Helper()
	prevGate := SetCommitGateTripper(gate)
	prevDiff := SetGitDiffRunner(diff)
	return func() {
		SetCommitGateTripper(prevGate)
		SetGitDiffRunner(prevDiff)
	}
}

// copyFixture copies an entire fixture directory into a fresh tmpdir so
// the CompilationErrors branch can mutate the report without corrupting
// the testdata tree.
func copyFixture(t *testing.T, fixture string) string {
	t.Helper()
	srcDir := filepath.Join("testdata", "validation", fixture)
	dst := t.TempDir()
	entries, err := os.ReadDir(srcDir)
	if err != nil {
		t.Fatalf("read fixture %s: %v", fixture, err)
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		src, err := os.Open(filepath.Join(srcDir, e.Name()))
		if err != nil {
			t.Fatalf("open %s: %v", e.Name(), err)
		}
		out, err := os.Create(filepath.Join(dst, e.Name()))
		if err != nil {
			src.Close()
			t.Fatalf("create %s: %v", e.Name(), err)
		}
		if _, err := io.Copy(out, src); err != nil {
			src.Close()
			out.Close()
			t.Fatalf("copy %s: %v", e.Name(), err)
		}
		src.Close()
		out.Close()
	}
	return dst
}

func requestFor(dir string) *Request {
	return &Request{
		ProjectDir:       dir,
		TekhtonDir:       ".tekhton",
		TesterReportFile: "TESTER_REPORT.md",
		LogFile:          "LOG_FILE",
		Task:             "test task",
	}
}

func TestValidateOutput_Clean_NoFailuresNoRemaining(t *testing.T) {
	defer installSeams(t, &fakeCommitGate{}, &fakeGitDiff{})()
	dir := copyFixture(t, "clean")
	got := ValidateOutput(context.Background(), requestFor(dir), &AgentResult{})
	if got.Routing != RoutingClean {
		t.Fatalf("clean fixture: want Routing=Clean (%s), got %s", RoutingClean, got.Routing)
	}
	if got.Remaining != 0 {
		t.Fatalf("clean fixture: want Remaining=0, got %d", got.Remaining)
	}
	if got.SynthesizedReport != "" {
		t.Fatalf("clean fixture: SynthesizedReport must be empty, got %q", got.SynthesizedReport)
	}
}

func TestValidateOutput_PartialRun_CountsUncheckedItems(t *testing.T) {
	defer installSeams(t, &fakeCommitGate{}, &fakeGitDiff{})()
	dir := copyFixture(t, "partial")
	got := ValidateOutput(context.Background(), requestFor(dir), &AgentResult{})
	if got.Routing != RoutingPartialRun {
		t.Fatalf("partial fixture: want Routing=PartialRun (%s), got %s", RoutingPartialRun, got.Routing)
	}
	if got.Remaining != 2 {
		t.Fatalf("partial fixture: want Remaining=2, got %d", got.Remaining)
	}
	if !strings.Contains(got.ResumeMessage, "TESTER_REPORT.md") {
		t.Fatalf("partial fixture: ResumeMessage must mention the report file, got %q", got.ResumeMessage)
	}
}

func TestValidateOutput_CompilationErrors_FlipsCheckboxesAndAtomicWrites(t *testing.T) {
	defer installSeams(t, &fakeCommitGate{}, &fakeGitDiff{})()
	dir := copyFixture(t, "compilation-errors")
	req := requestFor(dir)
	got := ValidateOutput(context.Background(), req, &AgentResult{})
	if got.Routing != RoutingCompilationErrors {
		t.Fatalf("compilation fixture: want Routing=CompilationErrors (%s), got %s", RoutingCompilationErrors, got.Routing)
	}
	if len(got.CompilationPaths) != 1 || !strings.HasSuffix(got.CompilationPaths[0], "broken_test.go") {
		t.Fatalf("compilation fixture: want single path ending in broken_test.go, got %v", got.CompilationPaths)
	}
	// Verify the report on disk got the [x] flipped to [ ] for the
	// failed basename. The clean test_other line must remain [x].
	body, err := os.ReadFile(filepath.Join(dir, "TESTER_REPORT.md"))
	if err != nil {
		t.Fatalf("read report: %v", err)
	}
	bodyStr := string(body)
	if !strings.Contains(bodyStr, "- [ ] `broken_test.go` — COMPILATION FAILED:") {
		t.Fatalf("compilation fixture: broken_test.go must be flipped to unchecked with COMPILATION FAILED suffix; got body:\n%s", bodyStr)
	}
	if !strings.Contains(bodyStr, "- [x] `foo_test.go`") {
		t.Fatalf("compilation fixture: foo_test.go must remain [x] (was not in failed set); got body:\n%s", bodyStr)
	}
	if !strings.Contains(bodyStr, "- [x] `other_test.go`") {
		t.Fatalf("compilation fixture: other_test.go must remain [x] (was not in failed set); got body:\n%s", bodyStr)
	}
}

func TestValidateOutput_TestFailures_TriggersTestFailuresRouting(t *testing.T) {
	defer installSeams(t, &fakeCommitGate{}, &fakeGitDiff{})()
	dir := copyFixture(t, "test-failures")
	got := ValidateOutput(context.Background(), requestFor(dir), &AgentResult{})
	if got.Routing != RoutingTestFailures {
		t.Fatalf("test-failures fixture: want Routing=TestFailures (%s), got %s", RoutingTestFailures, got.Routing)
	}
}

func TestValidateOutput_NoReportButTestsCreated_TripsCommitGate(t *testing.T) {
	gate := &fakeCommitGate{}
	diff := &fakeGitDiff{files: []string{"internal/foo/foo_test.go", "internal/bar/bar_spec.py", "README.md"}}
	defer installSeams(t, gate, diff)()

	dir := copyFixture(t, "no-report-with-tests")
	req := requestFor(dir)
	got := ValidateOutput(context.Background(), req, &AgentResult{})
	if got.Routing != RoutingNoReportButTestsCreated {
		t.Fatalf("no-report-with-tests fixture: want Routing=NoReportButTestsCreated (%s), got %s", RoutingNoReportButTestsCreated, got.Routing)
	}
	if len(gate.calls) != 1 {
		t.Fatalf("commit gate must be tripped exactly once; got %d calls", len(gate.calls))
	}
	if gate.calls[0].reason != "tester_did_not_produce_report" {
		t.Fatalf("commit gate reason must be 'tester_did_not_produce_report'; got %q", gate.calls[0].reason)
	}
	if gate.calls[0].projectDir != dir {
		t.Fatalf("commit gate projectDir wrong: want %q, got %q", dir, gate.calls[0].projectDir)
	}
	// Body must include the synthesized fallback report — bash heredoc parity.
	if !strings.Contains(got.SynthesizedReport, "## Test Summary") {
		t.Fatalf("synthesized report missing ## Test Summary header; got:\n%s", got.SynthesizedReport)
	}
	if !strings.Contains(got.SynthesizedReport, "## Bugs Found\nNone") {
		t.Fatalf("synthesized report missing ## Bugs Found block; got:\n%s", got.SynthesizedReport)
	}
	if !strings.Contains(got.SynthesizedReport, "- [x] `internal/foo/foo_test.go`") {
		t.Fatalf("synthesized report missing the test file bullet; got:\n%s", got.SynthesizedReport)
	}
	if !strings.Contains(got.SynthesizedReport, "- [x] `internal/bar/bar_spec.py`") {
		t.Fatalf("synthesized report missing the spec file bullet; got:\n%s", got.SynthesizedReport)
	}
	if strings.Contains(got.SynthesizedReport, "README.md") {
		t.Fatalf("synthesized report must not include non-test files; got:\n%s", got.SynthesizedReport)
	}
	// File on disk must reflect the synthesized body via atomic write.
	body, err := os.ReadFile(filepath.Join(dir, "TESTER_REPORT.md"))
	if err != nil {
		t.Fatalf("read synthesized report: %v", err)
	}
	if string(body) != got.SynthesizedReport {
		t.Fatalf("on-disk synthesized report must match in-memory body byte-for-byte")
	}
}

func TestValidateOutput_NoReportNoTests_NoGateTrip(t *testing.T) {
	gate := &fakeCommitGate{}
	diff := &fakeGitDiff{files: []string{"README.md", "CHANGELOG.md"}}
	defer installSeams(t, gate, diff)()

	dir := copyFixture(t, "no-report-no-tests")
	got := ValidateOutput(context.Background(), requestFor(dir), &AgentResult{})
	if got.Routing != RoutingNoReportNoTests {
		t.Fatalf("no-report-no-tests fixture: want Routing=NoReportNoTests (%s), got %s", RoutingNoReportNoTests, got.Routing)
	}
	if len(gate.calls) != 0 {
		t.Fatalf("commit gate must NOT be tripped on this branch; got %d calls", len(gate.calls))
	}
}

func TestValidateOutput_NilRequest_ReturnsNoReportNoTests(t *testing.T) {
	got := ValidateOutput(context.Background(), nil, &AgentResult{})
	if got.Routing != RoutingNoReportNoTests {
		t.Fatalf("nil request: want NoReportNoTests, got %s", got.Routing)
	}
}

func TestValidateOutput_GitDiffError_TreatedAsNoTests(t *testing.T) {
	// When git fails (e.g., not a repo), the bash version's
	// `2>/dev/null` swallows the error and treats it as zero test files.
	// The Go port must do the same.
	defer installSeams(t, &fakeCommitGate{}, &fakeGitDiff{err: io.EOF})()
	dir := copyFixture(t, "no-report-with-tests")
	got := ValidateOutput(context.Background(), requestFor(dir), &AgentResult{})
	if got.Routing != RoutingNoReportNoTests {
		t.Fatalf("git diff error: want NoReportNoTests, got %s", got.Routing)
	}
}

func TestRoutingKind_StringNamesAreStable(t *testing.T) {
	cases := []struct {
		k    RoutingKind
		want string
	}{
		{RoutingClean, "clean"},
		{RoutingCompilationErrors, "compilation_errors"},
		{RoutingTestFailures, "test_failures"},
		{RoutingPartialRun, "partial_run"},
		{RoutingNoReportButTestsCreated, "no_report_but_tests_created"},
		{RoutingNoReportNoTests, "no_report_no_tests"},
	}
	for _, c := range cases {
		if c.k.String() != c.want {
			t.Errorf("RoutingKind(%d).String() = %q, want %q", c.k, c.k.String(), c.want)
		}
	}
	// All six enum values are exercised above; the unknown-default arm
	// is the only remaining branch.
	if got := RoutingKind(99).String(); got != "unknown(99)" {
		t.Errorf("unknown kind: want unknown(99), got %q", got)
	}
}

func TestFlipFailedCheckboxes_PassthroughOnEmptySet(t *testing.T) {
	body := "- [x] `foo.go`\n- [x] `bar.go`\n"
	got := flipFailedCheckboxes(body, nil)
	if got != body {
		t.Fatalf("empty set must return body verbatim")
	}
}

func TestFlipFailedCheckboxes_StopsAtFirstMatchPerLine(t *testing.T) {
	body := "- [x] `broken_test.go`\n"
	set := map[string]struct{}{"broken_test.go": {}}
	got := flipFailedCheckboxes(body, set)
	want := "- [ ] `broken_test.go` — COMPILATION FAILED: re-read source models before rewriting\n"
	if got != want {
		t.Fatalf("flip mismatch:\nwant: %q\ngot:  %q", want, got)
	}
}

func TestAtomicWriteFile_CreatesDirIfMissing(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "sub", "report.md")
	if err := atomicWriteFile(target, []byte("hello")); err != nil {
		t.Fatalf("atomic write: %v", err)
	}
	data, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("readback: %v", err)
	}
	if string(data) != "hello" {
		t.Fatalf("atomic write content mismatch: %q", data)
	}
}

func TestAtomicWriteFile_EmptyPathErrors(t *testing.T) {
	if err := atomicWriteFile("", []byte("x")); err == nil {
		t.Fatal("atomic write must reject empty path")
	}
}

func TestResolveProjectPath_Cases(t *testing.T) {
	cases := []struct {
		name       string
		projectDir string
		path       string
		want       string
	}{
		{"empty path", "/proj", "", ""},
		{"absolute path stays absolute", "/proj", "/etc/foo", "/etc/foo"},
		{"relative joined under project", "/proj", "report.md", "/proj/report.md"},
		{"relative without project dir", "", "report.md", "report.md"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := resolveProjectPath(c.projectDir, c.path)
			if got != c.want {
				t.Fatalf("resolveProjectPath(%q,%q): want %q, got %q", c.projectDir, c.path, c.want, got)
			}
		})
	}
}

func TestDefaultCommitGateTripper_WritesSentinel(t *testing.T) {
	dir := t.TempDir()
	tr := defaultCommitGateTripper{}
	if err := tr.TripCommitGate(context.Background(), dir, ".tekhton", "tester_did_not_produce_report"); err != nil {
		t.Fatalf("trip: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(dir, ".tekhton", ".final_check_result"))
	if err != nil {
		t.Fatalf("read sentinel: %v", err)
	}
	if !strings.Contains(string(body), "tester_did_not_produce_report") {
		t.Fatalf("sentinel body missing reason; got %q", body)
	}
	// Idempotent: second call with a different reason must NOT overwrite.
	if err := tr.TripCommitGate(context.Background(), dir, ".tekhton", "other_reason"); err != nil {
		t.Fatalf("second trip: %v", err)
	}
	body2, err := os.ReadFile(filepath.Join(dir, ".tekhton", ".final_check_result"))
	if err != nil {
		t.Fatalf("read sentinel after second trip: %v", err)
	}
	if string(body2) != string(body) {
		t.Fatalf("sentinel must be idempotent; original=%q updated=%q", body, body2)
	}
}

func TestDefaultCommitGateTripper_DefaultsReasonAndDir(t *testing.T) {
	dir := t.TempDir()
	tr := defaultCommitGateTripper{}
	if err := tr.TripCommitGate(context.Background(), dir, "", ""); err != nil {
		t.Fatalf("trip with defaults: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(dir, ".tekhton", ".final_check_result"))
	if err != nil {
		t.Fatalf("read sentinel: %v", err)
	}
	if !strings.Contains(string(body), "synthesize_fallback") {
		t.Fatalf("default reason must be synthesize_fallback; got %q", body)
	}
}

func TestCountRemaining_MissingFileReturnsZero(t *testing.T) {
	if got := countRemaining("/does/not/exist"); got != 0 {
		t.Fatalf("missing file: want 0, got %d", got)
	}
}

func TestHasTestFailureSummary_MatchesNegativeNumberShapes(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log")
	body := "   -1: AssertionError\n some text\n  -5: Failure\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write log: %v", err)
	}
	if !hasTestFailureSummary(path) {
		t.Fatalf("expected negative-number summary lines to match")
	}
}

func TestHasTestFailureSummary_EmptyPathReturnsFalse(t *testing.T) {
	if hasTestFailureSummary("") {
		t.Fatalf("empty path must return false")
	}
}

func TestHasCompilationFailures_EmptyPathReturnsFalse(t *testing.T) {
	if hasCompilationFailures("") {
		t.Fatalf("empty path must return false")
	}
}

func TestCompilationFailedPaths_DedupsAndSorts(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log")
	body := "" +
		"Compilation failed for testPath=zzz/foo.go:1: err\n" +
		"Compilation failed for testPath=aaa/bar.go:2: err\n" +
		"Compilation failed for testPath=aaa/bar.go:3: err\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	got := compilationFailedPaths(path)
	if len(got) != 2 || got[0] != "aaa/bar.go" || got[1] != "zzz/foo.go" {
		t.Fatalf("dedup+sort failed; got %v", got)
	}
}

func TestSynthesizeFallbackReport_TruncatesAt20Files(t *testing.T) {
	// synthesizeFallbackReport caps the bullet list at 20 entries to prevent
	// the synthesized report from being unboundedly large. Verify that when
	// given >20 files only 20 bullets appear and the 21st file is absent.
	files := make([]string, 25)
	for i := range files {
		files[i] = strings.Repeat("x", i+1) + "_test.go"
	}
	body := synthesizeFallbackReport("TESTER_REPORT.md", files)
	count := strings.Count(body, "- [x] `")
	if count != 20 {
		t.Fatalf("expected 20 bullet lines, got %d", count)
	}
	if strings.Contains(body, files[20]) {
		t.Fatalf("21st file must be truncated from synthesized report")
	}
}

func TestPathExists_ReturnsFalseForDirectory(t *testing.T) {
	// pathExists mirrors `[ -f "$path" ]` — a directory must return false so
	// ValidateOutput routes to the "missing report" branches rather than
	// trying to parse a directory as the TESTER_REPORT.md file.
	dir := t.TempDir()
	if pathExists(dir) {
		t.Fatalf("pathExists must return false for a directory path")
	}
}
