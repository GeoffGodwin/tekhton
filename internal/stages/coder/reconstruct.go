package coder

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ReconstructSummary writes a minimal CODER_SUMMARY.md from git state. Called
// when the coder agent did substantive work but failed to produce or
// maintain the summary file. The reviewer assesses actual file changes.
//
// status accepts "COMPLETE", "FAILED", or "INCOMPLETE":
//
//   - COMPLETE  — missing-summary-but-substantive-work (Path A);
//                 continuation-failure fallback (Path C); completion-gate-
//                 failed-substantive-work (Path D).
//   - FAILED    — turn-exhaustion fallback (Path B).
//   - INCOMPLETE — completion-gate-failed-no-work (Path E).
//
// The bash _reconstruct_coder_summary at stages/coder.sh:50-92 reads git
// tracked modifications and untracked new files, writes the skeleton with
// the supplied status, and excludes .claude/logs/ and the session-dir
// basename from untracked files. The Go port preserves these exclusions
// verbatim.
func ReconstructSummary(_ context.Context, path, status string, deps *Deps) error {
	if status == "" {
		status = "COMPLETE"
	}
	if !isValidStatus(status) {
		return fmt.Errorf("reconstruct: unknown status %q", status)
	}
	if path == "" {
		path = ".tekhton/CODER_SUMMARY.md"
	}

	tracked := ""
	if deps != nil && deps.GitTrackedNameOnly != nil {
		t, _ := deps.GitTrackedNameOnly()
		tracked = t
	}
	diffStat := ""
	if deps != nil && deps.GitDiffStat != nil {
		d, _ := deps.GitDiffStat()
		diffStat = d
	}
	untracked := ""
	if deps != nil && deps.GitUntrackedFiles != nil {
		u, _ := deps.GitUntrackedFiles()
		untracked = u
	}

	sessionBase := filepath.Base(envOr("TEKHTON_SESSION_DIR", "__nosession__"))
	untrackedFiltered := filterUntracked(untracked, sessionBase)
	trackedTrimmed := topNLines(tracked, 30)
	diffStatTrimmed := topNLines(diffStat, 5)
	untrackedTrimmed := topNLines(untrackedFiltered, 30)

	var b strings.Builder
	fmt.Fprintf(&b, "## Status: %s\n\n", status)
	b.WriteString("## Summary\n")
	fmt.Fprintf(&b,
		"%s was reconstructed by the pipeline after the coder agent\n"+
			"failed to produce or maintain it. The following files were modified based\n"+
			"on git state. The reviewer should assess actual changes directly.\n\n",
		path)
	b.WriteString("## Files Modified\n")
	for _, line := range strings.Split(trackedTrimmed, "\n") {
		if line == "" {
			continue
		}
		fmt.Fprintf(&b, "- %s\n", line)
	}
	b.WriteString("\n## New Files Created\n")
	for _, line := range strings.Split(untrackedTrimmed, "\n") {
		if line == "" {
			continue
		}
		fmt.Fprintf(&b, "- %s (new)\n", line)
	}
	b.WriteString("\n## Git Diff Summary\n")
	b.WriteString("```\n")
	b.WriteString(diffStatTrimmed)
	if !strings.HasSuffix(diffStatTrimmed, "\n") {
		b.WriteByte('\n')
	}
	b.WriteString("```\n\n")
	b.WriteString("## Remaining Work\n")
	b.WriteString("Unable to determine — coder did not report remaining items.\n")
	b.WriteString("Review the task description against actual changes to identify gaps.\n")

	if dir := filepath.Dir(path); dir != "" {
		_ = os.MkdirAll(dir, 0o755)
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

// isValidStatus enforces the 3-status table — any other value is a caller
// error.
func isValidStatus(status string) bool {
	switch status {
	case "COMPLETE", "FAILED", "INCOMPLETE":
		return true
	}
	return false
}

// filterUntracked drops .claude/logs/ entries and entries under the session
// dir basename. Matches the bash exclusions at stages/coder.sh:63-66.
func filterUntracked(content, sessionBase string) string {
	if content == "" {
		return ""
	}
	scanner := bufio.NewScanner(strings.NewReader(content))
	var out []string
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, ".claude/logs/") {
			continue
		}
		if sessionBase != "" && sessionBase != "__nosession__" && strings.HasPrefix(line, sessionBase+"/") {
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

// topNLines returns the first n lines of content joined by '\n'. Mirrors
// bash `head -N`.
func topNLines(content string, n int) string {
	if content == "" || n <= 0 {
		return ""
	}
	lines := strings.Split(content, "\n")
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.Join(lines, "\n")
}
