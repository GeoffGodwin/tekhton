package finalize

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// defaultReportEnvVars is the canonical list of report-file env vars the
// bash archive_reports function copied into the log dir. Each entry resolves
// to a project-relative path via os.Getenv at hook run time. If an env var
// is unset we fall back to the conventional .tekhton/ or .claude/ basename
// so the Go port still archives reports when the runner is invoked without
// a fully-populated pipeline.conf environment.
var defaultReportEnvVars = []envVarFallback{
	{Env: "CODER_SUMMARY_FILE", Fallback: ".tekhton/CODER_SUMMARY.md"},
	{Env: "REVIEWER_REPORT_FILE", Fallback: ".tekhton/REVIEWER_REPORT.md"},
	{Env: "TESTER_REPORT_FILE", Fallback: ".tekhton/TESTER_REPORT.md"},
	{Env: "JR_CODER_SUMMARY_FILE", Fallback: ".tekhton/JR_CODER_SUMMARY.md"},
	{Env: "SECURITY_REPORT_FILE", Fallback: ".tekhton/SECURITY_REPORT.md"},
	{Env: "SECURITY_NOTES_FILE", Fallback: ".tekhton/SECURITY_NOTES.md"},
	{Env: "INTAKE_REPORT_FILE", Fallback: ".tekhton/INTAKE_REPORT.md"},
	{Env: "PREFLIGHT_ERRORS_FILE", Fallback: ".tekhton/PREFLIGHT_REPORT.md"},
	{Env: "TEST_AUDIT_REPORT_FILE", Fallback: ".tekhton/TEST_AUDIT_REPORT.md"},
	{Env: "UI_VALIDATION_REPORT_FILE", Fallback: ".tekhton/UI_VALIDATION_REPORT.md"},
}

type envVarFallback struct {
	Env      string
	Fallback string
}

// ArchiveReports is the Go body of _hook_archive_reports. Copies each
// stage report file from the project root into the log directory, prefixed
// with the run timestamp so multiple runs in a day are distinguishable.
// Pure Go because every dependency (file paths, env var lookup, file copy)
// is stdlib-only.
//
// Dashboard data files under .claude/dashboard/data/ are NOT archived — the
// bash version made the same exclusion because those files are regenerated
// each run from the causal log. CAUSAL_LOG.jsonl is archived separately by
// CausalLogFinalize via internal/causal.Log.Archive.
type ArchiveReports struct {
	// Reports overrides the default set of project-relative report paths.
	// Tests use this to point at fixtures.
	Reports []string

	// Lookup overrides os.LookupEnv. Tests use this to inject a fake env
	// without mutating the process environment.
	Lookup func(string) (string, bool)
}

// Name implements Hook.
func (h *ArchiveReports) Name() string { return "_hook_archive_reports" }

// Run executes the report archive. Missing source files are skipped without
// error; an I/O failure on copy is returned (the orchestrator logs it and
// continues — chain semantics unchanged).
func (h *ArchiveReports) Run(_ context.Context, in *Input) error {
	if in.LogDir == "" {
		return errors.New("archive_reports: log dir not set")
	}
	if in.Timestamp == "" {
		return errors.New("archive_reports: timestamp not set")
	}
	if err := os.MkdirAll(in.LogDir, 0o755); err != nil {
		return fmt.Errorf("archive_reports: mkdir log dir: %w", err)
	}

	reports := h.resolveReports(in.ProjectDir)
	var firstErr error
	for _, src := range reports {
		// Skip missing source files silently — the bash version did the
		// same with `[ -f "$f" ]` so absent reports are normal.
		info, err := os.Stat(src)
		if err != nil || info.IsDir() {
			continue
		}
		dst := filepath.Join(in.LogDir, in.Timestamp+"_"+filepath.Base(src))
		if err := copyReportFile(src, dst); err != nil && firstErr == nil {
			firstErr = fmt.Errorf("archive_reports: copy %s: %w", src, err)
		}
	}
	return firstErr
}

// resolveReports turns the env-var driven default list into absolute paths
// inside in.ProjectDir, honoring Lookup overrides for tests.
func (h *ArchiveReports) resolveReports(projectDir string) []string {
	if len(h.Reports) > 0 {
		out := make([]string, 0, len(h.Reports))
		for _, p := range h.Reports {
			out = append(out, absoluteUnder(projectDir, p))
		}
		return out
	}
	lookup := h.Lookup
	if lookup == nil {
		lookup = os.LookupEnv
	}
	out := make([]string, 0, len(defaultReportEnvVars))
	for _, e := range defaultReportEnvVars {
		path, ok := lookup(e.Env)
		if !ok || path == "" {
			path = e.Fallback
		}
		out = append(out, absoluteUnder(projectDir, path))
	}
	return out
}

// absoluteUnder returns path joined to projectDir when path is relative, or
// path unchanged when already absolute. Mirrors the bash convention where
// most config file paths are stored as project-relative strings.
//
// Relative inputs are cleaned and asserted to resolve under projectDir;
// a relative path that traverses out (e.g. "../../etc/passwd") collapses
// to projectDir itself, refusing the traversal. Absolute paths are
// cleaned only — bash parity allows env-driven absolute paths (LOG_DIR,
// CAUSAL_LOG_FILE) to point anywhere the operator configures.
func absoluteUnder(projectDir, path string) string {
	if filepath.IsAbs(path) {
		return filepath.Clean(path)
	}
	cleanProject := filepath.Clean(projectDir)
	joined := filepath.Clean(filepath.Join(cleanProject, path))
	if joined == cleanProject ||
		strings.HasPrefix(joined, cleanProject+string(filepath.Separator)) {
		return joined
	}
	return cleanProject
}

// copyReportFile copies src to dst. Mirrors `cp` semantics — overwrites
// destination, preserves contents, does not preserve mtime (which the bash
// cp did but reviewers never depended on it).
func copyReportFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
