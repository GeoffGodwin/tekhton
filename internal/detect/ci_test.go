package detect

import (
	"context"
	"testing"
)

func TestCIDetector_GitHubActions(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		".github/workflows/test.yml": `name: ci
jobs:
  test:
    steps:
      - run: go test ./...
      - run: go vet ./...
`,
	})
	r, _ := CIDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	hasTest, hasLint := false, false
	for _, row := range r.Findings {
		if row["test"] == "go test ./..." {
			hasTest = true
		}
		if row["lint"] == "go vet ./..." {
			hasLint = true
		}
	}
	if !hasTest || !hasLint {
		t.Errorf("missing classifications: hasTest=%v hasLint=%v findings=%v", hasTest, hasLint, r.Findings)
	}
}

func TestCIDetector_DockerfileLangPositionedAsDeploy(t *testing.T) {
	// Replicates the bash quirk where dockerfile language lands in the
	// DEPLOY column. See lib/detect_ci.sh:187-191.
	dir := writeFixture(t, map[string]string{
		"Dockerfile": "FROM golang:1.22\n",
	})
	r, _ := CIDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 1 {
		t.Fatalf("want 1 finding; got %d", len(r.Findings))
	}
	if r.Findings[0]["deploy"] != "go" {
		t.Errorf("dockerfile deploy: got %q, want go", r.Findings[0]["deploy"])
	}
}

func TestCIDetector_NoConfig(t *testing.T) {
	dir := writeFixture(t, map[string]string{"README.md": "# x"})
	r, _ := CIDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 0 {
		t.Errorf("expected no CI configs; got %v", r.Findings)
	}
}
