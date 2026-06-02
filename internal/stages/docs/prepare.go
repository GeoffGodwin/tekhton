package docs

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// safeReadFileMaxBytes mirrors the 1 MB cap _safe_read_file enforces on the
// bash side. Files larger than this are truncated with a marker so a stray
// 50 MB log never bloats the agent prompt.
const safeReadFileMaxBytes = 1 << 20

// prepareTemplateVars builds the {{VAR}} substitution map the docs_agent
// prompt template expects. Port of _docs_prepare_template_vars from
// stages/docs.sh. Every value falls back to the empty string so the template
// renderer can safely substitute missing keys without "unbound variable"
// equivalents.
func prepareTemplateVars(projectDir string, req *proto.StageRequestV1) map[string]string {
	vars := map[string]string{}

	// Pre-seed shell-style passthroughs that the bash prepare function
	// exported unconditionally; downstream callers expect them present even
	// when the user has not customised them.
	vars["DOCS_README_FILE"] = envOr("DOCS_README_FILE", "README.md")
	vars["DOCS_DIRS"] = envOr("DOCS_DIRS", "docs/")
	tekhtonDir := envOr("TEKHTON_DIR", ".tekhton")
	vars["DOCS_AGENT_REPORT_FILE"] = envOr("DOCS_AGENT_REPORT_FILE",
		filepath.Join(tekhtonDir, "DOCS_AGENT_REPORT.md"))

	// CODER_SUMMARY_CONTENT — best-effort read.
	summaryRel := envOr("CODER_SUMMARY_FILE", filepath.Join(tekhtonDir, "CODER_SUMMARY.md"))
	summaryPath := summaryRel
	if !filepath.IsAbs(summaryPath) {
		summaryPath = filepath.Join(projectDir, summaryRel)
	}
	if b, err := safeReadFile(summaryPath); err == nil {
		vars["CODER_SUMMARY_CONTENT"] = b
	} else {
		vars["CODER_SUMMARY_CONTENT"] = ""
	}

	// DOCS_GIT_DIFF_STAT — try working tree first, fall back to index.
	vars["DOCS_GIT_DIFF_STAT"] = collectGitDiffStat(projectDir)

	// DOCS_SURFACE_SECTION — same Documentation Responsibilities section the
	// skip-check extracts, threaded through to the agent prompt as context.
	rulesFile := envOr("PROJECT_RULES_FILE", "CLAUDE.md")
	rulesPath := rulesFile
	if !filepath.IsAbs(rulesPath) {
		rulesPath = filepath.Join(projectDir, rulesFile)
	}
	if b, err := os.ReadFile(rulesPath); err == nil {
		vars["DOCS_SURFACE_SECTION"] = extractDocResponsibilities(string(b))
	} else {
		vars["DOCS_SURFACE_SECTION"] = ""
	}

	return vars
}

func collectGitDiffStat(projectDir string) string {
	out, err := runDiffStat(projectDir, "HEAD")
	if err == nil && strings.TrimSpace(out) != "" {
		return out
	}
	cached, _ := runDiffStat(projectDir, "--cached")
	return cached
}

func runDiffStat(projectDir string, refOrFlag string) (string, error) {
	cmd := exec.Command("git", "diff", "--stat", refOrFlag)
	cmd.Dir = projectDir
	out, err := cmd.Output()
	return string(out), err
}

// safeReadFile reads path and truncates at safeReadFileMaxBytes with a
// banner identifying the truncation. Returns the empty string and an error
// when the file is missing — callers fall back to "" so the template renders
// without an unbound-variable equivalent.
func safeReadFile(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if len(b) > safeReadFileMaxBytes {
		truncated := string(b[:safeReadFileMaxBytes])
		return truncated + "\n... [TRUNCATED — file exceeds " +
			"1MB cap] ...\n", nil
	}
	return string(b), nil
}

func envOr(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}
