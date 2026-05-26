package notes

import (
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

// AcceptanceResult is the bundle of warnings + status code emitted by
// RunAcceptance. Mirrors the bash function `run_note_acceptance` from
// lib/notes_acceptance.sh, including the warning-code string the
// finalize chain stores back to note metadata.
type AcceptanceResult struct {
	// Tag is the tag the acceptance run was scoped to (BUG / FEAT /
	// POLISH). Empty when called for an unrecognised tag — the result
	// is a no-op pass in that case.
	Tag string
	// Code is `pass` when no warnings were raised; otherwise a
	// comma-separated list of warning codes (e.g. `warn_no_test,warn_no_rca`).
	Code string
	// Warnings is the per-warning human-readable text. One entry per
	// code, suitable for appending to CODER_SUMMARY.md or logging.
	Warnings []string
}

// AcceptanceOptions configures the acceptance checks. The git/file
// boundaries are exposed for testability; production callers pass an
// empty struct (defaults map to the bash globals).
type AcceptanceOptions struct {
	// ProjectDir scopes git invocations to the target repo. Defaults
	// to the current working directory.
	ProjectDir string
	// CoderSummaryFile overrides the location of CODER_SUMMARY.md.
	// Defaults to .tekhton/CODER_SUMMARY.md under ProjectDir.
	CoderSummaryFile string
	// PolishLogicPatterns overrides the file-extension patterns used
	// to decide whether a POLISH note modified a "logic" file. The
	// bash equivalent reads POLISH_LOGIC_FILE_PATTERNS from
	// pipeline.conf.
	PolishLogicPatterns []string
}

// RunAcceptance evaluates tag-specific acceptance heuristics. Returns a
// pass result for tags that have no heuristics (or empty tag). Mirrors
// `run_note_acceptance` from lib/notes_acceptance.sh, including the
// warning-code formatting used downstream by the metadata store.
//
// The bash version exported NOTE_ACCEPTANCE_RESULT/NOTE_ACCEPTANCE_WARNINGS
// for dashboard consumption — that side effect moves into the
// finalize hook (note_acceptance.go) which wraps RunAcceptance.
func RunAcceptance(ctx context.Context, tag string, opts AcceptanceOptions) (AcceptanceResult, error) {
	res := AcceptanceResult{Tag: tag, Code: "pass"}
	if opts.ProjectDir == "" {
		opts.ProjectDir, _ = os.Getwd()
	}
	if opts.CoderSummaryFile == "" {
		opts.CoderSummaryFile = filepath.Join(opts.ProjectDir, ".tekhton", "CODER_SUMMARY.md")
	}
	switch tag {
	case "BUG":
		warns, err := checkBugAcceptance(ctx, opts)
		if err != nil {
			return res, err
		}
		res = composeAcceptance(tag, warns)
	case "FEAT":
		warns, err := checkFeatAcceptance(ctx, opts)
		if err != nil {
			return res, err
		}
		res = composeAcceptance(tag, warns)
	case "POLISH":
		warns, err := checkPolishAcceptance(ctx, opts)
		if err != nil {
			return res, err
		}
		res = composeAcceptance(tag, warns)
	default:
		// Unknown tag → no-op pass (matches bash default branch).
	}
	return res, nil
}

// acceptanceWarning is the parsed warning the heuristics emit. The bash
// version concatenated `code: message` strings; the Go version keeps
// them separated so the formatter can choose the join character.
type acceptanceWarning struct {
	Code    string
	Message string
}

func composeAcceptance(tag string, warns []acceptanceWarning) AcceptanceResult {
	res := AcceptanceResult{Tag: tag}
	if len(warns) == 0 {
		res.Code = "pass"
		return res
	}
	codes := make([]string, 0, len(warns))
	msgs := make([]string, 0, len(warns))
	for _, w := range warns {
		codes = append(codes, w.Code)
		msgs = append(msgs, w.Message)
	}
	res.Code = strings.Join(codes, ",")
	res.Warnings = msgs
	return res
}

// testFileRE matches paths that look like test files. The bash regex
// (`(test[_/]|_test\.|\.test\.|\.spec\.|tests/|spec/)`) ports here.
var testFileRE = regexp.MustCompile(`(?i)(test[_/]|_test\.|\.test\.|\.spec\.|tests/|spec/)`)

// rootCauseRE matches the heading the BUG acceptance check looks for
// inside CODER_SUMMARY.md (case-insensitive, mirrors `grep -qi`).
var rootCauseRE = regexp.MustCompile(`(?i)^##\s+Root Cause`)

// checkBugAcceptance ports `check_bug_acceptance`. Returns warnings
// (not errors) — the heuristics never fail in the "test exited
// non-zero" sense.
func checkBugAcceptance(ctx context.Context, opts AcceptanceOptions) ([]acceptanceWarning, error) {
	var warns []acceptanceWarning

	changed, err := gitChangedFiles(ctx, opts.ProjectDir)
	if err != nil {
		return nil, fmt.Errorf("notes: bug acceptance git: %w", err)
	}
	untracked, err := gitUntrackedFiles(ctx, opts.ProjectDir)
	if err != nil {
		return nil, fmt.Errorf("notes: bug acceptance git ls-files: %w", err)
	}
	testTouched := false
	for _, f := range changed {
		if testFileRE.MatchString(f) {
			testTouched = true
			break
		}
	}
	if !testTouched {
		for _, f := range untracked {
			if testFileRE.MatchString(f) {
				testTouched = true
				break
			}
		}
	}
	if !testTouched {
		warns = append(warns, acceptanceWarning{
			Code:    "warn_no_test",
			Message: "Bug fix has no regression test coverage. Consider adding a test that reproduces the original bug.",
		})
	}

	// Root-cause analysis check (CODER_SUMMARY.md).
	if data, err := os.ReadFile(opts.CoderSummaryFile); err == nil {
		if !rootCauseRE.MatchString(string(data)) {
			warns = append(warns, acceptanceWarning{
				Code:    "warn_no_rca",
				Message: "No root cause analysis provided. Future debugging may repeat the same investigation.",
			})
		}
	}
	return warns, nil
}

// checkFeatAcceptance is the FEAT heuristics port. The bash version
// inspected new files against a "common directories" set built from
// `git ls-files | sort | uniq -c | head -20`. The Go port preserves
// the same shape — minus the awk pipeline — by using maps directly.
func checkFeatAcceptance(ctx context.Context, opts AcceptanceOptions) ([]acceptanceWarning, error) {
	var warns []acceptanceWarning

	untracked, err := gitUntrackedFiles(ctx, opts.ProjectDir)
	if err != nil {
		return nil, fmt.Errorf("notes: feat acceptance untracked: %w", err)
	}
	stagedNew, err := gitStagedNewFiles(ctx, opts.ProjectDir)
	if err != nil {
		return nil, fmt.Errorf("notes: feat acceptance staged: %w", err)
	}
	newFiles := dedupe(append(untracked, stagedNew...))
	if len(newFiles) == 0 {
		return warns, nil
	}

	all, err := gitAllFiles(ctx, opts.ProjectDir)
	if err != nil {
		return nil, fmt.Errorf("notes: feat acceptance ls-files: %w", err)
	}
	if len(all) == 0 {
		return warns, nil
	}
	commonDirs := topNDirs(all, 20)
	commonSet := make(map[string]struct{}, len(commonDirs))
	for _, d := range commonDirs {
		commonSet[d] = struct{}{}
	}

	for _, f := range newFiles {
		dir := filepath.Dir(f)
		if dir == "." {
			continue
		}
		if testFileRE.MatchString(f) {
			continue
		}
		if _, ok := commonSet[dir]; ok {
			continue
		}
		// Try to suggest a sibling under the same parent.
		parent := filepath.Dir(dir)
		if parent == "." {
			continue
		}
		var suggestion string
		for _, d := range commonDirs {
			if strings.HasPrefix(d, parent) && d != dir {
				suggestion = d
				break
			}
		}
		if suggestion == "" {
			continue
		}
		warns = append(warns, acceptanceWarning{
			Code: "warn_file_placement",
			Message: fmt.Sprintf(
				"New file '%s' may not follow project conventions. Expected location: %s/",
				f, suggestion,
			),
		})
	}
	return warns, nil
}

// defaultPolishLogicPatterns mirrors the bash POLISH_LOGIC_FILE_PATTERNS
// default. Extensions are stored without the leading `*`.
var defaultPolishLogicPatterns = []string{".py", ".js", ".ts", ".sh", ".go", ".rs", ".java", ".rb", ".c", ".cpp", ".h"}

// checkPolishAcceptance ports `check_polish_acceptance`.
func checkPolishAcceptance(ctx context.Context, opts AcceptanceOptions) ([]acceptanceWarning, error) {
	patterns := opts.PolishLogicPatterns
	if len(patterns) == 0 {
		patterns = defaultPolishLogicPatterns
	}
	changed, err := gitChangedFiles(ctx, opts.ProjectDir)
	if err != nil {
		return nil, fmt.Errorf("notes: polish acceptance git: %w", err)
	}
	staged, err := gitStagedFiles(ctx, opts.ProjectDir)
	if err != nil {
		return nil, fmt.Errorf("notes: polish acceptance staged: %w", err)
	}
	all := dedupe(append(changed, staged...))

	var logicFiles []string
	for _, f := range all {
		for _, ext := range patterns {
			if strings.HasSuffix(f, ext) {
				if testFileRE.MatchString(f) {
					break
				}
				logicFiles = append(logicFiles, f)
				break
			}
		}
	}
	logicFiles = dedupe(logicFiles)
	if len(logicFiles) == 0 {
		return nil, nil
	}
	sort.Strings(logicFiles)
	msg := fmt.Sprintf(
		"Polish note modified logic files: %s. This may indicate scope creep beyond the visual/UX change.",
		strings.Join(logicFiles, ", "),
	)
	return []acceptanceWarning{{Code: "warn_logic_modified", Message: msg}}, nil
}

// gitChangedFiles wraps `git diff --name-only HEAD`. Missing repo and
// "no diff" both produce an empty slice without an error.
func gitChangedFiles(ctx context.Context, dir string) ([]string, error) {
	return runGitNameOnly(ctx, dir, "diff", "--name-only", "HEAD")
}

func gitStagedFiles(ctx context.Context, dir string) ([]string, error) {
	return runGitNameOnly(ctx, dir, "diff", "--cached", "--name-only")
}

func gitStagedNewFiles(ctx context.Context, dir string) ([]string, error) {
	return runGitNameOnly(ctx, dir, "diff", "--cached", "--name-only", "--diff-filter=A")
}

func gitUntrackedFiles(ctx context.Context, dir string) ([]string, error) {
	return runGitNameOnly(ctx, dir, "ls-files", "--others", "--exclude-standard")
}

func gitAllFiles(ctx context.Context, dir string) ([]string, error) {
	return runGitNameOnly(ctx, dir, "ls-files")
}

// runGitNameOnly invokes git, returning each output line as an entry.
// Empty output yields a nil slice. A git binary not found / non-repo
// directory returns an empty slice instead of an error so the
// acceptance heuristics degrade gracefully outside a repo.
func runGitNameOnly(ctx context.Context, dir string, args ...string) ([]string, error) {
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			// git diff returns 0 with no output if there's no change;
			// `git diff --quiet` returns 1 when there is. Since we use
			// --name-only (no --quiet) the only non-zero we expect is
			// "not a repo" — degrade to empty.
			return nil, nil
		}
		// `exec: "git": executable file not found` etc.
		if errors.Is(err, exec.ErrNotFound) {
			return nil, nil
		}
		return nil, err
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) == 1 && lines[0] == "" {
		return nil, nil
	}
	return lines, nil
}

// topNDirs returns the top n most-common parent directories from the
// supplied file list, ordered by descending count. Ports the bash
// `sort | uniq -c | sort -rn | head -20 | awk '{print $2}'` chain.
func topNDirs(files []string, n int) []string {
	counts := map[string]int{}
	for _, f := range files {
		dir := filepath.Dir(f)
		if dir == "." {
			continue
		}
		counts[dir]++
	}
	type kv struct {
		dir string
		n   int
	}
	pairs := make([]kv, 0, len(counts))
	for d, c := range counts {
		pairs = append(pairs, kv{d, c})
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i].n != pairs[j].n {
			return pairs[i].n > pairs[j].n
		}
		return pairs[i].dir < pairs[j].dir
	})
	if n > len(pairs) {
		n = len(pairs)
	}
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, pairs[i].dir)
	}
	return out
}

func dedupe(in []string) []string {
	seen := map[string]struct{}{}
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
