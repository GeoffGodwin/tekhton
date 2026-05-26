package clarify

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func writeReport(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "REPORT.md")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestDetect_NoSection(t *testing.T) {
	path := writeReport(t, "# Report\n\n## Other Section\n- foo\n")
	_, err := DetectFromFile(path, DetectOptions{})
	if !errors.Is(err, ErrNoClarifications) {
		t.Errorf("expected ErrNoClarifications, got %v", err)
	}
}

func TestDetect_EmptySection(t *testing.T) {
	path := writeReport(t, "## Clarification Required\n\n## Next\n")
	_, err := DetectFromFile(path, DetectOptions{})
	if !errors.Is(err, ErrNoClarifications) {
		t.Errorf("expected ErrNoClarifications, got %v", err)
	}
}

func TestDetect_BlockingItems(t *testing.T) {
	path := writeReport(t, `# Report

## Clarification Required
- [BLOCKING] What is the timeout?
- [NON_BLOCKING] Style: tabs or spaces?
- [BLOCKING] Which library?

## Next Section
`)
	items, err := DetectFromFile(path, DetectOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if len(items.Blocking) != 2 {
		t.Errorf("Blocking = %d, want 2", len(items.Blocking))
	}
	if len(items.NonBlocking) != 1 {
		t.Errorf("NonBlocking = %d, want 1", len(items.NonBlocking))
	}
}

func TestDetect_CaseInsensitiveTags(t *testing.T) {
	path := writeReport(t, `## Clarification Required
- [blocking] lowercase tag
`)
	items, err := DetectFromFile(path, DetectOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if len(items.Blocking) != 1 {
		t.Errorf("expected 1 blocking item with lowercase tag, got %d", len(items.Blocking))
	}
}

func TestDetect_DisabledViaEnv(t *testing.T) {
	path := writeReport(t, `## Clarification Required
- [BLOCKING] question
`)
	env := func(key string) string {
		if key == "CLARIFICATION_ENABLED" {
			return "false"
		}
		return ""
	}
	_, err := DetectFromFile(path, DetectOptions{Env: env})
	if !errors.Is(err, ErrDisabled) {
		t.Errorf("expected ErrDisabled, got %v", err)
	}
}

func TestDetect_MissingFile(t *testing.T) {
	_, err := DetectFromFile("/nonexistent/path/to/report.md", DetectOptions{})
	if !errors.Is(err, ErrNoClarifications) {
		t.Errorf("expected ErrNoClarifications, got %v", err)
	}
}

func TestDetect_HasBlockingExitCode(t *testing.T) {
	// The CLI's `clarify detect` exits 0 when no unchecked items, 1 when any
	// blocking are present. Test the underlying predicate.
	none, err := DetectFromFile(writeReport(t, "no section\n"), DetectOptions{})
	if !errors.Is(err, ErrNoClarifications) {
		t.Errorf("none: want ErrNoClarifications, got items=%v err=%v", none, err)
	}
	has, err := DetectFromFile(writeReport(t, "## Clarification Required\n- [BLOCKING] x\n"), DetectOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if !has.HasBlocking() {
		t.Error("HasBlocking() should be true with one [BLOCKING] item")
	}
}

func TestLoadFileContent_Missing(t *testing.T) {
	body, err := LoadFileContent("/nonexistent")
	if err != nil {
		t.Fatal(err)
	}
	if body != "" {
		t.Errorf("missing file = %q, want empty", body)
	}
}

func TestLoadFileContent_Present(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "C.md")
	_ = os.WriteFile(path, []byte("# c\n## Q: hi\n**A:** there\n"), 0o644)
	body, err := LoadFileContent(path)
	if err != nil {
		t.Fatal(err)
	}
	if body == "" {
		t.Error("present file should return non-empty content")
	}
}
