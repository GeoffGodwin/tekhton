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

func TestCIDetector_GitLabCI(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		".gitlab-ci.yml": `test:
  script:
    - pytest tests/
    - ruff check .
`,
	})
	r, _ := CIDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	hasTest, hasLint := false, false
	for _, row := range r.Findings {
		if row["system"] == "gitlab-ci" {
			if row["test"] != "" {
				hasTest = true
			}
			if row["lint"] != "" {
				hasLint = true
			}
		}
	}
	if !hasTest {
		t.Errorf("expected gitlab-ci test finding; findings=%v", r.Findings)
	}
	if !hasLint {
		t.Errorf("expected gitlab-ci lint finding; findings=%v", r.Findings)
	}
}

func TestCIDetector_CircleCI(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		".circleci/config.yml": `version: 2.1
jobs:
  build:
    steps:
      - run:
          command: go test ./...
      - run:
          command: golangci-lint run
`,
	})
	r, _ := CIDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	hasTest, hasLint := false, false
	for _, row := range r.Findings {
		if row["system"] == "circleci" {
			if row["test"] != "" {
				hasTest = true
			}
			if row["lint"] != "" {
				hasLint = true
			}
		}
	}
	if !hasTest {
		t.Errorf("expected circleci test finding; findings=%v", r.Findings)
	}
	if !hasLint {
		t.Errorf("expected circleci lint finding; findings=%v", r.Findings)
	}
}

func TestCIDetector_Jenkins(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"Jenkinsfile": `pipeline {
  stages {
    stage('Test') {
      steps {
        sh 'go test ./...'
      }
    }
    stage('Lint') {
      steps {
        sh 'golangci-lint run'
      }
    }
  }
}
`,
	})
	r, _ := CIDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	hasTest, hasLint := false, false
	for _, row := range r.Findings {
		if row["system"] == "jenkins" {
			if row["test"] != "" {
				hasTest = true
			}
			if row["lint"] != "" {
				hasLint = true
			}
		}
	}
	if !hasTest {
		t.Errorf("expected jenkins test finding; findings=%v", r.Findings)
	}
	if !hasLint {
		t.Errorf("expected jenkins lint finding; findings=%v", r.Findings)
	}
}

func TestCIDetector_BitbucketPipelines(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"bitbucket-pipelines.yml": `pipelines:
  default:
    - step:
        script:
          - pytest tests/
          - ruff check .
`,
	})
	r, _ := CIDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	hasTest, hasLint := false, false
	for _, row := range r.Findings {
		if row["system"] == "bitbucket" {
			if row["test"] != "" {
				hasTest = true
			}
			if row["lint"] != "" {
				hasLint = true
			}
		}
	}
	if !hasTest {
		t.Errorf("expected bitbucket test finding; findings=%v", r.Findings)
	}
	if !hasLint {
		t.Errorf("expected bitbucket lint finding; findings=%v", r.Findings)
	}
}

func TestCIDetector_DockerfilePythonLang(t *testing.T) {
	// Dockerfile with Python base image lands python in deploy column — mirrors bash quirk.
	dir := writeFixture(t, map[string]string{
		"Dockerfile": "FROM python:3.11-slim\n",
	})
	r, _ := CIDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 1 {
		t.Fatalf("want 1 finding; got %d: %v", len(r.Findings), r.Findings)
	}
	if r.Findings[0]["deploy"] != "python" {
		t.Errorf("dockerfile deploy: got %q, want python", r.Findings[0]["deploy"])
	}
}

func TestCIDetector_SecretsLinesSkipped(t *testing.T) {
	// Lines containing ${{ secrets are skipped to preserve read-only contract.
	dir := writeFixture(t, map[string]string{
		".github/workflows/deploy.yml": `name: deploy
jobs:
  deploy:
    steps:
      - run: aws s3 sync . s3://bucket --${{ secrets.AWS_KEY }}
      - run: go test ./...
`,
	})
	r, _ := CIDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	for _, row := range r.Findings {
		if row["test"] != "" && row["test"] == "aws s3 sync . s3://bucket --${{ secrets.AWS_KEY }}" {
			t.Errorf("secrets line should be skipped; got finding: %v", row)
		}
	}
	hasTest := false
	for _, row := range r.Findings {
		if row["test"] == "go test ./..." {
			hasTest = true
		}
	}
	if !hasTest {
		t.Errorf("expected go test ./... finding to survive secrets-skip; findings=%v", r.Findings)
	}
}
