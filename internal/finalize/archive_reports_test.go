package finalize

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestArchiveReports_CopiesPresentFilesWithTimestampPrefix(t *testing.T) {
	dir := t.TempDir()
	src1 := filepath.Join(dir, ".tekhton", "CODER_SUMMARY.md")
	src2 := filepath.Join(dir, ".tekhton", "REVIEWER_REPORT.md")
	if err := os.MkdirAll(filepath.Dir(src1), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{src1, src2} {
		if err := os.WriteFile(s, []byte("hello "+s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	logDir := filepath.Join(dir, ".claude", "logs")
	h := &ArchiveReports{
		Reports: []string{src1, src2},
	}
	in := &Input{
		ProjectDir: dir,
		LogDir:     logDir,
		Timestamp:  "20260517_120000",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("ArchiveReports.Run: %v", err)
	}
	for _, basename := range []string{"CODER_SUMMARY.md", "REVIEWER_REPORT.md"} {
		dst := filepath.Join(logDir, "20260517_120000_"+basename)
		if _, err := os.Stat(dst); err != nil {
			t.Errorf("expected archived report %s; stat err=%v", dst, err)
		}
	}
}

func TestArchiveReports_SkipsMissingFiles(t *testing.T) {
	dir := t.TempDir()
	logDir := filepath.Join(dir, ".claude", "logs")
	h := &ArchiveReports{
		Reports: []string{filepath.Join(dir, "nonexistent.md")},
	}
	in := &Input{
		ProjectDir: dir,
		LogDir:     logDir,
		Timestamp:  "20260517_120000",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Errorf("missing source should not error; got %v", err)
	}
}

func TestArchiveReports_RequiresLogDirAndTimestamp(t *testing.T) {
	h := &ArchiveReports{}
	if err := h.Run(context.Background(), &Input{ProjectDir: "/tmp"}); err == nil {
		t.Errorf("expected error when LogDir empty")
	}
	if err := h.Run(context.Background(), &Input{ProjectDir: "/tmp", LogDir: "/tmp/logs"}); err == nil {
		t.Errorf("expected error when Timestamp empty")
	}
}

func TestArchiveReports_UsesEnvVarFallbacksByDefault(t *testing.T) {
	dir := t.TempDir()
	logDir := filepath.Join(dir, ".claude", "logs")
	customReport := filepath.Join(dir, ".tekhton", "custom_coder.md")
	if err := os.MkdirAll(filepath.Dir(customReport), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(customReport, []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}
	lookup := func(key string) (string, bool) {
		if key == "CODER_SUMMARY_FILE" {
			return ".tekhton/custom_coder.md", true
		}
		return "", false
	}
	h := &ArchiveReports{Lookup: lookup}
	in := &Input{
		ProjectDir: dir,
		LogDir:     logDir,
		Timestamp:  "ts",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("ArchiveReports.Run: %v", err)
	}
	dst := filepath.Join(logDir, "ts_custom_coder.md")
	if _, err := os.Stat(dst); err != nil {
		t.Errorf("expected env-driven report archived at %s; stat err=%v", dst, err)
	}
}
