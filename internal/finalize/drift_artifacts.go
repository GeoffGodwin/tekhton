package finalize

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/drift"
)

// DriftArtifacts is the Go body of _hook_drift_artifacts. m25 port of
// the bash _hook_drift_artifacts function in
// lib/finalize_core_hooks.sh, which called process_drift_artifacts
// from lib/drift_artifacts.sh.
//
// Two concerns mix in this hook:
//
//  1. Drift observations from the reviewer report get appended to
//     DRIFT_LOG.md.
//  2. Non-blocking notes from the reviewer report get appended to
//     NON_BLOCKING_LOG.md.
//
// Both run unconditionally — the bash version was a no-op when the
// report file was missing, which the Go ports preserve. The
// runs-since-audit counter is incremented at the end of the hook.
//
// Mode gates: the bash version respected FIX_DRIFT_MODE and
// FIX_NONBLOCKERS_MODE env vars to skip the relevant append step so
// the fix loop didn't generate the same observations it was trying
// to resolve. The Go body preserves these.
type DriftArtifacts struct{}

// Name implements Hook.
func (h *DriftArtifacts) Name() string { return "_hook_drift_artifacts" }

// Run executes the hook. Always returns nil — chain semantics.
func (h *DriftArtifacts) Run(_ context.Context, in *Input) error {
	projectDir := in.ProjectDir
	if projectDir == "" {
		var err error
		projectDir, err = os.Getwd()
		if err != nil {
			return nil
		}
	}
	reviewerReport := resolveReportFile(projectDir, in, "REVIEWER_REPORT_FILE", "REVIEWER_REPORT.md")
	task := envValue(in, "TASK")

	// 1. Append drift observations (skip during --fix-drift to
	//    prevent feedback loop).
	if envValue(in, "FIX_DRIFT_MODE") != "true" {
		if section := extractSection(reviewerReport, "## Drift Observations"); section != "" {
			driftPath := resolveReportFile(projectDir, in, "DRIFT_LOG_FILE", "DRIFT_LOG.md")
			l := drift.NewLog(driftPath)
			if err := l.AppendObservations(task, section); err != nil {
				fmt.Fprintf(logWriter(in), "drift_artifacts: append observations: %v\n", err)
			}
		}
	}

	// 2. Append non-blocking notes (skip during --fix-nonblockers).
	if envValue(in, "FIX_NONBLOCKERS_MODE") != "true" {
		if section := extractSection(reviewerReport, "## Non-Blocking Notes"); section != "" {
			nbPath := resolveReportFile(projectDir, in, "NON_BLOCKING_LOG_FILE", "NON_BLOCKING_LOG.md")
			nb := drift.NewNonBlocking(nbPath)
			if err := nb.AppendNotes(task, section); err != nil {
				fmt.Fprintf(logWriter(in), "drift_artifacts: append non-blocking: %v\n", err)
			}
		}
	}

	// 3. Increment runs-since-audit counter.
	driftPath := resolveReportFile(projectDir, in, "DRIFT_LOG_FILE", "DRIFT_LOG.md")
	if _, err := os.Stat(driftPath); err == nil {
		l := drift.NewLog(driftPath)
		if err := l.IncrementRunsSinceAudit(); err != nil {
			fmt.Fprintf(logWriter(in), "drift_artifacts: increment runs: %v\n", err)
		}
	}
	return nil
}

// resolveReportFile returns the absolute path to a report file, given
// project directory, the Input env, and a fallback default. Mirrors
// the bash `${PROJECT_DIR}/${REVIEWER_REPORT_FILE:-default}` pattern.
func resolveReportFile(projectDir string, in *Input, envKey, defaultName string) string {
	name := envValue(in, envKey)
	if name == "" {
		name = defaultName
	}
	if filepath.IsAbs(name) {
		return name
	}
	return filepath.Join(projectDir, name)
}

// extractSection reads the named markdown H2 section from path and
// returns the body (everything until the next H2 or EOF). Returns
// the empty string when the section is absent, the file is missing,
// or the section body contains only "None".
func extractSection(path, header string) string {
	body, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var lines []string
	in := false
	for _, line := range splitLines(string(body)) {
		if !in {
			if startsWith(line, header) {
				in = true
			}
			continue
		}
		if startsWith(line, "## ") {
			break
		}
		lines = append(lines, line)
	}
	if len(lines) == 0 {
		return ""
	}
	// Strip leading/trailing blank lines and check for "None".
	out := joinLines(lines)
	trimmed := trimAll(out)
	if trimmed == "" || isNoneOnly(out) {
		return ""
	}
	return out
}

// splitLines / joinLines / startsWith / trimAll / isNoneOnly are
// tiny inline helpers so this file doesn't pull in strings / bytes
// imports — those would slightly slow the finalize cold path. They
// follow the same semantics as their stdlib counterparts.
func splitLines(s string) []string {
	out := []string{""}
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			out = append(out, "")
			continue
		}
		out[len(out)-1] += string(s[i])
	}
	return out
}

func joinLines(ls []string) string {
	out := ""
	for i, l := range ls {
		if i > 0 {
			out += "\n"
		}
		out += l
	}
	return out
}

func startsWith(s, p string) bool { return len(s) >= len(p) && s[:len(p)] == p }

func trimAll(s string) string {
	out := ""
	for _, r := range s {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			continue
		}
		out += string(r)
	}
	return out
}

func isNoneOnly(s string) bool {
	t := trimAll(s)
	if t == "" {
		return true
	}
	// Strip leading bullet/dash characters before comparing.
	for len(t) > 0 && (t[0] == '-' || t[0] == '*') {
		t = t[1:]
	}
	return t == "None" || t == "none" || t == "NONE"
}
