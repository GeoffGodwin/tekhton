package detect

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// helper: write fixture files into a temp dir for a single sub-test.
func writeFixture(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for rel, body := range files {
		full := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", filepath.Dir(full), err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatalf("write %s: %v", full, err)
		}
	}
	return dir
}

func TestCommandsDetector_GoMod(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"go.mod": "module example.com/x\n\ngo 1.22\n",
	})
	in := &Input{ProjectDir: dir, Languages: []Language{{Name: "go"}}}
	r, err := CommandsDetector{}.Run(context.Background(), in)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	wantTypes := map[string]string{"test": "go test ./...", "build": "go build ./...", "analyze": "go vet ./..."}
	got := map[string]string{}
	for _, row := range r.Findings {
		if row["kind"] == "command" {
			got[row["type"]] = row["command"]
		}
	}
	for k, v := range wantTypes {
		if got[k] != v {
			t.Errorf("command %s: want %q, got %q", k, v, got[k])
		}
	}
}

func TestCommandsDetector_DedupHighestConfidence(t *testing.T) {
	// Go-mod analyze (high) should outrank ruff convention (low). Use a
	// pyproject as well so both sources contribute test commands.
	dir := writeFixture(t, map[string]string{
		"go.mod":         "module x\n",
		"pyproject.toml": "[project]\nname = \"x\"\n",
	})
	in := &Input{ProjectDir: dir}
	r, _ := CommandsDetector{}.Run(context.Background(), in)
	seen := map[string]string{}
	for _, row := range r.Findings {
		if row["kind"] != "command" {
			continue
		}
		// First (highest-confidence) entry per type wins.
		if _, ok := seen[row["type"]]; !ok {
			seen[row["type"]] = row["confidence"]
		}
	}
	if seen["analyze"] != "high" {
		t.Errorf("analyze should pick go-vet (high) over pyproject convention (low); got %q", seen["analyze"])
	}
}

func TestCommandsDetector_EmptyDir(t *testing.T) {
	dir := t.TempDir()
	in := &Input{ProjectDir: dir}
	r, _ := CommandsDetector{}.Run(context.Background(), in)
	for _, row := range r.Findings {
		if row["kind"] == "command" {
			t.Errorf("empty dir should produce no commands; got %+v", row)
		}
	}
}

func TestEntryPoints_GoCmdPattern(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"cmd/foo/main.go": "package main\n",
		"cmd/bar/main.go": "package main\n",
	})
	eps := detectEntryPoints(dir)
	want := []string{"cmd/bar/main.go", "cmd/foo/main.go"}
	if len(eps) != len(want) || eps[0] != want[0] || eps[1] != want[1] {
		t.Errorf("cmd/*/main.go entry points: want %v, got %v", want, eps)
	}
}

func TestDetectProjectType_Library(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"package.json": `{"name":"x","main":"index.js"}`,
	})
	langs := []Language{{Name: "javascript"}}
	got := detectProjectType(dir, langs, nil, nil)
	if got != "library" {
		t.Errorf("library detection: got %q, want library", got)
	}
}
