package docs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestPrepareTemplateVars_DefaultsAndContent(t *testing.T) {
	proj := t.TempDir()
	gitInit(t, proj)

	// Coder summary lives at the bash default path (.tekhton/CODER_SUMMARY.md).
	writeFile(t, filepath.Join(proj, ".tekhton", "CODER_SUMMARY.md"),
		"# summary\nSome work was done.\n")
	writeFile(t, filepath.Join(proj, "CLAUDE.md"), `# X
## Documentation Responsibilities
- Update README.md
`)
	// Clear the relevant env vars so the defaults exercise their fallback.
	t.Setenv("DOCS_README_FILE", "")
	t.Setenv("DOCS_DIRS", "")
	t.Setenv("DOCS_AGENT_REPORT_FILE", "")
	t.Setenv("TEKHTON_DIR", "")
	t.Setenv("PROJECT_RULES_FILE", "")
	t.Setenv("CODER_SUMMARY_FILE", "")

	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageDocs,
		ResultFile: "/tmp/x",
	}
	vars := prepareTemplateVars(proj, req)

	if vars["DOCS_README_FILE"] != "README.md" {
		t.Errorf("DOCS_README_FILE default=%q", vars["DOCS_README_FILE"])
	}
	if vars["DOCS_DIRS"] != "docs/" {
		t.Errorf("DOCS_DIRS default=%q", vars["DOCS_DIRS"])
	}
	if !strings.HasSuffix(vars["DOCS_AGENT_REPORT_FILE"], "DOCS_AGENT_REPORT.md") {
		t.Errorf("DOCS_AGENT_REPORT_FILE=%q", vars["DOCS_AGENT_REPORT_FILE"])
	}
	if !strings.Contains(vars["CODER_SUMMARY_CONTENT"], "Some work was done") {
		t.Errorf("coder summary content not propagated: %q", vars["CODER_SUMMARY_CONTENT"])
	}
	if !strings.Contains(vars["DOCS_SURFACE_SECTION"], "README.md") {
		t.Errorf("DOCS_SURFACE_SECTION missing surface entry: %q", vars["DOCS_SURFACE_SECTION"])
	}
}

func TestPrepareTemplateVars_NoCoderSummary(t *testing.T) {
	proj := t.TempDir()
	gitInit(t, proj)
	// No CLAUDE.md, no CODER_SUMMARY.md — every var must still be present
	// (empty string acceptable) so the prompt renderer never sees a missing key.
	t.Setenv("DOCS_README_FILE", "")
	t.Setenv("DOCS_DIRS", "")
	t.Setenv("DOCS_AGENT_REPORT_FILE", "")
	t.Setenv("TEKHTON_DIR", "")
	t.Setenv("PROJECT_RULES_FILE", "")
	t.Setenv("CODER_SUMMARY_FILE", "")

	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageDocs,
		ResultFile: "/tmp/x",
	}
	vars := prepareTemplateVars(proj, req)

	for _, k := range []string{
		"DOCS_README_FILE", "DOCS_DIRS", "DOCS_AGENT_REPORT_FILE",
		"CODER_SUMMARY_CONTENT", "DOCS_SURFACE_SECTION", "DOCS_GIT_DIFF_STAT",
	} {
		if _, ok := vars[k]; !ok {
			t.Errorf("vars missing key %q", k)
		}
	}
	if vars["CODER_SUMMARY_CONTENT"] != "" {
		t.Errorf("expected empty CODER_SUMMARY_CONTENT, got %q", vars["CODER_SUMMARY_CONTENT"])
	}
}

func TestSafeReadFile_Truncates(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "big.md")
	// Write 1.1 MB so we cross the 1 MB cap.
	big := strings.Repeat("a", safeReadFileMaxBytes+1024)
	if err := os.WriteFile(path, []byte(big), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := safeReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "TRUNCATED") {
		t.Fatalf("truncation marker missing: tail=%q", got[len(got)-200:])
	}
}

func TestEnvOr(t *testing.T) {
	t.Setenv("DOCS_TEST_KEY", "")
	if envOr("DOCS_TEST_KEY", "fallback") != "fallback" {
		t.Fatal("empty env should fall back")
	}
	t.Setenv("DOCS_TEST_KEY", "set-value")
	if envOr("DOCS_TEST_KEY", "fallback") != "set-value" {
		t.Fatal("set env should win")
	}
}
