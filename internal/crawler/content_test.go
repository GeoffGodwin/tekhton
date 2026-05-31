package crawler

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIsBinaryExtension(t *testing.T) {
	dir := t.TempDir()
	// Create an empty file with each extension — null-byte heuristic
	// won't fire (empty); fallback to extension check.
	for ext, want := range map[string]bool{
		"png": true, "zip": true, "exe": true,
		"go": false, "md": false, "txt": false,
	} {
		p := filepath.Join(dir, "f."+ext)
		if err := os.WriteFile(p, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		if got := isBinary(p); got != want {
			t.Errorf("isBinary(.%s) = %v, want %v", ext, got, want)
		}
	}
}

func TestIsBinaryNullByte(t *testing.T) {
	dir := t.TempDir()
	// A .txt file containing a null byte must register as binary
	// regardless of extension.
	p := filepath.Join(dir, "weird.txt")
	if err := os.WriteFile(p, []byte("hello\x00world"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !isBinary(p) {
		t.Errorf("isBinary should fire on null byte in .txt")
	}
}

func TestReadSampledStripsTrailingNewlines(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "a.md")
	if err := os.WriteFile(p, []byte("hello\nworld\n\n\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := readSampled(p, 1000)
	want := "hello\nworld"
	if got != want {
		t.Errorf("readSampled trailing-newline strip:\n  got %q\n  want %q", got, want)
	}
}

func TestReadSampledTruncatesAtLastNewline(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "a.md")
	body := "line1\nline2\nline3\n"
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	// Budget of 10 — fits "line1\nline" (10 chars) → trim to last
	// newline → "line1" → append truncation marker.
	got := readSampled(p, 10)
	if !strings.HasPrefix(got, "line1\n... (truncated") {
		t.Errorf("readSampled truncate: got %q", got)
	}
}

func TestSampleFilesStoredNameMapping(t *testing.T) {
	dir := t.TempDir()
	mustWrite := func(rel, body string) {
		full := filepath.Join(dir, rel)
		_ = os.MkdirAll(filepath.Dir(full), 0o755)
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mustWrite("README.md", "# Hi\n")
	mustWrite("src/main.go", "package main\n")

	samples := sampleFiles(dir, []string{"README.md", "src/main.go"}, 1000, "")
	if len(samples) != 2 {
		t.Fatalf("got %d samples, want 2", len(samples))
	}
	if samples[1].Stored != "src__main.go.txt" {
		t.Errorf("stored name should flatten / to __: got %q", samples[1].Stored)
	}
	if samples[0].Stored != "README.md.txt" {
		t.Errorf("README stored name: got %q", samples[0].Stored)
	}
}

func TestSampleFilesBudgetExhaustion(t *testing.T) {
	dir := t.TempDir()
	mustWrite := func(rel string, size int) {
		full := filepath.Join(dir, rel)
		_ = os.MkdirAll(filepath.Dir(full), 0o755)
		body := strings.Repeat("x", size)
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mustWrite("README.md", 200)
	mustWrite("main.go", 200)
	// Budget too small for the second sample after README + wrapper.
	samples := sampleFiles(dir, []string{"README.md", "main.go"}, 220, "")
	if len(samples) != 1 {
		t.Errorf("budget should have cut second sample: got %d", len(samples))
	}
}

func TestSampleFilesSkipsBinary(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("a binary marker\x00here"), 0o644); err != nil {
		t.Fatal(err)
	}
	samples := sampleFiles(dir, []string{"README.md"}, 1000, "")
	if len(samples) != 0 {
		t.Errorf("binary README should be skipped: got %d samples", len(samples))
	}
}
