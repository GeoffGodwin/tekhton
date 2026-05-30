package detect

import (
	"context"
	"path/filepath"
	"regexp"
	"strings"
)

// CIDetector ports lib/detect_ci.sh::detect_ci_config — GitHub Actions,
// GitLab CI, CircleCI, Jenkinsfile, Bitbucket Pipelines, and Dockerfile
// language hints. Read-only: never executes CI commands, never reads
// secrets (lines containing ${{ secrets or $CI_ env refs are skipped).
type CIDetector struct{}

// Name returns the canonical detector name.
func (CIDetector) Name() string { return "ci" }

// Run executes CI config detection across the supported providers.
func (CIDetector) Run(_ context.Context, in *Input) (*Result, error) {
	r := &Result{Detector: "ci"}
	for _, c := range detectCIConfig(in.ProjectDir) {
		r.Findings = append(r.Findings, map[string]string{
			"system":     c.System,
			"build":      c.Build,
			"test":       c.Test,
			"lint":       c.Lint,
			"deploy":     c.Deploy,
			"language":   c.Language,
			"confidence": c.Confidence,
		})
	}
	return r, nil
}

// detectCIConfig is the shared internal entry used by CommandsDetector for
// CI-injected commands AND by CIDetector for its own Result. Mirrors
// bash detect_ci_config.
func detectCIConfig(dir string) []CIConfig {
	var out []CIConfig
	out = append(out, detectGitHubActions(dir)...)
	out = append(out, detectGitLabCI(dir)...)
	out = append(out, detectCircleCI(dir)...)
	out = append(out, detectJenkinsfile(dir)...)
	out = append(out, detectBitbucketPipelines(dir)...)
	out = append(out, detectDockerfileLangs(dir)...)
	return out
}

func detectGitHubActions(dir string) []CIConfig {
	wfDir := filepath.Join(dir, ".github", "workflows")
	if !dirExists(wfDir) {
		return nil
	}
	matches := globMany(wfDir, "*.yml")
	matches = append(matches, globMany(wfDir, "*.yaml")...)
	if len(matches) > 10 {
		matches = matches[:10]
	}
	var out []CIConfig
	for _, f := range matches {
		out = append(out, parseGitHubWorkflow(f)...)
	}
	return out
}

var rxRunCmd = regexp.MustCompile(`run:\s*(.*)`)
var rxLeadStrip = regexp.MustCompile(`^[|>-]*`)

func parseGitHubWorkflow(file string) []CIConfig {
	body := readFile(file)
	var out []CIConfig
	var deploy string
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, "${{secrets") || strings.Contains(line, "${{ secrets") {
			continue
		}
		if m := rxRunCmd.FindStringSubmatch(line); m != nil {
			raw := m[1]
			raw = rxLeadStrip.ReplaceAllString(raw, "")
			raw = strings.ReplaceAll(raw, `"`, "")
			raw = strings.TrimLeft(raw, " \t")
			if raw != "" {
				if c, ok := classifyCICommand("github-actions", raw); ok {
					out = append(out, c)
				}
			}
		}
		if strings.Contains(line, "deploy") || strings.Contains(line, "publish") {
			switch {
			case strings.Contains(line, "aws") || strings.Contains(line, "s3"):
				deploy = "aws"
			case strings.Contains(line, "gcloud") || strings.Contains(line, "gcp"):
				deploy = "gcp"
			case strings.Contains(line, "azure"):
				deploy = "azure"
			case strings.Contains(line, "heroku"):
				deploy = "heroku"
			case strings.Contains(line, "vercel"):
				deploy = "vercel"
			case strings.Contains(line, "netlify"):
				deploy = "netlify"
			}
		}
	}
	if deploy != "" {
		out = append(out, CIConfig{System: "github-actions", Deploy: deploy, Confidence: "medium"})
	}
	return out
}

func detectGitLabCI(dir string) []CIConfig {
	p := filepath.Join(dir, ".gitlab-ci.yml")
	if !fileExists(p) {
		return nil
	}
	body := readFile(p)
	rx := regexp.MustCompile(`^[[:space:]]+-[[:space:]]+(.*)`)
	var out []CIConfig
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, "$CI_") || strings.Contains(line, "${") {
			continue
		}
		if m := rx.FindStringSubmatch(line); m != nil {
			raw := strings.TrimLeft(strings.ReplaceAll(m[1], `"`, ""), " \t")
			if raw == "" {
				continue
			}
			if c, ok := classifyCICommand("gitlab-ci", raw); ok {
				out = append(out, c)
			}
		}
	}
	return out
}

func detectCircleCI(dir string) []CIConfig {
	p := filepath.Join(dir, ".circleci", "config.yml")
	if !fileExists(p) {
		return nil
	}
	body := readFile(p)
	rxCommand := regexp.MustCompile(`command:\s*(.*)`)
	rxRun := regexp.MustCompile(`run:\s*(.*)`)
	var out []CIConfig
	for _, line := range strings.Split(body, "\n") {
		if m := rxCommand.FindStringSubmatch(line); m != nil {
			raw := strings.TrimLeft(strings.ReplaceAll(m[1], `"`, ""), " \t")
			if raw == "" {
				continue
			}
			if c, ok := classifyCICommand("circleci", raw); ok {
				out = append(out, c)
			}
		}
		if m := rxRun.FindStringSubmatch(line); m != nil {
			raw := m[1]
			if strings.TrimSpace(raw) == "" {
				continue
			}
			raw = strings.TrimLeft(strings.ReplaceAll(raw, `"`, ""), " \t")
			if raw == "" || strings.HasPrefix(raw, "name:") {
				continue
			}
			if c, ok := classifyCICommand("circleci", raw); ok {
				out = append(out, c)
			}
		}
	}
	return out
}

func detectJenkinsfile(dir string) []CIConfig {
	p := filepath.Join(dir, "Jenkinsfile")
	if !fileExists(p) {
		return nil
	}
	body := readFile(p)
	rx := regexp.MustCompile(`sh\s+["'](.*)["']`)
	var out []CIConfig
	for _, line := range strings.Split(body, "\n") {
		if m := rx.FindStringSubmatch(line); m != nil && m[1] != "" {
			if c, ok := classifyCICommand("jenkins", m[1]); ok {
				out = append(out, c)
			}
		}
	}
	return out
}

func detectBitbucketPipelines(dir string) []CIConfig {
	p := filepath.Join(dir, "bitbucket-pipelines.yml")
	if !fileExists(p) {
		return nil
	}
	body := readFile(p)
	rx := regexp.MustCompile(`^[[:space:]]+-[[:space:]]+(.*)`)
	var out []CIConfig
	for _, line := range strings.Split(body, "\n") {
		if m := rx.FindStringSubmatch(line); m != nil {
			raw := strings.TrimLeft(strings.ReplaceAll(m[1], `"`, ""), " \t")
			if raw == "" || strings.HasPrefix(raw, "pipe:") {
				continue
			}
			if c, ok := classifyCICommand("bitbucket", raw); ok {
				out = append(out, c)
			}
		}
	}
	return out
}

func detectDockerfileLangs(dir string) []CIConfig {
	candidates := []string{"Dockerfile"}
	candidates = append(candidates, basenames(globMany(dir, "Dockerfile.*"))...)
	seen := make(map[string]bool)
	var out []CIConfig
	for _, name := range candidates {
		if seen[name] {
			continue
		}
		seen[name] = true
		p := filepath.Join(dir, name)
		if !fileExists(p) {
			continue
		}
		body := readFile(p)
		var from string
		for _, line := range strings.Split(body, "\n") {
			if strings.HasPrefix(strings.ToLower(strings.TrimSpace(line)), "from") {
				from = line
				break
			}
		}
		if from == "" {
			continue
		}
		fields := strings.Fields(from)
		if len(fields) < 2 {
			continue
		}
		image := fields[1]
		if idx := strings.IndexByte(image, ':'); idx >= 0 {
			image = image[:idx]
		}
		lang := dockerImageLang(image)
		if lang == "" {
			continue
		}
		// Bash quirk (lib/detect_ci.sh:187-191): the language is emitted
		// in the DEPLOY pipe field (`dockerfile||||$lang||medium`), so it
		// shows up in the Deploy column of the report. Mirror that here
		// to keep parity until/unless we explicitly fix the bash field.
		out = append(out, CIConfig{System: "dockerfile", Deploy: lang, Confidence: "medium"})
	}
	return out
}

func dockerImageLang(image string) string {
	switch {
	case strings.Contains(image, "node"):
		return "node"
	case strings.Contains(image, "python"):
		return "python"
	case strings.Contains(image, "golang") || strings.Contains(image, "go"):
		return "go"
	case strings.Contains(image, "rust"):
		return "rust"
	case strings.Contains(image, "ruby"):
		return "ruby"
	}
	return ""
}

func basenames(paths []string) []string {
	out := make([]string, 0, len(paths))
	for _, p := range paths {
		out = append(out, filepath.Base(p))
	}
	return out
}

// classifyCICommand ports lib/detect_ci.sh::_classify_ci_command.
// Returns (CIConfig, true) on classification, (zero, false) otherwise.
func classifyCICommand(ciSystem, cmd string) (CIConfig, bool) {
	norm := strings.TrimPrefix(cmd, "sudo ")
	norm = regexp.MustCompile(`^[A-Z_]+=[^ ]* `).ReplaceAllString(norm, "")

	if containsAny(norm, "test", "pytest", "jest", "vitest", "rspec", "cargo test", "go test", "dotnet test") {
		if !containsAny(norm, "install", "setup", "npm ci") {
			return CIConfig{System: ciSystem, Test: cmd, Confidence: "high"}, true
		}
		return CIConfig{}, false
	}
	if containsAny(norm, "lint", "eslint", "ruff", "flake8", "clippy", "golangci-lint",
		"rubocop", "prettier", "black --check", "go vet", "shellcheck", "analyze") {
		return CIConfig{System: ciSystem, Lint: cmd, Confidence: "high"}, true
	}
	if containsAny(norm, "build", "compile", "cargo build", "go build",
		"dotnet build", "mvn package", "gradlew build") {
		if !containsAny(norm, "install", "npm ci") {
			return CIConfig{System: ciSystem, Build: cmd, Confidence: "high"}, true
		}
	}
	return CIConfig{}, false
}

func containsAny(s string, needles ...string) bool {
	for _, n := range needles {
		if strings.Contains(s, n) {
			return true
		}
	}
	return false
}
