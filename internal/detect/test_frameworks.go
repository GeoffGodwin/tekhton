package detect

import (
	"context"
	"path/filepath"
	"strings"
)

// TestFrameworksDetector ports lib/detect_test_frameworks.sh.
type TestFrameworksDetector struct{}

// Name returns the canonical detector name.
func (TestFrameworksDetector) Name() string { return "test_frameworks" }

// Run executes test framework detection.
func (TestFrameworksDetector) Run(_ context.Context, in *Input) (*Result, error) {
	r := &Result{Detector: "test_frameworks"}
	for _, tf := range detectTestFrameworks(in.ProjectDir) {
		r.Findings = append(r.Findings, map[string]string{
			"name":       tf.Name,
			"config":     tf.Config,
			"confidence": tf.Confidence,
		})
	}
	return r, nil
}

func detectTestFrameworks(dir string) []TestFW {
	var out []TestFW
	out = append(out, pythonTestFWs(dir)...)
	out = append(out, jsTestFWs(dir)...)
	out = append(out, goTestFWs(dir)...)
	if fileExists(filepath.Join(dir, "Cargo.toml")) {
		out = append(out, TestFW{Name: "cargo-test", Config: "Cargo.toml", Confidence: "high"})
	}
	out = append(out, rubyTestFWs(dir)...)
	out = append(out, javaTestFWs(dir)...)
	out = append(out, csharpTestFWs(dir)...)
	out = append(out, dartTestFWs(dir)...)
	out = append(out, shellTestFWs(dir)...)
	return out
}

func pythonTestFWs(dir string) []TestFW {
	switch {
	case fileExists(filepath.Join(dir, "pytest.ini")):
		return []TestFW{{Name: "pytest", Config: "pytest.ini", Confidence: "high"}}
	case fileExists(filepath.Join(dir, "conftest.py")):
		return []TestFW{{Name: "pytest", Config: "conftest.py", Confidence: "high"}}
	case fileExists(filepath.Join(dir, "pyproject.toml")) && strings.Contains(readFile(filepath.Join(dir, "pyproject.toml")), "[tool.pytest"):
		return []TestFW{{Name: "pytest", Config: "pyproject.toml", Confidence: "high"}}
	case fileExists(filepath.Join(dir, "setup.cfg")) && strings.Contains(readFile(filepath.Join(dir, "setup.cfg")), "[tool:pytest]"):
		return []TestFW{{Name: "pytest", Config: "setup.cfg", Confidence: "high"}}
	case fileExists(filepath.Join(dir, "tox.ini")) && strings.Contains(readFile(filepath.Join(dir, "tox.ini")), "pytest"):
		return []TestFW{{Name: "pytest", Config: "tox.ini", Confidence: "medium"}}
	}
	if fileExists(filepath.Join(dir, "pyproject.toml")) {
		if strings.Contains(readFile(filepath.Join(dir, "pyproject.toml")), "pytest") {
			return []TestFW{{Name: "pytest", Config: "requirements", Confidence: "medium"}}
		}
	}
	if fileExists(filepath.Join(dir, "requirements.txt")) {
		if strings.Contains(readFile(filepath.Join(dir, "requirements.txt")), "pytest") {
			return []TestFW{{Name: "pytest", Config: "requirements", Confidence: "medium"}}
		}
	}
	// unittest fallback: test_*.py files but no pytest indicators.
	if hasTestPyFiles(dir) {
		if fileExists(filepath.Join(dir, "pytest.ini")) || fileExists(filepath.Join(dir, "conftest.py")) {
			return nil
		}
		py := readFile(filepath.Join(dir, "pyproject.toml"))
		req := readFile(filepath.Join(dir, "requirements.txt"))
		if !strings.Contains(py, "pytest") && !strings.Contains(req, "pytest") {
			return []TestFW{{Name: "unittest", Config: "test_*.py", Confidence: "medium"}}
		}
	}
	return nil
}

func hasTestPyFiles(dir string) bool {
	for _, p := range listFilesDepth(dir, 3) {
		if strings.HasPrefix(filepath.Base(p), "test_") && strings.HasSuffix(p, ".py") {
			if !strings.Contains(p, "/.venv/") {
				return true
			}
		}
	}
	return false
}

func jsTestFWs(dir string) []TestFW {
	p := filepath.Join(dir, "package.json")
	if !fileExists(p) {
		return nil
	}
	body := readFile(p)
	var out []TestFW
	if strings.Contains(body, `"jest"`) {
		conf := "package.json"
		switch {
		case fileExists(filepath.Join(dir, "jest.config.ts")):
			conf = "jest.config.ts"
		case fileExists(filepath.Join(dir, "jest.config.js")):
			conf = "jest.config.js"
		}
		out = append(out, TestFW{Name: "jest", Config: conf, Confidence: "high"})
	}
	if strings.Contains(body, `"vitest"`) {
		conf := "package.json"
		switch {
		case fileExists(filepath.Join(dir, "vitest.config.js")):
			conf = "vitest.config.js"
		case fileExists(filepath.Join(dir, "vitest.config.ts")):
			conf = "vitest.config.ts"
		}
		out = append(out, TestFW{Name: "vitest", Config: conf, Confidence: "high"})
	}
	if strings.Contains(body, `"mocha"`) {
		conf := "package.json"
		switch {
		case fileExists(filepath.Join(dir, ".mocharc.yaml")):
			conf = ".mocharc.yaml"
		case fileExists(filepath.Join(dir, ".mocharc.yml")):
			conf = ".mocharc.yml"
		}
		out = append(out, TestFW{Name: "mocha", Config: conf, Confidence: "high"})
	}
	if strings.Contains(body, `"cypress"`) {
		conf := "package.json"
		switch {
		case fileExists(filepath.Join(dir, "cypress.config.ts")):
			conf = "cypress.config.ts"
		case fileExists(filepath.Join(dir, "cypress.config.js")):
			conf = "cypress.config.js"
		}
		out = append(out, TestFW{Name: "cypress", Config: conf, Confidence: "high"})
	}
	if strings.Contains(body, `"@playwright/test"`) || strings.Contains(body, `"playwright"`) {
		conf := "package.json"
		switch {
		case fileExists(filepath.Join(dir, "playwright.config.js")):
			conf = "playwright.config.js"
		case fileExists(filepath.Join(dir, "playwright.config.ts")):
			conf = "playwright.config.ts"
		}
		out = append(out, TestFW{Name: "playwright", Config: conf, Confidence: "high"})
	}
	return out
}

func goTestFWs(dir string) []TestFW {
	if !fileExists(filepath.Join(dir, "go.mod")) {
		return nil
	}
	var out []TestFW
	if hasGoTestFiles(dir) {
		out = append(out, TestFW{Name: "go-test", Config: "go.mod", Confidence: "high"})
	}
	if strings.Contains(readFile(filepath.Join(dir, "go.mod")), "stretchr/testify") {
		out = append(out, TestFW{Name: "testify", Config: "go.mod", Confidence: "high"})
	}
	return out
}

func hasGoTestFiles(dir string) bool {
	for _, p := range listFilesDepth(dir, 3) {
		if strings.HasSuffix(p, "_test.go") && !strings.Contains(p, "/vendor/") {
			return true
		}
	}
	return false
}

func rubyTestFWs(dir string) []TestFW {
	var out []TestFW
	gem := filepath.Join(dir, "Gemfile")
	if fileExists(gem) {
		body := readFile(gem)
		if strings.Contains(body, "'rspec'") || strings.Contains(body, `"rspec"`) {
			out = append(out, TestFW{Name: "rspec", Config: "Gemfile", Confidence: "high"})
		}
		if strings.Contains(body, "'minitest'") || strings.Contains(body, `"minitest"`) {
			out = append(out, TestFW{Name: "minitest", Config: "Gemfile", Confidence: "high"})
		}
	}
	if fileExists(filepath.Join(dir, ".rspec")) {
		out = append(out, TestFW{Name: "rspec", Config: ".rspec", Confidence: "high"})
	}
	return out
}

func javaTestFWs(dir string) []TestFW {
	switch {
	case fileExists(filepath.Join(dir, "build.gradle.kts")):
		body := readFile(filepath.Join(dir, "build.gradle.kts"))
		if strings.Contains(body, "junit") {
			return []TestFW{{Name: "junit", Config: "build.gradle.kts", Confidence: "high"}}
		}
	case fileExists(filepath.Join(dir, "build.gradle")):
		body := readFile(filepath.Join(dir, "build.gradle"))
		if strings.Contains(body, "junit") {
			return []TestFW{{Name: "junit", Config: "build.gradle", Confidence: "high"}}
		}
	case fileExists(filepath.Join(dir, "pom.xml")):
		body := readFile(filepath.Join(dir, "pom.xml"))
		if strings.Contains(body, "junit") {
			return []TestFW{{Name: "junit", Config: "pom.xml", Confidence: "high"}}
		}
	}
	return nil
}

func csharpTestFWs(dir string) []TestFW {
	if firstMatch(dir, "*.csproj") == "" {
		return nil
	}
	var body strings.Builder
	for _, m := range globMany(dir, "*.csproj") {
		body.WriteString(readFile(m))
		body.WriteByte('\n')
	}
	s := body.String()
	var out []TestFW
	if strings.Contains(s, "xunit") {
		out = append(out, TestFW{Name: "xunit", Config: "*.csproj", Confidence: "high"})
	}
	if strings.Contains(s, "NUnit") {
		out = append(out, TestFW{Name: "nunit", Config: "*.csproj", Confidence: "high"})
	}
	if strings.Contains(s, "MSTest") {
		out = append(out, TestFW{Name: "mstest", Config: "*.csproj", Confidence: "high"})
	}
	return out
}

func dartTestFWs(dir string) []TestFW {
	p := filepath.Join(dir, "pubspec.yaml")
	if !fileExists(p) {
		return nil
	}
	body := readFile(p)
	if strings.Contains(body, "flutter_test:") {
		return []TestFW{{Name: "flutter-test", Config: "pubspec.yaml", Confidence: "high"}}
	}
	if strings.Contains(body, "test:") {
		return []TestFW{{Name: "dart-test", Config: "pubspec.yaml", Confidence: "high"}}
	}
	return nil
}

func shellTestFWs(dir string) []TestFW {
	var out []TestFW
	if fileExists(filepath.Join(dir, "tests/run_tests.sh")) {
		out = append(out, TestFW{Name: "shell-tests", Config: "tests/run_tests.sh", Confidence: "high"})
	}
	if fileExists(filepath.Join(dir, "test/bats")) || hasBatsFiles(dir) {
		out = append(out, TestFW{Name: "bats", Config: "*.bats", Confidence: "high"})
	}
	return out
}

func hasBatsFiles(dir string) bool {
	for _, p := range listFilesDepth(dir, 2) {
		if strings.HasSuffix(p, ".bats") {
			return true
		}
	}
	return false
}
