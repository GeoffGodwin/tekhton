package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCrawlerHelpListsSubcommands(t *testing.T) {
	root := newRootCmd()
	root.SetArgs([]string{"crawler", "--help"})
	var buf bytes.Buffer
	root.SetOut(&buf)
	root.SetErr(&buf)
	if err := root.Execute(); err != nil {
		t.Fatalf("crawler --help: %v", err)
	}
	out := buf.String()
	for _, sub := range []string{"crawl", "inventory", "deps", "content", "rescan"} {
		if !strings.Contains(out, sub) {
			t.Errorf("crawler --help missing subcommand %q in output:\n%s", sub, out)
		}
	}
}

func TestCrawlerRescanHelpListsFlags(t *testing.T) {
	root := newRootCmd()
	root.SetArgs([]string{"crawler", "rescan", "--help"})
	var buf bytes.Buffer
	root.SetOut(&buf)
	root.SetErr(&buf)
	if err := root.Execute(); err != nil {
		t.Fatalf("crawler rescan --help: %v", err)
	}
	out := buf.String()
	for _, flag := range []string{"--full", "--project-dir", "--budget"} {
		if !strings.Contains(out, flag) {
			t.Errorf("crawler rescan --help missing %q in output:\n%s", flag, out)
		}
	}
}

func TestCrawlerRescanFullCrawlOnFreshProject(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("# x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	root := newRootCmd()
	root.SetArgs([]string{"crawler", "rescan", "--project-dir", dir, "--json"})
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&out)
	if err := root.Execute(); err != nil {
		t.Fatalf("crawler rescan: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("--json output not valid JSON: %v\n%s", err, out.String())
	}
	if got["mode"] != "full" {
		t.Errorf("expected mode=full on fresh project, got %v", got["mode"])
	}
}

func TestCrawlerCrawlJSONOutput(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("# x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "main.go"), []byte("package main\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	root := newRootCmd()
	root.SetArgs([]string{"crawler", "crawl", "--project-dir", dir, "--budget", "5000", "--json"})
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&out)
	if err := root.Execute(); err != nil {
		t.Fatalf("crawler crawl --json: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("--json output not valid JSON: %v\n%s", err, out.String())
	}
	for _, key := range []string{"index_dir", "file_count", "total_lines", "tree_lines", "doc_quality_score"} {
		if _, ok := got[key]; !ok {
			t.Errorf("missing JSON key %q in summary", key)
		}
	}
}

func TestCrawlerDepsJSON(t *testing.T) {
	dir := t.TempDir()
	// extractJSONKeys (ported from bash) is line-oriented — minified
	// JSON would parse to zero deps. Use the multi-line shape that real
	// package.json files take.
	pkg := `{
  "name": "demo",
  "dependencies": {
    "react": "^18.0.0",
    "express": "4.17.1"
  }
}
`
	if err := os.WriteFile(filepath.Join(dir, "package.json"), []byte(pkg), 0o644); err != nil {
		t.Fatal(err)
	}
	root := newRootCmd()
	root.SetArgs([]string{"crawler", "deps", "--project-dir", dir, "--json"})
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&out)
	if err := root.Execute(); err != nil {
		t.Fatalf("crawler deps --json: %v", err)
	}
	body := out.String()
	if !strings.Contains(body, `"react"`) {
		t.Errorf("deps --json missing react: %s", body)
	}
	if !strings.Contains(body, `"manifests"`) {
		t.Errorf("deps --json missing manifests key: %s", body)
	}
}
