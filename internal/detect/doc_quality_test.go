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

// parseSubscore extracts the numeric value from a detail entry like "readme:15/30".
func parseSubscore(details, prefix string) (int, bool) {
	for _, d := range strings.Split(details, ";") {
		if strings.HasPrefix(d, prefix+":") {
			rest := strings.TrimPrefix(d, prefix+":")
			// rest is like "15/30" or "15/30(missing)"
			slash := strings.IndexByte(rest, '/')
			if slash < 0 {
				return 0, false
			}
			v, err := strconv.Atoi(rest[:slash])
			if err != nil {
				return 0, false
			}
			return v, true
		}
	}
	return 0, false
}

func TestDocQualityDetector_APIDocsOpenAPI(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"openapi.yaml": "openapi: 3.0.0\ninfo:\n  title: My API\n",
	})
	r, _ := DocQualityDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 1 {
		t.Fatalf("want 1 finding; got %d", len(r.Findings))
	}
	apiScore, ok := parseSubscore(r.Findings[0]["details"], "api-docs")
	if !ok {
		t.Fatalf("api-docs subscore not found in details: %q", r.Findings[0]["details"])
	}
	if apiScore < 10 {
		t.Errorf("api-docs score: got %d, want >= 10 (openapi.yaml found)", apiScore)
	}
}

func TestDocQualityDetector_ArchitectureDoc(t *testing.T) {
	body := "# Architecture\n\n## Overview\n\nThis service does X.\n"
	for i := 0; i < 110; i++ {
		body += "Line " + strconv.Itoa(i) + "\n"
	}
	dir := writeFixture(t, map[string]string{
		"ARCHITECTURE.md": body,
	})
	r, _ := DocQualityDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 1 {
		t.Fatalf("want 1 finding; got %d", len(r.Findings))
	}
	archScore, ok := parseSubscore(r.Findings[0]["details"], "architecture")
	if !ok {
		t.Fatalf("architecture subscore not found in details: %q", r.Findings[0]["details"])
	}
	// ARCHITECTURE.md with >100 lines → score 15
	if archScore < 15 {
		t.Errorf("architecture score: got %d, want >= 15 (>100 line doc)", archScore)
	}
}

func TestDocQualityDetector_ADRDir(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"docs/adr/001-use-go.md": "# Use Go\n\n## Decision\n\nUse Go.\n",
		"docs/adr/002-use-pq.md": "# Use PostgreSQL\n\n## Decision\n\nUse PostgreSQL.\n",
	})
	r, _ := DocQualityDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 1 {
		t.Fatalf("want 1 finding; got %d", len(r.Findings))
	}
	archScore, ok := parseSubscore(r.Findings[0]["details"], "architecture")
	if !ok {
		t.Fatalf("architecture subscore not found in details: %q", r.Findings[0]["details"])
	}
	// ADR dir with .md files → +5 bonus
	if archScore < 5 {
		t.Errorf("architecture score: got %d, want >= 5 (adr dir present)", archScore)
	}
}

func TestDocQualityDetector_ContributingGuide(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"CONTRIBUTING.md": strings.Repeat("Line.\n", 110),
	})
	r, _ := DocQualityDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 1 {
		t.Fatalf("want 1 finding; got %d", len(r.Findings))
	}
	contribScore, ok := parseSubscore(r.Findings[0]["details"], "contributing")
	if !ok {
		t.Fatalf("contributing subscore not found in details: %q", r.Findings[0]["details"])
	}
	// >100 line CONTRIBUTING.md → score 15
	if contribScore != 15 {
		t.Errorf("contributing score: got %d, want 15 (>100 line file)", contribScore)
	}
}

func TestDocQualityDetector_IndividualSubscoresPresentInDetails(t *testing.T) {
	// Verify that all five subscore prefixes are always present in the details string,
	// regardless of their value. This pins the output shape against future refactors.
	dir := writeFixture(t, map[string]string{
		"README.md": "# Hello\n",
	})
	r, _ := DocQualityDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 1 {
		t.Fatalf("want 1 finding; got %d", len(r.Findings))
	}
	details := r.Findings[0]["details"]
	required := []string{"readme:", "contributing:", "api-docs:", "architecture:", "inline:"}
	for _, pfx := range required {
		if !strings.Contains(details, pfx) {
			t.Errorf("subscore prefix %q missing from details %q", pfx, details)
		}
	}
}

func TestDocQualityDetector_ReadmeScoreCapAt30(t *testing.T) {
	// A maximally rich README should not push the readme subscore beyond 30.
	body := "# Project\n\n## Installation\n\n```sh\ngo install\n```\n\n## Usage\n\nDoc.\n"
	for i := 0; i < 200; i++ {
		body += "## Section " + strconv.Itoa(i) + "\nContent line.\n"
	}
	dir := writeFixture(t, map[string]string{"README.md": body})
	r, _ := DocQualityDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	readmeScore, ok := parseSubscore(r.Findings[0]["details"], "readme")
	if !ok {
		t.Fatalf("readme subscore not found in details: %q", r.Findings[0]["details"])
	}
	if readmeScore > 30 {
		t.Errorf("readme score exceeds cap: got %d, want <= 30", readmeScore)
	}
}
