package crawler

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCrawlMinimal(t *testing.T) {
	dir := t.TempDir()
	mustWrite := func(rel, body string) {
		full := filepath.Join(dir, rel)
		_ = os.MkdirAll(filepath.Dir(full), 0o755)
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mustWrite("README.md", "# x\n")
	mustWrite("main.go", "package main\n")
	mustWrite("package.json", `{"dependencies":{"react":"^18.0.0"}}`)

	r, err := Crawl(context.Background(), Options{
		ProjectDir:  dir,
		BudgetChars: 5000,
		ScanDate:    "FROZEN",
		ScanCommit:  "FROZEN",
	})
	if err != nil {
		t.Fatalf("Crawl: %v", err)
	}
	// Each artifact present.
	for _, name := range []string{
		"tree.txt", "inventory.jsonl", "dependencies.json",
		"configs.json", "tests.json", "meta.json", "samples/manifest.json",
	} {
		p := filepath.Join(r.IndexDir, name)
		if _, err := os.Stat(p); err != nil {
			t.Errorf("missing artifact %s: %v", name, err)
		}
	}
	// File count should include the three project files.
	if r.FileCount < 3 {
		t.Errorf("expected FileCount >= 3, got %d", r.FileCount)
	}
	// Meta should contain the injected scan_date / scan_commit (parity hook).
	body, _ := os.ReadFile(filepath.Join(r.IndexDir, "meta.json"))
	if !strings.Contains(string(body), `"scan_date": "FROZEN"`) {
		t.Errorf("meta missing injected scan_date: %s", body)
	}
}

func TestCrawlRequiresProjectDir(t *testing.T) {
	_, err := Crawl(context.Background(), Options{})
	if err != ErrMissingProjectDir {
		t.Errorf("expected ErrMissingProjectDir, got %v", err)
	}
}

func TestCrawlRespectsCanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Crawl(ctx, Options{ProjectDir: t.TempDir()}); err == nil {
		t.Error("expected context error on canceled ctx")
	}
}
