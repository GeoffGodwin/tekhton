package detect

import (
	"context"
	"strconv"
	"strings"
	"testing"
)

func TestDocQualityDetector_MissingReadme(t *testing.T) {
	dir := writeFixture(t, map[string]string{"main.go": "package main\nfunc main() {}\n"})
	r, _ := DocQualityDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 1 {
		t.Fatalf("want 1 doc_quality finding; got %d", len(r.Findings))
	}
	if !strings.Contains(r.Findings[0]["details"], "readme:0/30(missing)") {
		t.Errorf("expected missing-readme marker in details; got %q", r.Findings[0]["details"])
	}
}

func TestDocQualityDetector_RichReadme(t *testing.T) {
	body := "# Project\n\n## Installation\n\n```sh\ngo install\n```\n\n## Usage\n\nDoc."
	for i := 0; i < 5; i++ {
		body += "\n\n## Section " + strconv.Itoa(i) + "\nContent."
	}
	dir := writeFixture(t, map[string]string{
		"README.md":       body,
		"CONTRIBUTING.md": strings.Repeat("Lorem ipsum.\n", 40),
	})
	r, _ := DocQualityDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	score, _ := strconv.Atoi(r.Findings[0]["score"])
	if score < 15 {
		t.Errorf("expected score >= 15 with rich README + CONTRIBUTING; got %d details=%s", score, r.Findings[0]["details"])
	}
}

func TestDocQualityDetector_EmptyDir(t *testing.T) {
	dir := t.TempDir()
	r, _ := DocQualityDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if r.Findings[0]["score"] != "0" {
		t.Errorf("empty dir score: got %q, want 0", r.Findings[0]["score"])
	}
}
